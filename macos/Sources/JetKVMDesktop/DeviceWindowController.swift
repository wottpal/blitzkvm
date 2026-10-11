import AppKit
import CoreVideo
import JetKVMCore
import Network

/// One window per device: video, input capture, status line.
final class DeviceWindowController: NSWindowController, NSWindowDelegate, EngineProcessDelegate {
    private(set) var device: Device
    private(set) var address: String
    let engine: EngineProcess
    let decoder = VideoDecoder()
    let input = InputController()
    private(set) var videoView: CaptureVideoView!
    private let statusLabel = NSTextField(labelWithString: "Starting…")
    private let hud = HintView()
    private let viewControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private var keyboardHintShown = false
    private(set) var snapshot = SessionSnapshot(Phase: "idle", Status: "starting")
    private(set) var lastStats: [String: Any] = [:]
    private var codecName = "–"
    /// The codec of the last access unit ("H.265", "H.264" or "–").
    var currentCodec: String {
        codecLock.lock()
        defer { codecLock.unlock() }
        return codecName
    }
    private var password: String?
    var onFrameDecoded: ((CVPixelBuffer, AccessUnitHeader) -> Void)?
    var onRestart: ((String) -> Void)?
    /// Called when a session connects (to persist device ID, last use).
    var onConnected: ((DeviceWindowController) -> Void)?
    /// The device ID became known after connecting; passes the device as it
    /// was before (its credential account may change).
    var onIdentityLearned: ((DeviceWindowController, Device) -> Void)?
    /// The pinned certificate authority was learned or cleared.
    var onCertificateChange: ((DeviceWindowController) -> Void)?
    /// Called with a password the user typed, once it has been accepted by
    /// the device (to store it in the Keychain).
    var onPasswordAccepted: ((DeviceWindowController, String) -> Void)?
    /// Supplies the current stored password on reconnect.
    var credentialProvider: ((Device) -> String?)?
    /// Called when the window closes for good.
    var onClose: ((DeviceWindowController) -> Void)?
    /// A per-device preference changed (view, mouse, codec…): persist it.
    var onPreferencesChanged: ((DeviceWindowController) -> Void)?
    private var unverifiedPassword: String?
    private let codecLock = NSLock()
    private var statusTimer: Timer?
    private var isShutDown = false
    private var wasConnected = false
    private var pathMonitor: NWPathMonitor?
    private var aspectLocked = false
    private var pendingPasteID: Int64?
    let serialLog = SerialConsoleLog()
    private(set) lazy var mediaModel = VirtualMediaModel(engine: engine)
    private var mediaWindow: VirtualMediaWindowController?
    private var serialWindow: SerialConsoleWindowController?
    private var fatalAlertShown = false
    /// The window follows the remote screen's size until the user resizes
    /// it by hand.
    private var userSizedWindow = false
    private let videoSize = Locked(CGSize.zero)
    /// Set when the first probe found no address: keep probing all of them
    /// and switch to the first that answers.
    var reprobeAddresses = false
    private var reprobeTimer: Timer?
    private lazy var displayFollower = makeDisplayFollower()

    static let statusBarHeight: CGFloat = 22

    init(device: Device, address: String, password: String?, engineURL: URL) {
        self.device = device
        self.address = address
        self.password = password
        self.engine = EngineProcess(executableURL: engineURL)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = device.name
        window.subtitle = address
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
            let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            let changed = self.videoSize.withLock { current -> Bool in
                guard current != size else { return false }
                current = size
                return true
            }
            if changed { DispatchQueue.main.async { self.videoSizeChanged() } }
        }
        input.send = { [weak self] frame in self?.engine.write(frame) }
        input.onCaptureChange = { [weak self] in self?.captureChanged($0) }
        applyPreferences()
    }

    /// Says how to get the keyboard back the first time capture engages.
    private func captureChanged(_ captured: Bool) {
        if captured && !keyboardHintShown {
            keyboardHintShown = true
            if input.eventTapActive {
                hud.show("Keyboard goes to \(device.name)  ·  press ⌃⌘ to release", for: 2.5)
            } else {
                hud.show("Keyboard goes to \(device.name)  ·  ⌃⌘ releases  ·  ⌘Space, ⌘Tab stay here until you allow Accessibility (Device menu)", for: 5)
            }
        }
        refreshStatus()
    }

    @objc private func viewControlChanged() {
        if let raw = viewControl.selectedItem?.representedObject as? String, let mode = ScalingMode(rawValue: raw) {
            pickScaling(mode)
        }
    }

    private func applyPreferences() {
        if let item = viewControl.itemArray.first(where: { $0.representedObject as? String == device.scaling.rawValue }) {
            viewControl.select(item)
        }
        input.modifierProfile = device.profile
        input.invertScroll = device.invertScroll
        videoView.scalingMode = device.scaling
        window?.invalidateCursorRects(for: videoView)
        videoView.exactPixels = device.exactPixels
        refreshStatus()
    }

    /// Takes preferences edited in the device library (addresses and
    /// credentials apply on the next connect).
    func libraryEdited(_ edited: Device) {
        let keep = device
        device = edited
        device.deviceID = keep.deviceID ?? edited.deviceID
        device.certificateSHA256 = keep.certificateSHA256 ?? edited.certificateSHA256
        applyPreferences()
        if edited.adaptiveQuality != keep.adaptiveQuality && !input.viewOnly {
            engine.setAutoQuality(edited.adaptiveQuality)
        }
    }

    /// Changes this device's preferences, applies and persists them.
    func updatePreferences(_ change: (inout Device) -> Void) {
        change(&device)
        applyPreferences()
        onPreferencesChanged?(self)
    }

    /// A view mode picked from a menu. Match Window is explained once first:
    /// it changes the remote computer's display.
    func pickScaling(_ mode: ScalingMode) {
        let explained = "matchWindowExplained"
        if mode == .matchWindow && device.scaling != .matchWindow && !UserDefaults.standard.bool(forKey: explained) {
            let alert = NSAlert()
            alert.messageText = "Match Window changes the remote computer's display resolution"
            alert.informativeText = "Each resize makes the JetKVM offer a display of the window's size, and the remote computer re-detects its display; the picture pauses for a few seconds. A Mac with another monitor treats every new size as a new display: it is no longer the main display, its desktop is empty, and the JetKVM's pointer cannot reach it. Use Match Window when the JetKVM is the computer's only display."
            alert.addButton(withTitle: "Use Match Window")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                applyPreferences() // the status bar menu shows the mode again
                return
            }
            UserDefaults.standard.set(true, forKey: explained)
        }
        setScaling(mode)
    }

    /// Changing the view mode resizes the window to suit it, or (Match
    /// Window) the remote display to suit the window.
    func setScaling(_ mode: ScalingMode) {
        updatePreferences { $0.scaling = mode }
        if !followsWindow { displayFollower.cancel() }
        if mode == .actualSize || mode == .pixelExact {
            userSizedWindow = false
            fitWindowToRemote()
        }
        matchRemoteToWindow()
    }

    /// First frame, or the remote changed resolution: show it at its natural
    /// size unless the user sized the window. With Match Window, a remote
    /// that took the window's size (rounded down to whole size steps) gets
    /// the window snapped to it, and any other size is matched to the window.
    private func videoSizeChanged() {
        window?.invalidateCursorRects(for: videoView)
        defer { matchRemoteToWindow() }
        guard let window, !window.styleMask.contains(.fullScreen), let size = videoView.currentVideoSize else { return }
        if !userSizedWindow {
            fitWindowToRemote()
        } else if followsWindow, displayFollower.requested == RemoteDisplay.Size(width: Int(size.width), height: Int(size.height)),
                  (0..<CGFloat(RemoteDisplay.widthStep)).contains(videoView.bounds.width - size.width),
                  (0..<CGFloat(RemoteDisplay.heightStep)).contains(videoView.bounds.height - size.height) {
            var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height + Self.statusBarHeight))
            frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
            window.setFrame(frame, display: true)
        }
    }

    // MARK: Match Window

    /// The remote display follows the window (not in view-only sessions:
    /// it changes the device's EDID).
    private var followsWindow: Bool { device.scaling == .matchWindow && !input.viewOnly }

    private func makeDisplayFollower() -> DisplayFollower {
        let follower = DisplayFollower(engine: engine)
        follower.currentSize = { [weak self] in
            self?.videoView.currentVideoSize.map { RemoteDisplay.Size(width: Int($0.width), height: Int($0.height)) }
        }
        follower.isEnabled = { [weak self] in self?.followsWindow ?? false }
        follower.onResize = { [weak self] size in
            guard let self else { return }
            self.hud.show("Resizing \(self.device.name)'s display to \(size)", for: 3)
        }
        follower.onError = { [weak self] in self?.refreshStatus(extra: $0) }
        return follower
    }

    /// Asks the device for a display mode of the video area's size once
    /// resizing settles (also after full screen and zoom).
    private func matchRemoteToWindow() {
        guard followsWindow, snapshot.Phase == "connected", let window, !window.inLiveResize,
              let current = videoView.currentVideoSize else { return }
        let size = RemoteDisplay.size(fitting: Double(videoView.bounds.width), Double(videoView.bounds.height))
        if size != RemoteDisplay.Size(width: Int(current.width), height: Int(current.height)) {
            // The window drives the remote from now on.
            userSizedWindow = true
        }
        displayFollower.request(size)
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
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.addSubview(statusLabel)
        viewControl.controlSize = .mini
        viewControl.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        viewControl.translatesAutoresizingMaskIntoConstraints = false
        viewControl.target = self
        bar.addSubview(viewControl)
        viewControl.action = #selector(viewControlChanged)
        for mode in ScalingMode.allCases {
            viewControl.addItem(withTitle: mode.shortTitle)
            viewControl.lastItem?.representedObject = mode.rawValue
        }
        viewControl.toolTip = "How the remote screen is sized in the window"
        hud.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: window.contentLayoutRect)
        view.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        container.addSubview(bar)
        container.addSubview(hud)
        NSLayoutConstraint.activate([
            hud.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hud.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            hud.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
            viewControl.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            viewControl.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: Self.statusBarHeight),
            statusLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: viewControl.leadingAnchor, constant: -8),
            statusLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        window.contentView = container
        window.initialFirstResponder = view
    }

    /// Probes all of the device's addresses every few seconds while not
    /// connected and moves the session to the first one that answers (the
    /// first probe found none, e.g. the VPN came up later).
    private func startReprobing() {
        guard reprobeAddresses, device.addresses.count > 1, reprobeTimer == nil else { return }
        reprobeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.snapshot.Phase == "connected" || self.isShutDown {
                self.reprobeTimer?.invalidate()
                self.reprobeTimer = nil
                return
            }
            let device = self.device
            Task { @MainActor in
                let result = await AddressProbe.choose(addresses: device.addresses, expectedDeviceID: device.deviceID,
                                                       fetch: AddressProbe.httpFetch(certSHA256: device.certificateSHA256, log: { AppLog.log($0) }))
                guard case .success(let (address, _)) = result, address != self.address, self.snapshot.Phase != "connected" else { return }
                AppLog.log("\(device.name) answers at \(address); switching from \(self.address)")
                self.address = address
                self.window?.subtitle = address
                self.reconnect()
            }
        }
    }

    func start() throws {
        try engine.start()
        engine.connect(baseURL: address, password: password, deviceID: device.deviceID, certSHA256: device.certificateSHA256, autoQuality: device.adaptiveQuality && !input.viewOnly,
                       qualityLevel: input.viewOnly ? nil : device.qualityLevel)
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.input.ensureEventTap()
            self?.refreshStatus()
        }
        startPathMonitor()
        startReprobing()
    }

    func reconnect() {
        if unverifiedPassword == nil, let stored = credentialProvider?(device) {
            // Pick up a password changed in the device library meanwhile.
            password = stored
        }
        pendingPasteID = nil
        fatalAlertShown = false
        decoder.reset()
        engine.connect(baseURL: address, password: password, deviceID: device.deviceID, certSHA256: device.certificateSHA256, autoQuality: device.adaptiveQuality && !input.viewOnly,
                       qualityLevel: input.viewOnly ? nil : device.qualityLevel)
    }

    func showVirtualMedia() {
        if mediaWindow == nil {
            mediaWindow = VirtualMediaWindowController(model: mediaModel, deviceName: device.name)
            mediaWindow?.window?.center()
        }
        mediaWindow?.showWindow(nil)
        Task { await mediaModel.refresh() }
    }

    func showSerialConsole() {
        if serialWindow == nil {
            serialWindow = SerialConsoleWindowController(log: serialLog, engine: engine, deviceName: device.name)
            serialWindow?.window?.center()
        }
        serialWindow?.update(snapshot: snapshot)
        serialWindow?.showWindow(nil)
    }

    /// Switches the device's extension port (ATX, DC power, serial console).
    func setExtension(_ id: String) {
        Task { @MainActor in
            do {
                try await engine.run(EngineCommand(cmd: "setExtension", text: id))
            } catch {
                refreshStatus(extra: error.localizedDescription)
            }
        }
    }

    /// Ends the session: releases input and stops the engine helper.
    /// (Not `close()`, which is NSWindowController's and closes the window.)
    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        displayFollower.cancel()
        input.setCaptured(false)
        statusTimer?.invalidate()
        reprobeTimer?.invalidate()
        pathMonitor?.cancel()
        mediaWindow?.close()
        serialWindow?.close()
        engine.stop()
        decoder.reset()
    }

    /// When the network comes back (Wi-Fi switch, VPN up, wake from sleep),
    /// reconnect at once instead of waiting out the retry backoff.
    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        var lastStatus: NWPath.Status?
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                defer { lastStatus = path.status }
                // Only shorten a retry already in progress: never reconnect
                // after a takeover (it would kick the other user) or an
                // auth failure (it would count toward the login lockout).
                let retrying = ["reconnecting", "disconnected", "connecting"].contains(self.snapshot.Phase)
                if path.status == .satisfied, lastStatus != nil, lastStatus != .satisfied, retrying {
                    self.engine.send(command: EngineCommand(cmd: "reconnect"))
                }
            }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
    }

    // MARK: Commands

    func sendRPC(_ method: String, params: JSONValue? = nil) {
        engine.send(command: EngineCommand(cmd: "rpc", method: method, params: params))
    }

    func paste(_ text: String) {
        pendingPasteID = engine.send(command: EngineCommand(cmd: "paste", text: text))
        refreshStatus()
    }

    func cancelPaste() {
        engine.send(command: EngineCommand(cmd: "cancelPaste"))
    }

    /// Resizes the window to show the remote screen at its natural size: one
    /// remote pixel per point (pixel for pixel in that mode), or as large as
    /// fits the screen, keeping its aspect ratio. Keeps the window on screen.
    func fitWindowToRemote() {
        guard let window, !window.styleMask.contains(.fullScreen), let screen = window.screen ?? NSScreen.main,
              let size = videoView.currentVideoSize else { return }
        let visible = screen.visibleFrame
        let available = window.contentRect(forFrameRect: visible).size
        guard let content = preferredContentSize(videoWidth: Int(size.width), videoHeight: Int(size.height),
                                                 pointScale: Double(window.backingScaleFactor), mode: videoView.scalingMode,
                                                 available: (Double(available.width), Double(available.height)),
                                                 extraHeight: Double(Self.statusBarHeight)) else { return }
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: content.width, height: content.height))
        // Grow around the current center, then move fully onto the screen.
        frame.origin.x = window.frame.midX - frame.width / 2
        frame.origin.y = window.frame.maxY - frame.height
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: true, animate: false)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        userSizedWindow = true
        matchRemoteToWindow()
    }

    func windowDidResize(_ notification: Notification) {
        matchRemoteToWindow()
    }

    /// Sets the content size and keeps it (no automatic fit to the remote).
    func setContentSizeKeepingIt(_ size: NSSize) {
        userSizedWindow = true
        window?.setContentSize(size)
    }

    /// Automatic quality: the engine adapts the stream to the link.
    func setAdaptiveQuality(_ on: Bool) {
        guard !input.viewOnly else { return } // view-only never changes device settings
        let current = snapshot.QualityLevel
        updatePreferences {
            $0.adaptiveQuality = on
            // Off keeps what automatic had chosen (the engine does the same).
            if !on, let current, !current.isEmpty { $0.qualityLevel = current }
        }
        engine.setAutoQuality(on)
    }

    /// Fixes the stream quality at a ladder level (pkg/session
    /// autoquality.go) and turns automatic off. Live on firmware with the
    /// encoder patch; stock firmware restarts its encoder for a new factor.
    func setQualityLevel(_ name: String) {
        guard !input.viewOnly else { return }
        updatePreferences {
            $0.adaptiveQuality = false
            $0.qualityLevel = name
        }
        engine.setQualityLevel(name)
    }

    /// Keeps the video area's shape matching the remote screen while the
    /// window is resized (see windowWillResize).
    func lockAspect(_ on: Bool) {
        aspectLocked = on
        if on { fitWindowToRemote() }
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard aspectLocked, let size = videoView.currentVideoSize, size.width > 0 else { return frameSize }
        let bar = Self.statusBarHeight
        var content = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        content.height = (content.width * size.height / size.width).rounded() + bar
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: content)).size
    }

    var isAspectLocked: Bool { aspectLocked }

    // MARK: EngineProcessDelegate

    /// Called on the engine's I/O queue.
    func engine(_ engine: EngineProcess, didReceive header: AccessUnitHeader, data: Data) {
        codecLock.lock()
        codecName = header.codec == .h265 ? "H.265" : "H.264"
        codecLock.unlock()
        decoder.decode(header, annexB: data)
    }

    func engine(_ engine: EngineProcess, didUpdate snapshot: SessionSnapshot) {
        self.snapshot = snapshot
        if snapshot.Phase == "auth_failed" && !snapshot.Status.contains("locked") {
            // Wrong, empty or changed password: always ask (the engine has
            // stopped retrying). A lockout (429) must not trigger more tries.
            unverifiedPassword = nil
            promptForPassword()
        }
        if snapshot.Phase == "connected" && !wasConnected {
            wasConnected = true
            matchRemoteToWindow()
            if let accepted = unverifiedPassword {
                unverifiedPassword = nil
                onPasswordAccepted?(self, accepted)
            }
            device.lastConnected = Date()
            onConnected?(self)
        } else if snapshot.Phase != "connected" {
            wasConnected = false
        }
        // The ID loads in the background after connecting.
        if snapshot.Phase == "connected", let id = snapshot.DeviceID, !id.isEmpty, device.deviceID == nil {
            let before = device
            device.deviceID = id
            engine.pin(deviceID: id)
            onIdentityLearned?(self, before)
        }
        // https: the device CA seen on first connect is pinned from now on.
        if snapshot.Phase == "connected", let cert = snapshot.CertSHA256, !cert.isEmpty, device.certificateSHA256 == nil {
            device.certificateSHA256 = cert
            engine.pin(certSHA256: cert)
            onCertificateChange?(self)
        }
        if snapshot.Phase == "fatal_error" {
            showFatal(snapshot.Status)
        }
        serialWindow?.update(snapshot: snapshot)
        refreshStatus()
    }

    /// The engine stops on these; explain, and for a changed certificate
    /// let the user trust the new one (e.g. after resetting it on the device).
    private func showFatal(_ status: String) {
        guard !fatalAlertShown, let window else { return }
        fatalAlertShown = true
        let alert = NSAlert()
        alert.alertStyle = .critical
        if status.contains("certificate changed") {
            alert.messageText = "\(device.name) presented a different certificate"
            alert.informativeText = "Someone may be intercepting the connection, or the device's HTTPS certificate was regenerated. No password was sent. Trust the new certificate only if you changed it yourself."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Trust New Certificate")
        } else {
            alert.messageText = "Stopped connecting to \(device.name)"
            alert.informativeText = status.prefix(1).uppercased() + status.dropFirst() + ". Check the address in the device library."
            alert.addButton(withTitle: "OK")
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertSecondButtonReturn else { return }
            self.device.certificateSHA256 = nil
            self.onCertificateChange?(self)
            self.reconnect()
        }
    }

    func engine(_ engine: EngineProcess, didReceiveSerial text: String) {
        serialLog.append(text)
    }

    func engine(_ engine: EngineProcess, didUpdateUpload progress: UploadProgress) {
        mediaModel.progress(progress)
    }

    func engine(_ engine: EngineProcess, didUpdateStats stats: [String: Any]) {
        lastStats = stats
        refreshStatus()
    }

    func engine(_ engine: EngineProcess, didFinishCommand id: Int64, error: String?, invalid: String?) {
        if id == pendingPasteID {
            pendingPasteID = nil
            if let invalid, !invalid.isEmpty {
                refreshStatus(extra: "could not type: \(invalid)")
                return
            }
        }
        if let error, !error.isEmpty {
            refreshStatus(extra: error)
        }
    }

    func engineDidRestart(_ engine: EngineProcess, reason: String) {
        pendingPasteID = nil
        decoder.reset()
        onRestart?(reason)
        refreshStatus(extra: "engine restarted (\(reason))")
    }

    private func promptForPassword() {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Password for \(device.name)"
        alert.informativeText = "Saved in your Keychain for this device."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.password = field.stringValue
            // Stored only once the device accepts it.
            self.unverifiedPassword = field.stringValue
            self.reconnect()
        }
    }

    func refreshStatus(extra: String? = nil) {
        let decoded = decoder.snapshot()
        var parts = [snapshot.Status]
        if let signal = snapshot.VideoSignal, signal != "ready", !signal.isEmpty {
            parts.append("HDMI: \(signal.replacingOccurrences(of: "_", with: " "))")
        }
        if let size = videoView.currentVideoSize {
            let layout = videoView.layout
            let percent = layout.width > 0 ? Int((layout.width / size.width / videoView.pointScale * 100).rounded()) : 0
            parts.append("\(Int(size.width))×\(Int(size.height)) at \(percent)%")
        }
        codecLock.lock()
        parts.append(codecName)
        codecLock.unlock()
        if let level = snapshot.QualityLevel, !level.isEmpty {
            parts.append(snapshot.AutoQuality == true ? "quality \(level) (auto)" : "quality \(level)")
        }
        if let fps = lastStats["FramesPerSecond"] as? Double { parts.append(String(format: "%.0f fps", fps)) }
        if let kbps = lastStats["BitrateKbps"] as? Double { parts.append(String(format: "%.1f Mbit/s", kbps / 1000)) }
        if let rtt = lastStats["RoundTripMs"] as? Double, rtt > 0 { parts.append(String(format: "RTT %.0f ms", rtt)) }
        if let lost = lastStats["PacketsLost"] as? Int, lost > 0 { parts.append("lost \(lost)") }
        parts.append(String(format: "decode %.1f ms", decoded.lastDecodeMs))
        if decoded.errors > 0 { parts.append("decode errors \(decoded.errors)") }
        if decoder.paused { parts.append("paused (hidden)") }
        if snapshot.PasteInProgress == true || pendingPasteID != nil { parts.append("pasting…") }
        if input.viewOnly {
            parts.append("view only")
        } else if input.captured {
            let captured = input.eventTapActive ? "captured incl. system shortcuts" : "captured (system shortcuts stay local: allow Accessibility)"
            parts.append("input \(captured) (⌃⌘ releases)")
            if input.secureInputActive { parts.append("⚠︎ Secure Input is on: system shortcuts stay local") }
        } else {
            parts.append("input released (click the screen to capture)")
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

    /// Hidden windows (another tab in front, minimized, covered) stay
    /// connected but stop decoding; they resume at the next keyframe.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        decoder.paused = !window.occlusionState.contains(.visible)
        refreshStatus()
    }

    /// In full screen the menu bar (and with it the window's title bar and
    /// buttons) slides in when the pointer rests at the top edge, so full
    /// screen can be left with the mouse. The Dock stays hidden: the bottom
    /// edge belongs to the remote.
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        [.fullScreen, .hideDock, .autoHideMenuBar]
    }

    func windowWillClose(_ notification: Notification) {
        shutdown()
        onClose?(self)
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

    /// Hovering anywhere over the remote picture puts the remote pointer
    /// there, also while another app is active.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    /// A click into an inactive window also reaches the remote.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Over the remote picture only the remote pointer shows: the local one
    /// is invisible there (AppKit restores it outside the rect and while the
    /// window is not key).
    private static let invisibleCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in true },
                                                  hotSpot: .zero)

    override func resetCursorRects() {
        let l = currentLayout()
        let scale = pointScale
        guard l.width > 0, l.height > 0, scale > 0 else { return }
        // Physical pixels, origin top-left -> view points, origin bottom-left.
        let rect = NSRect(x: l.x / scale, y: bounds.height - (l.y + l.height) / scale,
                          width: l.width / scale, height: l.height / scale).intersection(bounds)
        if !rect.isEmpty { addCursorRect(rect, cursor: Self.invisibleCursor) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    private func routeMouse(_ event: NSEvent) {
        guard let controller else { return }
        let point = convert(event.locationInWindow, from: nil)
        let physical = physicalPoint(point)
        if overflows {
            // A remote screen larger than the view pans with the pointer:
            // at the view's left edge its left edge shows, and so on.
            let fx = bounds.width > 0 ? Double(point.x / bounds.width) : 0.5
            let fy = bounds.height > 0 ? Double(1 - point.y / bounds.height) : 0.5
            pan = (min(max(fx, 0), 1), min(max(fy, 0), 1))
        }
        controller.input.mouse(event, at: physical, in: currentLayout())
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller else { return }
        if !controller.input.captured {
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

/// A transient hint over the video (how to release capture and the like).
final class HintView: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        alphaValue = 0
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Never takes clicks from the video.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ text: String, for seconds: TimeInterval) {
        label.stringValue = text
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; animator().alphaValue = 1 }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { $0.duration = 0.4; self?.animator().alphaValue = 0 }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
