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
    /// Also exercises virtual media, the serial console and address probing
    /// through the app's models and windows.
    var exerciseExtras = false
    private var extras: [String: Any] = [:]
    private var extrasOK = false
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
        if exerciseExtras {
            Task { @MainActor [weak self] in await self?.runExtras() }
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

    @MainActor
    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// Upload, mount, eject and delete an image; type into the serial
    /// console and read the echo; probe the address with and without the
    /// right certificate pin. Each step is reported.
    @MainActor
    private func runExtras() async {
        guard let controller else { return }
        var ok = true
        func step(_ name: String, _ passed: Bool, _ detail: Any? = nil) {
            extras[name] = detail.map { ["ok": passed, "detail": $0] as [String: Any] } ?? passed
            ok = ok && passed
        }
        guard await waitUntil(10, { controller.snapshot.Phase == "connected" }) else {
            step("connected", false, controller.snapshot.Status)
            return
        }

        // Address probe, with the pinning the device library uses.
        let address = controller.address
        let identity = await AddressProbe.httpFetch(timeout: 3)(address)
        step("probe", identity?.deviceId?.isEmpty == false, identity?.deviceId ?? "no answer")
        if address.hasPrefix("https://") {
            let pin = controller.snapshot.CertSHA256 ?? ""
            step("tlsPinLearned", pin.count == 64, pin)
            let pinned = await AddressProbe.httpFetch(timeout: 3, certSHA256: pin)(address)
            step("probeWithPin", pinned != nil)
            let wrong = await AddressProbe.httpFetch(timeout: 3, certSHA256: String(repeating: "0", count: 64))(address)
            step("probeRefusesWrongPin", wrong == nil)
        }

        // Virtual media through the window's model.
        controller.showVirtualMedia()
        let media = controller.mediaModel
        let name = "selftest-\(ProcessInfo.processInfo.processIdentifier).img"
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        let size = 300 * 1024
        try? Data(repeating: 0x5A, count: size).write(to: file)
        await media.upload(file)
        step("upload", media.files.contains { $0.filename == name && $0.size == Int64(size) }, media.error ?? media.files.map(\.filename))
        if let stored = media.files.first(where: { $0.filename == name }) {
            await media.mount(stored, mode: .cdrom)
            step("mount", media.mounted?.filename == name, media.error ?? "")
            await media.eject()
            step("eject", media.mounted == nil, media.error ?? "")
            await media.delete(stored)
            step("delete", !media.files.contains { $0.filename == name }, media.error ?? "")
        }

        // Serial console: turn the extension on, type, read the echo.
        do {
            try await controller.engine.run(EngineCommand(cmd: "setExtension", text: "serial-console"))
            controller.showSerialConsole()
            try await controller.engine.run(EngineCommand(cmd: "serialSend", text: "selftest-serial\r"))
            let echoed = await waitUntil(5) { controller.serialLog.text.contains("selftest-serial") }
            step("serial", echoed, String(controller.serialLog.text.suffix(80)))
        } catch {
            step("serial", false, error.localizedDescription)
        }
        try? FileManager.default.removeItem(at: file)
        extrasOK = ok
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
            "codec": controller.currentCodec,
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
        if exerciseExtras {
            report["extras"] = extras
            report["extrasOK"] = extrasOK
        }
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
        if exerciseExtras { ok = ok && extrasOK }
        controller.shutdown()
        AppLog.flush()
        // _exit: skip atexit/static teardown while VideoToolbox and pipe
        // threads are still running (exit() can crash there).
        _exit(ok ? 0 : 1)
    }
}
