import Foundation
import JetKVMCore

protocol EngineProcessDelegate: AnyObject {
    /// Called on a background queue for every video access unit.
    func engine(_ engine: EngineProcess, didReceive header: AccessUnitHeader, data: Data)
    /// Called on the main queue.
    func engine(_ engine: EngineProcess, didUpdate snapshot: SessionSnapshot)
    func engine(_ engine: EngineProcess, didUpdateStats stats: [String: Any])
    func engine(_ engine: EngineProcess, didFinishCommand id: Int64, error: String?, invalid: String?)
    func engine(_ engine: EngineProcess, didReceiveSerial text: String)
    func engine(_ engine: EngineProcess, didUpdateUpload progress: UploadProgress)
    func engineDidRestart(_ engine: EngineProcess, reason: String)
}

struct EngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Runs and supervises the Go helper (`blitzkvm-engine`): one process per
/// device session. If it crashes, it is restarted with backoff and the last
/// connect command is replayed, so the window survives engine failures.
final class EngineProcess {
    weak var delegate: EngineProcessDelegate?

    private let executableURL: URL
    private let ioQueue = DispatchQueue(label: "jetkvm.engine.io", qos: .userInteractive)
    /// Guards process and stdinHandle, which writers on other threads use.
    private let writeLock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readHandles: [FileHandle] = []
    // Main-thread state.
    private var lastConnect: EngineCommand?
    private var videoPaused = false
    private var stopped = false
    private var restartDelay: TimeInterval = 0.5
    private var nextCommandID: Int64 = 1
    private(set) var restarts = 0
    /// Awaited commands and RPCs by ID (main thread).
    private var waiting: [Int64: CheckedContinuation<Data?, Error>] = [:]

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    deinit {
        stop()
    }

    /// Finds the helper next to the app binary (Contents/Helpers or
    /// Contents/MacOS), or at $BLITZKVM_ENGINE for development.
    static func locateHelper() -> URL? {
        if let path = ProcessInfo.processInfo.environment["BLITZKVM_ENGINE"], FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let bundle = Bundle.main.bundleURL
        let candidates = [
            bundle.appendingPathComponent("Contents/Helpers/blitzkvm-engine"),
            bundle.appendingPathComponent("Contents/MacOS/blitzkvm-engine"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("blitzkvm-engine"),
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
        let p = process
        process = nil
        try? stdinHandle?.close()
        stdinHandle = nil
        let handles = readHandles
        readHandles = []
        writeLock.unlock()
        // Readability handlers must be removed explicitly: at EOF Foundation
        // keeps calling them with empty data, spinning a CPU core.
        handles.forEach { $0.readabilityHandler = nil }
        p?.terminate()
        // The termination handler ignores a process stopped on purpose, so
        // fail what is still awaited here (e.g. an upload when the window
        // closes).
        let abandoned = waiting
        waiting = [:]
        abandoned.values.forEach { $0.resume(throwing: EngineError(message: "the session was closed")) }
    }

    /// Terminates the helper as a crash would (used by the self-test).
    func simulateCrash() {
        writeLock.lock()
        let pid = process?.processIdentifier ?? 0
        writeLock.unlock()
        if pid > 0 { kill(pid, SIGKILL) }
    }

    private func launch() throws {
        let p = Process()
        p.executableURL = executableURL
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        // Each launch gets its own parser: a restarted helper starts a fresh
        // byte stream, and the old pipe's handler may still be draining.
        var parser = FrameParser()
        let queue = ioQueue
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil // EOF
                return
            }
            queue.sync {
                do {
                    let frames = try parser.feed(data)
                    self?.dispatch(frames)
                } catch {
                    AppLog.log("engine protocol error: \(error)")
                    handle.readabilityHandler = nil
                    p.terminate()
                }
            }
        }
        // The helper logs JSON lines (and Go crash output) to stderr.
        var pending = Data()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                if !pending.isEmpty { AppLog.write(String(decoding: pending, as: UTF8.self), prefix: "[engine] ") }
                return
            }
            pending.append(data)
            // Only complete lines, so a line split across reads stays whole.
            guard let end = pending.lastIndex(of: UInt8(ascii: "\n")) else { return }
            let lines = pending[...end]
            pending = Data(pending[pending.index(after: end)...])
            AppLog.write(String(decoding: lines, as: UTF8.self), prefix: "[engine] ")
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.handleTermination(proc) }
        }
        try p.run()
        writeLock.lock()
        process = p
        stdinHandle = input.fileHandleForWriting
        readHandles = [output.fileHandleForReading, errors.fileHandleForReading]
        writeLock.unlock()
        // A new helper sends video until told otherwise.
        if videoPaused { send(command: EngineCommand(cmd: "setVideoPaused", paused: true)) }
    }

    private func handleTermination(_ proc: Process) {
        writeLock.lock()
        let isCurrent = process === proc
        if isCurrent {
            process = nil
            stdinHandle = nil
        }
        writeLock.unlock()
        guard isCurrent else { return }
        // Requests to the dead helper get no answer.
        let abandoned = waiting
        waiting = [:]
        abandoned.values.forEach { $0.resume(throwing: EngineError(message: "the engine restarted")) }
        guard !stopped else { return }
        restarts += 1
        let why = proc.terminationReason == .uncaughtSignal ? "signal \(proc.terminationStatus)" : "exit \(proc.terminationStatus)"
        AppLog.log("engine \(proc.processIdentifier) ended (\(why)); restarting")
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

    /// Runs on ioQueue.
    private func dispatch(_ frames: [(FrameType?, Data)]) {
        for (type, payload) in frames {
            switch type {
            case .accessUnit:
                if let (header, annexB) = AccessUnitHeader.parse(payload) {
                    delegate?.engine(self, didReceive: header, data: annexB)
                }
            case .event:
                handleEvent(payload)
            case .commandDone, .rpcResult:
                // RPC results share the id/error shape, plus a result.
                if let result = try? JSONDecoder().decode(CommandResult.self, from: payload) {
                    let value = type == .rpcResult ? (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])?["result"] : nil
                    let resultData = value.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed) }
                    DispatchQueue.main.async {
                        if let continuation = self.waiting.removeValue(forKey: result.id) {
                            if let error = result.error, !error.isEmpty {
                                continuation.resume(throwing: EngineError(message: error))
                            } else {
                                continuation.resume(returning: resultData)
                            }
                            return
                        }
                        self.delegate?.engine(self, didFinishCommand: result.id, error: result.error, invalid: result.invalid)
                    }
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
            DispatchQueue.main.async {
                if snapshot.Phase == "connected" { self.restartDelay = 0.5 }
                self.delegate?.engine(self, didUpdate: snapshot)
            }
        case "serial":
            guard let text = object["text"] as? String else { return }
            DispatchQueue.main.async { self.delegate?.engine(self, didReceiveSerial: text) }
        case "uploadProgress":
            guard let raw = object["upload"],
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let progress = try? JSONDecoder().decode(UploadProgress.self, from: data) else { return }
            DispatchQueue.main.async { self.delegate?.engine(self, didUpdateUpload: progress) }
        case "stats":
            // {"stats": {"stats": {...client stats...}, "engineDroppedUnits": n}}
            guard let wrapper = object["stats"] as? [String: Any] else { return }
            var flat = wrapper["stats"] as? [String: Any] ?? [:]
            flat["engineDroppedUnits"] = wrapper["engineDroppedUnits"]
            DispatchQueue.main.async { self.delegate?.engine(self, didUpdateStats: flat) }
        default:
            break
        }
    }

    // MARK: Sending

    /// Offers H.265: JetKVM then streams it (it picks H.265 whenever the
    /// offer contains it), and it measured sharper than H.264 at every bitrate
    /// on the device's encoder; every Apple-silicon Mac decodes it in
    /// hardware. The offer still lists H.264 for firmware without H.265.
    /// `--h264` (self-tests only) offers H.264 alone, for the emulator's live
    /// test pattern, which only its H.264 encoder can produce.
    static var offerH265 = true

    func connect(baseURL: String, password: String?, deviceID: String?, certSHA256: String?, autoQuality: Bool, qualityLevel: String?) {
        let command = EngineCommand(cmd: "connect", baseURL: baseURL, password: password, deviceID: deviceID,
                                    certSHA256: certSHA256, offerH265: Self.offerH265, autoQuality: autoQuality,
                                    qualityLevel: autoQuality ? nil : qualityLevel)
        lastConnect = command
        send(command: command)
    }

    /// Pins a device ID learned after connecting, so a restarted helper
    /// verifies it too (the running helper pins it itself).
    func pin(deviceID: String) {
        lastConnect?.deviceID = deviceID
    }

    /// Pins a certificate authority learned on first connect (see pin(deviceID:)).
    func pin(certSHA256: String) {
        lastConnect?.certSHA256 = certSHA256
    }

    /// Turns automatic quality on or off, also for a restarted helper.
    func setAutoQuality(_ on: Bool) {
        lastConnect?.autoQuality = on
        send(command: EngineCommand(cmd: "setAutoQuality", autoQuality: on))
    }

    /// Fixes the quality level (automatic off), also for a restarted helper.
    func setQualityLevel(_ name: String) {
        lastConnect?.autoQuality = false
        lastConnect?.qualityLevel = name
        send(command: EngineCommand(cmd: "setQualityLevel", qualityLevel: name))
    }

    /// Stops the helper sending video while none is shown (the window is
    /// hidden), also for a restarted helper; resumed, video restarts at a
    /// keyframe.
    func setVideoPaused(_ paused: Bool) {
        guard paused != videoPaused else { return }
        videoPaused = paused
        send(command: EngineCommand(cmd: "setVideoPaused", paused: paused))
    }

    /// Asks the device for a keyframe. Any thread; no reply.
    func requestKeyframe() {
        if let frame = try? EngineProtocol.command(EngineCommand(cmd: "requestKeyframe")) {
            write(frame)
        }
    }

    /// Sends a command and waits for its completion. Returns the RPC result
    /// (JSON) for "rpc" commands; throws the engine's or device's error.
    /// `assigned` receives the command's ID before it is sent (to match
    /// progress events). Main thread only.
    @MainActor @discardableResult
    func run(_ command: EngineCommand, assigned: ((Int64) -> Void)? = nil) async throws -> Data? {
        dispatchPrecondition(condition: .onQueue(.main))
        var command = command
        let id = nextCommandID
        nextCommandID += 1
        command.id = id
        assigned?(id)
        return try await withCheckedThrowingContinuation { continuation in
            writeLock.lock()
            let running = process != nil
            writeLock.unlock()
            guard running else {
                continuation.resume(throwing: EngineError(message: "the engine is not running"))
                return
            }
            waiting[id] = continuation
            send(command: command)
        }
    }

    /// Calls a device JSON-RPC method and decodes its result.
    @MainActor
    func call<T: Decodable>(_ method: String, params: JSONValue? = nil, as type: T.Type) async throws -> T {
        let data = try await run(EngineCommand(cmd: "rpc", method: method, params: params)) ?? Data("null".utf8)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Calls a device JSON-RPC method that returns nothing of interest.
    @MainActor
    func call(_ method: String, params: JSONValue? = nil) async throws {
        try await run(EngineCommand(cmd: "rpc", method: method, params: params))
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
