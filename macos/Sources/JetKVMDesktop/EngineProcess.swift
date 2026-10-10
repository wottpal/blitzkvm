import Foundation
import JetKVMCore

protocol EngineProcessDelegate: AnyObject {
    /// Called on a background queue for every video access unit.
    func engine(_ engine: EngineProcess, didReceive header: AccessUnitHeader, data: Data)
    /// Called on the main queue.
    func engine(_ engine: EngineProcess, didUpdate snapshot: SessionSnapshot)
    func engine(_ engine: EngineProcess, didUpdateStats stats: [String: Any])
    func engine(_ engine: EngineProcess, didFinishCommand id: Int64, error: String?, invalid: String?)
    func engineDidRestart(_ engine: EngineProcess, reason: String)
}

/// Runs and supervises the Go helper (`jetkvm-engine`): one process per
/// device session. If it crashes, it is restarted with backoff and the last
/// connect command is replayed, so the window survives engine failures.
final class EngineProcess {
    weak var delegate: EngineProcessDelegate?

    private let executableURL: URL
    private let ioQueue = DispatchQueue(label: "jetkvm.engine.io", qos: .userInteractive)
    private let writeLock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var parser = FrameParser()
    private var lastConnect: EngineCommand?
    private var stopped = false
    private var restartDelay: TimeInterval = 0.5
    private var nextCommandID: Int64 = 1
    private(set) var restarts = 0

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    /// Finds the helper next to the app binary (Contents/Helpers or
    /// Contents/MacOS), or at $JETKVM_ENGINE for development.
    static func locateHelper() -> URL? {
        if let path = ProcessInfo.processInfo.environment["JETKVM_ENGINE"], FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let bundle = Bundle.main.bundleURL
        let candidates = [
            bundle.appendingPathComponent("Contents/Helpers/jetkvm-engine"),
            bundle.appendingPathComponent("Contents/MacOS/jetkvm-engine"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("jetkvm-engine"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func start() throws {
        stopped = false
        try launch()
    }

    func stop() {
        stopped = true
        writeLock.lock()
        try? stdinHandle?.close()
        stdinHandle = nil
        writeLock.unlock()
        process?.terminate()
    }

    /// Terminates the helper as a crash would (used by the self-test).
    func simulateCrash() {
        process?.interrupt()
        kill(process?.processIdentifier ?? 0, SIGKILL)
    }

    private func launch() throws {
        let p = Process()
        p.executableURL = executableURL
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        parser = FrameParser()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.ioQueue.sync { self.consume(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                FileHandle.standardError.write(Data(("[engine] " + text).utf8))
            }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.handleTermination(status: proc.terminationStatus, reason: proc.terminationReason) }
        }
        try p.run()
        writeLock.lock()
        process = p
        stdinHandle = input.fileHandleForWriting
        writeLock.unlock()
    }

    private func handleTermination(status: Int32, reason: Process.TerminationReason) {
        guard !stopped else { return }
        restarts += 1
        let why = reason == .uncaughtSignal ? "signal \(status)" : "exit \(status)"
        delegate?.engineDidRestart(self, reason: why)
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 10)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped else { return }
            do {
                try self.launch()
                if var connect = self.lastConnect {
                    connect.id = nil
                    self.send(command: connect)
                }
            } catch {
                self.delegate?.engineDidRestart(self, reason: "relaunch failed: \(error)")
            }
        }
    }

    private func consume(_ data: Data) {
        let frames: [(FrameType?, Data)]
        do {
            frames = try parser.feed(data)
        } catch {
            FileHandle.standardError.write(Data("engine protocol error: \(error)\n".utf8))
            process?.terminate()
            return
        }
        for (type, payload) in frames {
            switch type {
            case .accessUnit:
                if let (header, annexB) = AccessUnitHeader.parse(payload) {
                    delegate?.engine(self, didReceive: header, data: annexB)
                }
            case .event:
                handleEvent(payload)
            case .commandDone, .rpcResult:
                // RPC results share the id/error shape; their result payload
                // is not needed by the app yet.
                if let result = try? JSONDecoder().decode(CommandResult.self, from: payload) {
                    DispatchQueue.main.async { self.delegate?.engine(self, didFinishCommand: result.id, error: result.error, invalid: result.invalid) }
                }
            default:
                break
            }
        }
    }

    private func handleEvent(_ payload: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let type = object["type"] as? String else { return }
        switch type {
        case "snapshot":
            guard let raw = object["snapshot"],
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data) else { return }
            if snapshot.Phase == "connected" { restartDelay = 0.5 }
            DispatchQueue.main.async { self.delegate?.engine(self, didUpdate: snapshot) }
        case "stats":
            if let stats = object["stats"] as? [String: Any] {
                DispatchQueue.main.async { self.delegate?.engine(self, didUpdateStats: stats) }
            }
        default:
            break
        }
    }

    // MARK: Sending

    func connect(baseURL: String, password: String?, offerH265: Bool) {
        let command = EngineCommand(cmd: "connect", baseURL: baseURL, password: password, offerH265: offerH265)
        lastConnect = command
        send(command: command)
    }

    @discardableResult
    func send(command: EngineCommand) -> Int64 {
        var command = command
        if command.id == nil {
            command.id = nextCommandID
            nextCommandID += 1
        }
        if let frame = try? EngineProtocol.command(command) {
            write(frame)
        }
        return command.id ?? 0
    }

    func write(_ frame: Data) {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard let handle = stdinHandle else { return }
        do {
            try handle.write(contentsOf: frame)
        } catch {
            // Broken pipe: the termination handler restarts the helper.
        }
    }
}
