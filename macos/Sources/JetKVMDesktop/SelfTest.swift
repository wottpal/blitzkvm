import AppKit
import CoreVideo
import JetKVMCore

/// `--selftest N`: connect, run for N seconds, print a JSON report and exit.
/// Against the emulator's test pattern it also measures latency from the
/// timestamp burned into each frame to the moment the frame is decoded.
/// `--crash-engine-after S` kills the helper mid-run to prove recovery.
/// `--hide-after S` minimizes the window for 2 s and measures how soon the
/// picture resumes once it is shown again. `--max-freeze-ms N` fails the run
/// if the picture stood still longer than N ms while the window was visible
/// (a hidden window stops decoding by design, minimized or covered alike).
/// `--set-quality-after S:level,…` changes the stream quality during the run;
/// `--toggle-status-bar-after S` shows or hides the status bar (not saved).
final class SelfTest {
    private weak var controller: DeviceWindowController?
    private let seconds: Double
    private let crashEngineAfter: Double?
    private let snapshotPath: String?
    var injectInput = false
    var hideAfter: Double?
    var maxFreezeMs: Double?
    var qualityChanges: [(Double, String)] = []
    var toggleStatusBarAfter: Double?
    private var beforeToggle: [String: Any]?
    private var shownAt: Date?
    /// Stall overlay changes: seconds into the run, title (nil: hidden).
    private var overlayEvents: [(Double, String?)] = []
    private var resumedAfterShowMs: Double?
    private var inputInjected = false
    /// Also exercises virtual media, the serial console and address probing
    /// through the app's models and windows.
    var exerciseExtras = false
    /// `--setup`: the JetKVM Setup action to run (see Options.setup).
    var setupAction: String?
    var setupSnapshotPath: String?
    private var setupReport: [String: Any]?
    private var setupOK = false
    private var finished = false
    private var extras: [String: Any] = [:]
    private var extrasOK = false
    private let lock = NSLock()
    private var latenciesMs: [Double] = []
    private var decodedFrames = 0
    private var framesAfterCrash = 0
    private var crashed = false
    private var restartReasons: [String] = []
    private var firstFrameAt: Date?
    private var lastFrameAt: Date?
    /// Gaps between decoded frames over 250 ms while the window was visible:
    /// picture freezes.
    private var freezesMs: [Double] = []
    /// Time the window spent hidden (sampled every 50 ms), in total and as
    /// of the last frame.
    private var hiddenSince: Date?
    private var hiddenTotal: TimeInterval = 0
    private var hiddenAtLastFrame: TimeInterval = 0
    private var visibilityTimer: Timer?
    private let started = Date()

    init(controller: DeviceWindowController, seconds: Double, crashEngineAfter: Double?, snapshotPath: String?) {
        self.controller = controller
        self.seconds = seconds
        self.crashEngineAfter = crashEngineAfter
        self.snapshotPath = snapshotPath
        controller.capturesOnFocus = false // only inject() sends input
        // Hidden windows stop decoding: stay above other apps' windows.
        controller.window?.level = .floating
        controller.onFrameDecoded = { [weak self] buffer, header in self?.frameDecoded(buffer, header) }
        controller.onStallOverlay = { [weak self] content in
            guard let self else { return }
            self.overlayEvents.append((Date().timeIntervalSince(self.started), content?.title))
            AppLog.log("selftest: stall overlay \(content?.title ?? "hidden")")
        }
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
        if let toggleStatusBarAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + toggleStatusBarAfter) { [weak self] in
                guard let self, let c = self.controller else { return }
                self.beforeToggle = self.windowReport(c)
                AppLog.log("selftest: status bar \(c.isStatusBarVisible ? "hidden" : "shown")")
                c.setStatusBarVisible(!c.isStatusBarVisible)
            }
        }
        for (after, level) in qualityChanges {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
                AppLog.log("selftest: stream quality \(level)")
                self?.controller?.setQualityLevel(level)
            }
        }
        if let hideAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + hideAfter) { [weak self] in
                self?.controller?.window?.miniaturize(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + hideAfter + 2) { [weak self] in
                self?.controller?.window?.deminiaturize(nil)
                self?.lock.lock()
                self?.shownAt = Date()
                self?.lock.unlock()
            }
        }
        if exerciseExtras {
            Task { @MainActor [weak self] in await self?.runExtras() }
        }
        if setupAction != nil {
            Task { @MainActor [weak self] in await self?.runSetup() }
        }
        visibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.sampleVisibility() }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.finish() }
    }

    private func sampleVisibility() {
        guard let controller else { return }
        let hidden = controller.decoder.paused
        lock.lock()
        defer { lock.unlock() }
        if hidden, hiddenSince == nil {
            hiddenSince = Date()
        } else if !hidden, let since = hiddenSince {
            hiddenTotal += Date().timeIntervalSince(since)
            hiddenSince = nil
        }
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
        if let gap = visibleGap(until: now) { freezesMs.append(gap) }
        if let shownAt, resumedAfterShowMs == nil { resumedAfterShowMs = now.timeIntervalSince(shownAt) * 1000 }
        lastFrameAt = now
        hiddenAtLastFrame = hidden(until: now)
        if crashed { framesAfterCrash += 1 }
        if let latency, latency >= 0, latency < 10_000 { latenciesMs.append(latency) }
        lock.unlock()
    }

    /// Seconds the window has been hidden up to `now` (lock held).
    private func hidden(until now: Date) -> TimeInterval {
        hiddenTotal + (hiddenSince.map { now.timeIntervalSince($0) } ?? 0)
    }

    /// How long the picture has stood still since the last frame while the
    /// window was visible, in ms, if that is a freeze (lock held).
    private func visibleGap(until now: Date) -> Double? {
        guard let lastFrameAt else { return nil }
        let gap = now.timeIntervalSince(lastFrameAt) - (hidden(until: now) - hiddenAtLastFrame)
        return gap > 0.25 ? gap * 1000 : nil
    }

    private func windowReport(_ c: DeviceWindowController) -> [String: Any] {
        let content = c.window?.contentLayoutRect.size ?? .zero
        var r: [String: Any] = [
            "videoArea": "\(Int(c.videoView.bounds.width))x\(Int(c.videoView.bounds.height))",
            "windowContent": "\(Int(content.width))x\(Int(content.height))",
            "statusBar": c.isStatusBarVisible,
        ]
        if let size = c.videoView.currentVideoSize { r["remoteSize"] = "\(Int(size.width))x\(Int(size.height))" }
        return r
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }

    /// Waits for the setup sheet (it opens on connect), lets it check, runs
    /// the action, lets it check again and finishes the run.
    @MainActor private func runSetup() async {
        func until(_ seconds: Double, _ done: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !done() {
                if Date() > deadline { return false }
                try? await Task.sleep(for: .milliseconds(250))
            }
            return true
        }
        guard let action = setupAction,
              await until(30, { controller?.setup?.isSettled == true }), let model = controller?.setup else {
            setupReport = ["error": "the setup sheet didn't settle"]
            return finish()
        }
        AppLog.log("selftest: setup before \(model.report)")
        var ok = true
        switch action {
        case "check":
            break
        case "install-tailscale":
            model.installTailscale()
            try? await Task.sleep(for: .milliseconds(300))
            ok = await until(600) {
                switch model.tailscale.value {
                case .needsLogin?, .running?: return !model.tailscale.isWorking
                default: return model.tailscale.error != nil && !model.tailscale.isWorking
                }
            } && model.tailscale.error == nil
        case "login":
            model.logIn()
            try? await Task.sleep(for: .milliseconds(300))
            ok = await until(60) {
                switch model.tailscale.value {
                case .needsLogin(_?)?, .running?: return !model.tailscale.isWorking
                default: return model.tailscale.error != nil && !model.tailscale.isWorking
                }
            } && model.tailscale.error == nil
        case "install-firmware":
            model.installFirmware()
            try? await Task.sleep(for: .seconds(1))
            ok = await until(600) { !model.firmware.isWorking } && model.firmware.error == nil
        case let a where a.hasPrefix("password="):
            model.createPassword(String(a.dropFirst("password=".count)))
            try? await Task.sleep(for: .milliseconds(300))
            ok = await until(30) { !model.password.isWorking } && model.password.value == true
        default:
            ok = false
        }
        model.refresh()
        try? await Task.sleep(for: .seconds(1))
        _ = await until(60) { model.isSettled }
        // The run also proves video (after a firmware install: again).
        _ = await until(30) { [weak self] in
            guard let self else { return true }
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.decodedFrames > 0
        }
        setupReport = model.report
        setupOK = ok && model.isSettled
        AppLog.log("selftest: setup after \(model.report)")
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        guard let controller else { _exit(3) }
        lock.lock()
        let decoded = decodedFrames
        let afterCrash = framesAfterCrash
        let latencies = latenciesMs
        let restarts = restartReasons
        let firstFrame = firstFrameAt.map { $0.timeIntervalSince(started) }
        var freezes = freezesMs
        let resumed = resumedAfterShowMs
        if let gap = visibleGap(until: Date()) { freezes.append(gap) }
        let hiddenMs = hidden(until: Date()) * 1000
        lock.unlock()
        let stats = controller.decoder.snapshot()
        var report: [String: Any] = [
            "device": controller.address,
            "phase": controller.snapshot.Phase,
            "status": controller.snapshot.Status,
            "decodedFrames": decoded,
            "presentedFrames": controller.videoView.presentedFrames,
            "unchangedFrames": controller.videoView.unchangedFrames,
            "decodeErrors": stats.errors,
            "keyframes": stats.keyframes,
            "skippedUnits": stats.skipped,
            "codec": controller.currentCodec,
            "lastDecodeMs": stats.lastDecodeMs,
            "engineRestarts": restarts,
            "backingScale": controller.window?.backingScaleFactor ?? 0,
            "layout": ["w": controller.videoView.layout.width, "h": controller.videoView.layout.height, "nearest": controller.videoView.layout.nearest],
        ]
        if let firstFrame { report["firstFrameSeconds"] = firstFrame }
        report["freezes"] = ["count": freezes.count, "longestMs": freezes.max() ?? 0, "totalMs": freezes.reduce(0, +)]
        report["scalingFilter"] = controller.videoView.scalingFilter.rawValue
        if let fps = controller.snapshot.VideoFPS { report["remoteRefresh"] = fps }
        if let signal = controller.snapshot.VideoSignal { report["videoSignal"] = signal }
        report["hiddenMs"] = hiddenMs.rounded()
        if hideAfter != nil { report["resumedAfterShowMs"] = resumed ?? -1 }
        report["stallOverlay"] = overlayEvents.map { ["at": ($0.0 * 10).rounded() / 10, "title": $0.1 ?? "hidden"] as [String: Any] }
        report.merge(windowReport(controller)) { $1 }
        if let beforeToggle { report["beforeStatusBarToggle"] = beforeToggle }
        let longestFreeze = freezes.max() ?? 0
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
        if setupAction != nil {
            report["setup"] = setupReport ?? ["error": "not finished"]
            report["setupOK"] = setupOK
        }
        if let setupSnapshotPath {
            report["setupSnapshotWritten"] = controller.writeSetupSnapshot(to: URL(fileURLWithPath: setupSnapshotPath))
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
        if setupAction != nil { ok = ok && setupOK }
        if let maxFreezeMs {
            // Hidden time says nothing about freezes; too much makes the run
            // inconclusive (the intended --hide-after pause aside).
            let unintended = hiddenMs - (hideAfter == nil ? 0 : 2000)
            if unintended > seconds * 250 {
                FileHandle.standardError.write(Data("window hidden for \(Int(hiddenMs)) ms of the run: inconclusive\n".utf8))
                ok = false
            } else if longestFreeze > maxFreezeMs {
                FileHandle.standardError.write(Data("picture froze for \(Int(longestFreeze)) ms (limit \(Int(maxFreezeMs)) ms)\n".utf8))
                ok = false
            }
        }
        controller.shutdown()
        AppLog.flush()
        // _exit: skip atexit/static teardown while VideoToolbox and pipe
        // threads are still running (exit() can crash there).
        _exit(ok ? 0 : 1)
    }
}
