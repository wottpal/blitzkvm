import AppKit
import CoreVideo
import JetKVMCore

/// One window per device: video, input capture, status line.
final class DeviceWindowController: NSWindowController, NSWindowDelegate, EngineProcessDelegate {
    let address: String
    let engine: EngineProcess
    let decoder = VideoDecoder()
    let input = InputController()
    private(set) var videoView: CaptureVideoView!
    private let statusLabel = NSTextField(labelWithString: "Starting…")
    private(set) var snapshot = SessionSnapshot(Phase: "idle", Status: "starting")
    private(set) var lastStats: [String: Any] = [:]
    private var codecName = "–"
    private var password: String?
    var offerH265: Bool
    var onFrameDecoded: ((CVPixelBuffer, AccessUnitHeader) -> Void)?
    var onRestart: ((String) -> Void)?
    private var secureInputTimer: Timer?
    private var isShutDown = false

    init(address: String, password: String?, offerH265: Bool, engineURL: URL) {
        self.address = address
        self.password = password
        self.offerH265 = offerH265
        self.engine = EngineProcess(executableURL: engineURL)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = address
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "jetkvm-device"
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior.insert(.fullScreenPrimary)
        super.init(window: window)
        window.delegate = self
        buildContent()
        engine.delegate = self
        decoder.onFrame = { [weak self] buffer, header in
            guard let self else { return }
            self.videoView.display(buffer)
            self.onFrameDecoded?(buffer, header)
        }
        input.send = { [weak self] frame in self?.engine.write(frame) }
        input.onCaptureChange = { [weak self] _ in self?.refreshStatus() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildContent() {
        guard let window, let view = CaptureVideoView(frame: window.contentLayoutRect, controller: self) else {
            fatalError("Metal is not available")
        }
        videoView = view
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(statusLabel)
        let container = NSView(frame: window.contentLayoutRect)
        view.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 22),
            statusLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            statusLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        window.contentView = container
        window.initialFirstResponder = view
    }

    func start() throws {
        try engine.start()
        engine.connect(baseURL: address, password: password, offerH265: offerH265)
        secureInputTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshStatus() }
    }

    func reconnect(offerH265: Bool? = nil) {
        if let offerH265 { self.offerH265 = offerH265 }
        decoder.reset()
        engine.connect(baseURL: address, password: password, offerH265: self.offerH265)
    }

    /// Ends the session: releases input and stops the engine helper.
    /// (Not `close()`, which is NSWindowController's and closes the window.)
    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        input.setCaptured(false)
        secureInputTimer?.invalidate()
        engine.stop()
    }

    // MARK: EngineProcessDelegate

    func engine(_ engine: EngineProcess, didReceive header: AccessUnitHeader, data: Data) {
        codecName = header.codec == .h265 ? "H.265" : "H.264"
        decoder.decode(header, annexB: data)
    }

    func engine(_ engine: EngineProcess, didUpdate snapshot: SessionSnapshot) {
        self.snapshot = snapshot
        if snapshot.Phase == "auth_failed" && password == nil {
            promptForPassword()
        }
        refreshStatus()
    }

    func engine(_ engine: EngineProcess, didUpdateStats stats: [String: Any]) {
        lastStats = stats
        refreshStatus()
    }

    func engine(_ engine: EngineProcess, didFinishCommand id: Int64, error: String?, invalid: String?) {
        if let error, !error.isEmpty { NSLog("engine command \(id) failed: \(error)") }
        if let invalid, !invalid.isEmpty { NSLog("could not type: \(invalid)") }
    }

    func engineDidRestart(_ engine: EngineProcess, reason: String) {
        decoder.reset()
        onRestart?(reason)
        refreshStatus(extra: "engine restarted (\(reason))")
    }

    private func promptForPassword() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Password for \(address)"
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.password = field.stringValue
            self.reconnect()
        }
    }

    func refreshStatus(extra: String? = nil) {
        let decoded = decoder.snapshot()
        var parts = [snapshot.Status]
        if let signal = snapshot.VideoSignal, signal != "ready", !signal.isEmpty {
            parts.append("HDMI: \(signal.replacingOccurrences(of: "_", with: " "))")
        }
        parts.append(codecName)
        if let fps = lastStats["FramesPerSecond"] as? Double { parts.append(String(format: "%.0f fps", fps)) }
        if let kbps = lastStats["BitrateKbps"] as? Double { parts.append(String(format: "%.1f Mbit/s", kbps / 1000)) }
        if let rtt = lastStats["RoundTripMs"] as? Double, rtt > 0 { parts.append(String(format: "RTT %.0f ms", rtt)) }
        parts.append(String(format: "decode %.1f ms", decoded.lastDecodeMs))
        if decoded.errors > 0 { parts.append("decode errors \(decoded.errors)") }
        if input.captured {
            parts.append(input.eventTapActive ? "⌨︎ captured incl. system shortcuts (⌃⌘ releases)" : "⌨︎ captured (⌃⌘ releases)")
            if input.secureInputActive { parts.append("⚠︎ Secure Input is on: system shortcuts stay local") }
        } else {
            parts.append("⌨︎ released (click video to capture)")
        }
        if let extra { parts.append(extra) }
        statusLabel.stringValue = parts.joined(separator: "  ·  ")
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        window?.makeFirstResponder(videoView)
        input.setCaptured(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Focus left mid-press (⌘Tab during a drag): release everything on
        // the remote so nothing stays stuck.
        input.setCaptured(false)
    }

    func windowWillClose(_ notification: Notification) {
        shutdown()
    }
}

/// The video view plus input routing.
final class CaptureVideoView: VideoView {
    private weak var controller: DeviceWindowController?
    private var trackingArea: NSTrackingArea?

    init?(frame: NSRect, controller: DeviceWindowController) {
        self.controller = controller
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func routeMouse(_ event: NSEvent) {
        guard let controller else { return }
        let point = convert(event.locationInWindow, from: nil)
        controller.input.mouse(event, at: physicalPoint(point), in: layout)
    }

    override func mouseDown(with event: NSEvent) {
        if let controller, !controller.input.captured {
            controller.input.setCaptured(true)
        }
        routeMouse(event)
    }

    override func mouseMoved(with event: NSEvent) { routeMouse(event) }
    override func mouseDragged(with event: NSEvent) { routeMouse(event) }
    override func mouseUp(with event: NSEvent) { routeMouse(event) }
    override func rightMouseDown(with event: NSEvent) { routeMouse(event) }
    override func rightMouseDragged(with event: NSEvent) { routeMouse(event) }
    override func rightMouseUp(with event: NSEvent) { routeMouse(event) }
    override func otherMouseDown(with event: NSEvent) { routeMouse(event) }
    override func otherMouseDragged(with event: NSEvent) { routeMouse(event) }
    override func otherMouseUp(with event: NSEvent) { routeMouse(event) }
    override func scrollWheel(with event: NSEvent) { controller?.input.scroll(event) }

    override func keyDown(with event: NSEvent) {
        if controller?.input.handle(event) != true { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if controller?.input.handle(event) != true { super.keyUp(with: event) }
    }

    override func flagsChanged(with event: NSEvent) {
        if controller?.input.handle(event) != true { super.flagsChanged(with: event) }
    }

    /// ⌘-shortcuts reach this before the menu bar: while captured they go to
    /// the remote (⌘Q quits the remote app, not this one).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let controller, controller.input.captured else { return super.performKeyEquivalent(with: event) }
        return controller.input.handle(event)
    }
}
