import AppKit
import CoreVideo
import JetKVMCore

/// `--selftest N`: connect, run for N seconds, print a JSON report and exit.
/// Against the emulator's test pattern it also measures latency from the
/// timestamp burned into each frame to the moment the frame is decoded.
/// `--crash-engine-after S` kills the helper mid-run to prove recovery.
final class SelfTest {
    private weak var controller: DeviceWindowController?
    private let seconds: Double
    private let crashEngineAfter: Double?
    private let snapshotPath: String?
    var injectInput = false
    private var inputInjected = false
    private let lock = NSLock()
    private var latenciesMs: [Double] = []
    private var decodedFrames = 0
    private var framesAfterCrash = 0
    private var crashed = false
    private var restartReasons: [String] = []
    private var firstFrameAt: Date?
    private let started = Date()

    init(controller: DeviceWindowController, seconds: Double, crashEngineAfter: Double?, snapshotPath: String?) {
        self.controller = controller
        self.seconds = seconds
        self.crashEngineAfter = crashEngineAfter
        self.snapshotPath = snapshotPath
        controller.onFrameDecoded = { [weak self] buffer, header in self?.frameDecoded(buffer, header) }
        controller.onRestart = { [weak self] reason in
            self?.lock.lock()
            self?.restartReasons.append(reason)
            self?.lock.unlock()
        }
    }

    func start() {
        if let crashEngineAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + crashEngineAfter) { [weak self] in
                self?.lock.lock()
                self?.crashed = true
                self?.lock.unlock()
                self?.controller?.engine.simulateCrash()
            }
        }
        if injectInput {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.inject() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.finish() }
    }

    /// Feeds synthetic AppKit events through the real view handlers: types
    /// "a", Shift+"a", and clicks the middle of the video. The Makefile
    /// checks that the emulator received them.
    private func inject() {
        guard let controller, let window = controller.window else { return }
        let view = controller.videoView!
        controller.input.setCaptured(true)
        func key(_ type: NSEvent.EventType, code: UInt16, chars: String, flags: NSEvent.ModifierFlags = []) -> NSEvent? {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                             isARepeat: false, keyCode: code)
        }
        let shiftDown = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x2)
        if let e = key(.keyDown, code: 0x00, chars: "a") { view.keyDown(with: e) }
        if let e = key(.keyUp, code: 0x00, chars: "a") { view.keyUp(with: e) }
        if let e = key(.flagsChanged, code: 0x38, chars: "", flags: shiftDown) { view.flagsChanged(with: e) }
        if let e = key(.keyDown, code: 0x00, chars: "A", flags: shiftDown) { view.keyDown(with: e) }
        if let e = key(.keyUp, code: 0x00, chars: "A", flags: shiftDown) { view.keyUp(with: e) }
        if let e = key(.flagsChanged, code: 0x38, chars: "") { view.flagsChanged(with: e) }
        let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: center, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                type == .leftMouseDown ? view.mouseDown(with: e) : view.mouseUp(with: e)
            }
        }
        inputInjected = true
    }

    private func frameDecoded(_ buffer: CVPixelBuffer, _ header: AccessUnitHeader) {
        let now = Date()
        var latency: Double?
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            if let ms = TimestampBarcode.decode(luma: base.assumingMemoryBound(to: UInt8.self), stride: stride,
                                                width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)) {
                latency = now.timeIntervalSince1970 * 1000 - Double(ms)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        lock.lock()
        decodedFrames += 1
        if firstFrameAt == nil { firstFrameAt = now }
        if crashed { framesAfterCrash += 1 }
        if let latency, latency >= 0, latency < 10_000 { latenciesMs.append(latency) }
        lock.unlock()
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }

    private func finish() {
        guard let controller else { _exit(3) }
        lock.lock()
        let decoded = decodedFrames
        let afterCrash = framesAfterCrash
        let latencies = latenciesMs
        let restarts = restartReasons
        let firstFrame = firstFrameAt.map { $0.timeIntervalSince(started) }
        lock.unlock()
        let stats = controller.decoder.snapshot()
        var report: [String: Any] = [
            "device": controller.address,
            "phase": controller.snapshot.Phase,
            "status": controller.snapshot.Status,
            "decodedFrames": decoded,
            "presentedFrames": controller.videoView.presentedFrames,
            "decodeErrors": stats.errors,
            "keyframes": stats.keyframes,
            "lastDecodeMs": stats.lastDecodeMs,
            "engineRestarts": restarts,
            "backingScale": controller.window?.backingScaleFactor ?? 0,
            "layout": ["w": controller.videoView.layout.width, "h": controller.videoView.layout.height, "nearest": controller.videoView.layout.nearest],
        ]
        if let firstFrame { report["firstFrameSeconds"] = firstFrame }
        if let p50 = percentile(latencies, 0.5), let p95 = percentile(latencies, 0.95) {
            report["encodeToDecodeMsP50"] = p50
            report["encodeToDecodeMsP95"] = p95
            report["latencySamples"] = latencies.count
        }
        if crashEngineAfter != nil { report["framesAfterEngineCrash"] = afterCrash }
        if injectInput { report["inputInjected"] = inputInjected }
        if let snapshotPath {
            report["snapshotWritten"] = controller.videoView.writeSnapshot(to: URL(fileURLWithPath: snapshotPath))
        }
        if let stats = controller.lastStats["stats"] as? [String: Any] ?? Optional(controller.lastStats), !stats.isEmpty {
            report["engineStats"] = stats
        }
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        var ok = decoded > 0 && controller.videoView.presentedFrames > 0
        if crashEngineAfter != nil { ok = ok && afterCrash > 0 && !restarts.isEmpty }
        controller.shutdown()
        // _exit: skip atexit/static teardown while VideoToolbox and pipe
        // threads are still running (exit() can crash there).
        _exit(ok ? 0 : 1)
    }
}
