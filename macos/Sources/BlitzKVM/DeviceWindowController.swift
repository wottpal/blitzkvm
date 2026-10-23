import AppKit
import Carbon.HIToolbox
import CoreVideo
import JetKVMCore
import Network
import SwiftUI

/// One window per device: video, input capture, status line.
final class DeviceWindowController: NSWindowController, NSWindowDelegate, EngineProcessDelegate {
    private(set) var device: Device
    private(set) var address: String
    let engine: EngineProcess
    let decoder = VideoDecoder()
    let audio = AudioPlayer()
    let input = InputController()
    /// Game Mode's pointer lock, held while its relative mouse is active.
    let pointerLock = PointerLock()
    private(set) lazy var gameModeBinding = GameModeBinding(input: input, lock: pointerLock)
    /// --game-mode (self-tests, latency probe): on for this window, not saved.
    var gameModeOverride: Bool? {
        didSet { applyPreferences() }
    }
    private var gameModeHintShown = false
    private var sleepObservers: [NSObjectProtocol] = []
    /// Asks for still refreshes where the firmware leaves them to the app.
    let stillRefresh: StillRefresh
    private(set) var videoView: CaptureVideoView!
    private let statusLabel = NSTextField(labelWithString: "Starting…")
    private let hud = HintView()
    private let stallOverlay = StallOverlay()
    private let statusBar = NSView()
    private var statusBarHeightConstraint: NSLayoutConstraint!
    private let viewControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private var keyboardHintShown = false
    private var captureHintShown = false
    private(set) var snapshot = SessionSnapshot(Phase: "idle", Status: "starting")
    private(set) var lastStats: [String: Any] = [:]
    // Video watchdog (main thread): received, decoded and presented counts
    // at the last stats tick, and seconds without progress.
    private var watchedReceived = 0
    private var watchedDecoded = 0
    private var watchedPresented = 0
    private var decodeStalledFor = 0
    private var renderStalledFor = 0
    private var codecName = "–"
    /// The codec of the last access unit ("H.265", "H.264" or "–").
    var currentCodec: String {
        codecLock.lock()
        defer { codecLock.unlock() }
        return codecName
    }
    private var password: String?
    var onFrameDecoded: ((CVPixelBuffer, AccessUnitHeader) -> Void)?
    /// The stall overlay appeared, changed or went away (nil).
    var onStallOverlay: ((StallOverlay.Content?) -> Void)?
    var onRestart: ((String) -> Void)?
    /// Called when a session connects (to persist device ID, last use).
    var onConnected: ((DeviceWindowController) -> Void)?
    /// The device ID became known after connecting; passes the device as it
    /// was before (its credential account may change).
    var onIdentityLearned: ((DeviceWindowController, Device) -> Void)?
    /// The pinned certificate authority was learned or cleared.
    var onCertificateChange: ((DeviceWindowController) -> Void)?
    /// Called with a password the user typed, once it has been accepted by
    /// the device, or nil once the device has none (for the Keychain).
    var onPasswordAccepted: ((DeviceWindowController, String?) -> Void)?
    /// Supplies the current stored password on reconnect.
    var credentialProvider: ((Device) -> String?)?
    /// Called when the window closes for good.
    var onClose: ((DeviceWindowController) -> Void)?
    /// A per-device preference changed (view, mouse, codec…): persist it.
    var onPreferencesChanged: ((DeviceWindowController) -> Void)?
    /// An address was added (the JetKVM's tailnet name): persist it.
    var onAddressesChanged: ((DeviceWindowController) -> Void)?
    /// JetKVM Setup checked the device: persist the summary.
    var onSetupChecked: ((DeviceWindowController, SetupSummary) -> Void)?
    /// Clipboard sync was set up, turned on or off, or removed: persist it.
    var onClipboardChanged: ((DeviceWindowController) -> Void)?
    /// Clipboard sync's state as the engine reports it ("off" until it runs).
    var clipboardLive = ClipboardLive()
    /// Opens the setup sheet once the session connects.
    var showsSetupOnConnect = false
    private var setupModel: JetKVMSetupModel?
    private var setupSheet: NSWindow?
    /// The Tailscale relay the video goes through, when it isn't direct.
    private var tailscaleRelay: String?
    private var relayCheckedAt: Date?
    private var unverifiedPassword: String?
    private let codecLock = NSLock()
    private var statusTimer: Timer?
    private var stallTimer: Timer?
    /// When the current stall began (uptime ns), and when the session last
    /// connected or the remote display was last asked to resize.
    private var stallSince: UInt64?
    private var connectedAt: UInt64 = 0
    private var resizeRequest: (at: UInt64, mode: RemoteDisplay.Mode)?
    /// When the app asked the JetKVM to restart (uptime ns); the overlay says
    /// so until the session is back.
    private var restartedAt: UInt64?
    /// The device's capture buffer size (getVideoEncoderParams), which bounds
    /// Match Window's modes; stock firmware's until the device says more.
    private var captureMaxBytes = RemoteDisplay.defaultCaptureMaxBytes
    private var slowLinkHintShown = false
    private var isShutDown = false
    private var wasConnected = false
    private var pathMonitor: NWPathMonitor?
    private var aspectLocked = false
    private var pendingPasteID: Int64?
    /// The paste of another app's clipboard on its way (pasteFromApp).
    private var appPasteID: Int64?
    let serialLog = SerialConsoleLog()
    private(set) lazy var mediaModel = VirtualMediaModel(engine: engine)
    private var mediaWindow: VirtualMediaWindowController?
    private var serialWindow: SerialConsoleWindowController?
    private var fatalAlertShown = false
    /// The window follows the remote screen's size until the user resizes
    /// it by hand.
    private var userSizedWindow = false
    private let videoSize = Locked(CGSize.zero)
    /// While the remote display switches to a new size, the host sends black
    /// frames: the last picture stays up until one of the new size arrives
    /// (or the deadline, uptime ns, passes).
    private let displayHold = Locked<(size: CGSize, until: UInt64)?>(nil)
    /// When a frame last reached the view (uptime ns).
    private let shownAt = Locked<UInt64>(0)
    /// False when the first probe found no address answering and the window
    /// connects to the first one anyway (set before start()).
    var addressAnswered = true
    /// Which address the session uses as the Mac moves between networks
    /// (from start()).
    private var roaming: AddressRoaming!
    private var roamingProbe: Task<Void, Never>?
    /// A more preferred address answered while connected: the move waits
    /// for a pause (see quietForMove).
    private var pendingMove: (address: String, at: TimeInterval)?
    private var lastNetworkKey: String?
    /// When input last went to the remote (system uptime, seconds).
    private var lastInputAt: TimeInterval = 0
    /// The window moved its session to another address (self-test).
    var onAddressMove: ((String) -> Void)?
    private lazy var displayFollower = makeDisplayFollower()

    static let statusBarHeight: CGFloat = 22

    /// View › Show Status Bar, for all device windows.
    static var showsStatusBar: Bool {
        get { UserDefaults.standard.object(forKey: "showStatusBar") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showStatusBar") }
    }

    /// View › Scaling Filter, for all device windows.
    static var scalingFilter: ScalingFilter {
        get { UserDefaults.standard.string(forKey: "scalingFilter").flatMap(ScalingFilter.init(rawValue:)) ?? .automatic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "scalingFilter") }
    }

    /// --scaling-filter (self-tests): instead of the saved choice.
    var scalingFilterOverride: ScalingFilter? {
        didSet { videoView?.scalingFilter = scalingFilterOverride ?? Self.scalingFilter }
    }

    /// View › Local Pointer, for all device windows.
    static var localPointer: LocalPointer {
        get { UserDefaults.standard.string(forKey: "localPointer").flatMap(LocalPointer.init(rawValue:)) ?? .hidden }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "localPointer") }
    }

    /// View › Play Audio, for all device windows.
    static var playsAudio: Bool {
        get { UserDefaults.standard.object(forKey: "playAudio") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "playAudio") }
    }

    /// Self-tests: instead of the saved choice (set before start()).
    var playsAudioOverride: Bool?
    var playsAudio: Bool { playsAudioOverride ?? Self.playsAudio }

    /// Plays the device's audio or stops it (View › Play Audio).
    func setPlaysAudio(_ on: Bool) {
        audio.setEnabled(on)
        engine.setAudio(on)
    }

    /// --local-pointer (self-tests): instead of the saved choice.
    var localPointerOverride: LocalPointer? {
        didSet { videoView?.localPointer = localPointerOverride ?? Self.localPointer }
    }

    /// The status bar's current height (0 while hidden).
    private var barHeight: CGFloat { statusBar.isHidden ? 0 : Self.statusBarHeight }
    var isStatusBarVisible: Bool { !statusBar.isHidden }

    init(device: Device, address: String, password: String?, engineURL: URL) {
        self.device = device
        self.address = address
        self.password = password
        let engine = EngineProcess(executableURL: engineURL)
        self.engine = engine
        self.stillRefresh = StillRefresh(engine: engine)
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
            self.onFrameDecoded?(buffer, header)
            let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            let now = DispatchTime.now().uptimeNanoseconds
            let held = self.displayHold.withLock { hold -> Bool in
                guard let h = hold else { return false }
                if h.size == size || now > h.until { hold = nil }
                return hold != nil
            }
            guard !held else { return }
            let shown = self.videoView.display(buffer)
            // The encoder's re-coding of a still picture is no change to refresh.
            self.stillRefresh.frameShown(width: Int(size.width), height: Int(size.height),
                                         changed: shown.visible, keyframe: header.keyframe)
            self.shownAt.withLock { $0 = now }
            let changed = self.videoSize.withLock { current -> Bool in
                guard current != size else { return false }
                current = size
                return true
            }
            if changed { DispatchQueue.main.async { self.videoSizeChanged() } }
        }
        decoder.onKeyframeNeeded = { [weak self] in self?.engine.requestKeyframe() }
        input.send = { [weak self] frame in
            guard let self else { return }
            self.engine.write(frame)
            self.inputSent(keysHeld: self.input.keysHeld)
        }
        input.onCaptureChange = { [weak self] in self?.captureChanged($0) }
        input.localShortcuts = { MainActor.assumeIsolated { LocalShortcuts.shared.shortcuts } }
        input.onPasteFromApp = { [weak self] in MainActor.assumeIsolated { self?.pasteFromApp() == true } }
        applyPreferences()
        // The cursor comes back before the Mac sleeps or the user switches away.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            sleepObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.releasePointerLock()
            })
        }
    }

    /// Game Mode › Sensitivity (Settings), for all device windows.
    static let gameModeSensitivityKey = "gameModeSensitivity"
    static var gameModeSensitivity: Double {
        let value = UserDefaults.standard.double(forKey: gameModeSensitivityKey)
        return value > 0 ? min(max(value, 0.25), 4) : 1
    }

    /// Game Mode for this window (an override, else the device's setting);
    /// never for view-only windows.
    var isGameMode: Bool { !input.viewOnly && (gameModeOverride ?? device.isGameMode) }

    /// Device › Game Mode: saved for the device and applied at once.
    func setGameMode(_ on: Bool) {
        guard !input.viewOnly else { return }
        gameModeOverride = nil
        updatePreferences { $0.isGameMode = on }
        if !on { releasePointerLock() }
    }

    /// Gives the cursor back and ends a capture that relied on it (a
    /// relative mouse without the lock would move nothing and click blindly).
    /// Desktop mode is untouched: nothing is locked there.
    func releasePointerLock() {
        if input.relativeActive { input.setCaptured(false) }
        gameModeBinding.stop()
    }

    /// The video view's center in global display coordinates, origin at the
    /// top left of the primary screen (what CGWarpMouseCursorPosition takes).
    private func videoCenter() -> CGPoint {
        guard let window, let view = videoView else { return .zero }
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        let primaryHeight = NSScreen.screens.first?.frame.height ?? rect.maxY
        return CGPoint(x: rect.midX, y: primaryHeight - rect.midY)
    }

    /// Input went to the remote: the still refresh waits for the typing to
    /// pause, and the picture keeps presenting for its echo.
    func inputSent(keysHeld: Bool) {
        lastInputAt = ProcessInfo.processInfo.systemUptime
        stillRefresh.inputSent(keysHeld: keysHeld)
        videoView.inputSent()
    }

    /// Says how to get the keyboard back the first time capture engages.
    private func captureChanged(_ captured: Bool) {
        if captured { input.sensitivity = Self.gameModeSensitivity }
        gameModeBinding.captureChanged(captured, center: videoCenter())
        if pointerLock.engaged && !gameModeHintShown {
            gameModeHintShown = true
            keyboardHintShown = true
            hud.show("Game Mode: mouse locked  ·  ⌃⌘ releases", for: 3)
        } else if captured && !keyboardHintShown {
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
        input.gameMode = isGameMode // ends a capture first when it changes
        input.sensitivity = Self.gameModeSensitivity
        videoView.scalingMode = device.scaling
        videoView.matchScale = device.matchScale
        videoView.scalingFilter = scalingFilterOverride ?? Self.scalingFilter
        videoView.localPointer = localPointerOverride ?? Self.localPointer
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
        device.clipboardSync = keep.clipboardSync // JetKVM Setup owns it
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

    /// Match Window: window points per remote pixel (Device.matchScale).
    func setMatchScale(_ scale: Double) {
        updatePreferences { $0.matchScale = scale }
        matchRemoteToWindow()
    }

    /// Match Window: a fixed refresh rate, or nil for the largest picture.
    func setMatchRefresh(_ refresh: Int?) {
        updatePreferences { $0.matchWindowRefresh = refresh }
        matchRemoteToWindow()
    }

    /// The mode this window asks for at `refresh` (nil: Automatic).
    func matchMode(refresh: Int?) -> RemoteDisplay.Mode {
        let scale = device.matchScale
        return RemoteDisplay.mode(fitting: Double(videoView.bounds.width) / scale, Double(videoView.bounds.height) / scale,
                                  refresh: refresh, captureMaxBytes: captureMaxBytes)
    }

    /// The window's full size in remote pixels (what 1:1 would need).
    var matchFullSize: RemoteDisplay.Size {
        let scale = device.matchScale
        return RemoteDisplay.Size(width: Int(Double(videoView.bounds.width) / scale) / RemoteDisplay.widthStep * RemoteDisplay.widthStep,
                                  height: Int(Double(videoView.bounds.height) / scale) / RemoteDisplay.heightStep * RemoteDisplay.heightStep)
    }

    /// Learns the device's capture buffer size (fork firmware with D10
    /// reports it) and matches the window again if it allows more.
    private func learnCaptureLimit() {
        Task { @MainActor in
            struct Status: Decodable { var captureMaxBytes: Int? }
            guard let status = try? await engine.call("getVideoEncoderParams", as: Status.self),
                  let bytes = status.captureMaxBytes, bytes != captureMaxBytes else { return }
            captureMaxBytes = bytes
            matchRemoteToWindow()
        }
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
        let scale = CGFloat(device.matchScale) // window points per remote pixel
        if !userSizedWindow {
            fitWindowToRemote()
        } else if followsWindow, displayFollower.requested?.size == RemoteDisplay.Size(width: Int(size.width), height: Int(size.height)),
                  (0..<CGFloat(RemoteDisplay.widthStep) * scale).contains(videoView.bounds.width - size.width * scale),
                  (0..<CGFloat(RemoteDisplay.heightStep) * scale).contains(videoView.bounds.height - size.height * scale) {
            let content = NSRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale + barHeight)
            var frame = window.frameRect(forContentRect: content)
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
        follower.currentMode = { [weak self] in
            guard let self, let size = self.videoView.currentVideoSize else { return nil }
            let fps = Int((self.snapshot.VideoFPS ?? 60).rounded())
            return RemoteDisplay.Mode(RemoteDisplay.Size(width: Int(size.width), height: Int(size.height)), refresh: fps)
        }
        follower.isEnabled = { [weak self] in self?.followsWindow ?? false }
        // Keep the picture through the switch; the stall overlay explains
        // the pause.
        follower.onResize = { [weak self] mode in
            guard let self else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            self.resizeRequest = (now, mode)
            self.displayHold.withLock { $0 = (CGSize(width: mode.size.width, height: mode.size.height), now + 8_000_000_000) }
            if mode.refresh < 60 && self.device.matchWindowRefresh == nil && !self.slowLinkHintShown {
                self.slowLinkHintShown = true
                self.hud.show("Full resolution: \(mode.size) at \(mode.refresh) Hz  ·  View › Match Window Refresh trades size for up to 120 Hz", for: 5)
            }
        }
        follower.onError = { [weak self] in self?.refreshStatus(extra: $0) }
        return follower
    }

    /// Asks the device for a display mode of the video area's size once
    /// resizing settles (also after full screen and zoom).
    private func matchRemoteToWindow() {
        guard followsWindow, snapshot.Phase == "connected", let window, !window.inLiveResize,
              let current = videoView.currentVideoSize else { return }
        let mode = matchMode(refresh: device.matchWindowRefresh)
        if mode.size != RemoteDisplay.Size(width: Int(current.width), height: Int(current.height)) {
            // The window drives the remote from now on.
            userSizedWindow = true
        }
        displayFollower.request(mode)
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
        let bar = statusBar
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
        stallOverlay.translatesAutoresizingMaskIntoConstraints = false
        stallOverlay.onAction = { [weak self] action in
            switch action {
            case .wake: self?.wakeComputer()
            case .reconnect: self?.reconnect()
            }
        }
        let container = NSView(frame: window.contentLayoutRect)
        view.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        container.addSubview(stallOverlay)
        container.addSubview(bar)
        container.addSubview(hud)
        bar.isHidden = !Self.showsStatusBar
        statusBarHeightConstraint = bar.heightAnchor.constraint(equalToConstant: barHeight)
        NSLayoutConstraint.activate([
            stallOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stallOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stallOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            stallOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            statusBarHeightConstraint,
            hud.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hud.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hud.topAnchor.constraint(equalTo: view.topAnchor),
            hud.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            viewControl.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            viewControl.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: viewControl.leadingAnchor, constant: -8),
            statusLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        window.contentView = container
        window.initialFirstResponder = view
    }

    // MARK: Roaming between addresses

    private var roamingSession: AddressRoaming.Session {
        AddressRoaming.Session(phase: snapshot.Phase, path: lastStats["Path"] as? String)
    }

    /// Every second: probes the device's addresses over HTTP when
    /// AddressRoaming says so (the session is down, or a more preferred
    /// address may answer) and follows its decision.
    private func roam() {
        let now = ProcessInfo.processInfo.systemUptime
        applyPendingMove(at: now)
        guard roamingProbe == nil, !isShutDown, roaming.probeDue(device.addresses, session: roamingSession, at: now) else { return }
        let device = device
        let order = roaming.order(device.addresses, at: now)
        roamingProbe = Task { @MainActor [weak self] in
            let result = await AddressProbe.choose(addresses: order, expectedDeviceID: device.deviceID,
                                                   fetch: AddressProbe.httpFetch(certSHA256: device.certificateSHA256))
            guard let self, !self.isShutDown else { return }
            self.roamingProbe = nil
            let now = ProcessInfo.processInfo.systemUptime
            switch self.roaming.decide(self.device.addresses, answer: try? result.get().address, session: self.roamingSession, at: now) {
            case .stay:
                break
            case .reconnect:
                AppLog.log("\(device.name) answers again at \(self.address): reconnecting now")
                self.engine.send(command: EngineCommand(cmd: "reconnect"))
            case .move(let address):
                self.pendingMove = (address, now)
                self.applyPendingMove(at: now)
            }
        }
    }

    /// Moves the session to the address roaming chose: at once while the
    /// session is down; while it is up, once nothing a reconnect would cut
    /// short is under way, within 15 s (then the next probe decides again).
    private func applyPendingMove(at now: TimeInterval) {
        guard let move = pendingMove else { return }
        let connected = snapshot.Phase == "connected"
        if connected {
            guard now - move.at < 15 else { pendingMove = nil; return }
            guard quietForMove(at: now) else { return }
        }
        pendingMove = nil
        guard move.address != address, device.addresses.contains(move.address) else { return }
        AppLog.log("\(device.name) answers at \(move.address); switching from \(address)\(connected ? "" : " (\(snapshot.Phase))")")
        roaming.moved(to: move.address, at: now)
        address = move.address
        window?.subtitle = address
        hud.show("Switching to \(address)", for: 3)
        onAddressMove?(address)
        reconnect()
    }

    /// Nothing a reconnect would cut short: no input for 2 s (nothing held
    /// down, no word half typed), and no paste, upload, setup step or
    /// remote display resize under way.
    private func quietForMove(at now: TimeInterval) -> Bool {
        let resizing = resizeRequest.map { DispatchTime.now().uptimeNanoseconds - $0.at < 15_000_000_000 } ?? false
        return now - lastInputAt >= 2 && !input.keysHeld && NSEvent.pressedMouseButtons == 0
            && pendingPasteID == nil && appPasteID == nil && snapshot.PasteInProgress != true
            && (mediaWindow == nil || mediaModel.upload == nil)
            && setupSheet == nil && setupModel?.isWorking != true && !resizing
    }

    /// What identifies the network this Mac is on: its gateways and
    /// physical interfaces. A VPN's tunnel coming or going is no new network.
    private static func networkKey(_ path: NWPath) -> String {
        let interfaces = path.availableInterfaces.filter { $0.type != .other && $0.type != .loopback }.map(\.name)
        return Set(path.gateways.map { "\($0)" } + interfaces).sorted().joined(separator: " ")
    }

    func start() throws {
        roaming = AddressRoaming(current: address, answered: addressAnswered, at: ProcessInfo.processInfo.systemUptime)
        try engine.start()
        audio.setEnabled(playsAudio)
        connectEngine()
        applyClipboardSync()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.input.ensureEventTap()
            self?.refreshStatus()
            self?.roam()
        }
        stallTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.updateStallOverlay() }
        startPathMonitor()
    }

    func reconnect() {
        if unverifiedPassword == nil, let stored = credentialProvider?(device) {
            // Pick up a password changed in the device library meanwhile.
            password = stored
        }
        pendingPasteID = nil
        fatalAlertShown = false
        decoder.reset()
        connectEngine()
    }

    /// View-only sessions change no device settings: no quality level, the
    /// device keeps refreshing still pictures itself, and its audio stays
    /// as it is (they play it where it is on: hearing is not input).
    private func connectEngine() {
        engine.connect(baseURL: address, password: password, deviceID: device.deviceID, certSHA256: device.certificateSHA256,
                       autoQuality: device.adaptiveQuality && !input.viewOnly, qualityLevel: input.viewOnly ? nil : device.qualityLevel,
                       clientRefresh: !input.viewOnly, audio: playsAudio, enableDeviceAudio: !input.viewOnly)
    }

    func showVirtualMedia() {
        if mediaWindow == nil {
            mediaWindow = VirtualMediaWindowController(model: mediaModel, deviceName: device.name)
            mediaWindow?.window?.center()
        }
        mediaWindow?.showWindow(nil)
        Task { await mediaModel.refresh() }
    }

    /// Device Settings: the device library's editor for this device, as a
    /// sheet; `save` stores what was saved (it comes back as libraryEdited).
    func showDeviceSettings(_ saved: Device, save: @escaping (Device, String?) -> Void) {
        guard let window, window.attachedSheet == nil else { return }
        let host = NSHostingController(rootView: AnyView(EmptyView()))
        let sheet = NSWindow(contentViewController: host)
        host.rootView = AnyView(DeviceEditor(device: saved, isNew: false) { [weak window, weak sheet] device, password in
            save(device, password)
            if let sheet { window?.endSheet(sheet) }
        } cancel: { [weak window, weak sheet] in
            if let sheet { window?.endSheet(sheet) }
        })
        window.beginSheet(sheet)
    }

    /// The JetKVM Setup sheet: firmware, Tailscale and password.
    func showSetup() {
        guard let window, setupSheet == nil else { return }
        let model = setupModel ?? JetKVMSetupModel(controller: self)
        setupModel = model
        let view = JetKVMSetupView(model: model, deviceName: device.name, address: address) { [weak self] in
            guard let self, let sheet = self.setupSheet else { return }
            self.window?.endSheet(sheet)
            self.setupSheet = nil
        }
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: view))
        setupSheet = sheet
        window.beginSheet(sheet)
        model.refresh()
    }

    /// Wakes the computer: a one-pixel pointer nudge there and back and a
    /// Shift tap (types nothing; some displays wake on a key but not on the
    /// pointer) wake a sleeping display, and JetKVM's wake-only USB signal a
    /// suspended computer (from firmware 0.5.9 on, ordinary input no longer does).
    func wakeComputer() {
        engine.write(EngineProtocol.relativePointer(dx: 1, dy: 0, buttons: 0))
        engine.write(EngineProtocol.relativePointer(dx: -1, dy: 0, buttons: 0))
        engine.write(EngineProtocol.key(hid: 0xE1, pressed: true))
        engine.write(EngineProtocol.key(hid: 0xE1, pressed: false))
        Task {
            do {
                try await engine.call("wakeHost")
                hud.show("Sent a wake signal to \(device.name)", for: 2.5)
            } catch {
                hud.show("This JetKVM firmware can't send a wake signal", for: 3)
            }
        }
    }

    /// Checks JetKVM Setup's three states without showing the sheet.
    private func checkSetup() {
        guard snapshot.Phase == "connected", setupSheet == nil else { return }
        let model = setupModel ?? JetKVMSetupModel(controller: self)
        setupModel = model
        model.refresh()
    }

    func recordSetup(_ summary: SetupSummary) {
        device.setup = summary.merged(over: device.setup)
        onSetupChecked?(self, summary)
    }

    /// Asks, then restarts the JetKVM (not the computer).
    func confirmRestart() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Restart the JetKVM?"
        alert.informativeText = "The JetKVM for \(device.name) restarts, which takes about a minute, and the window reconnects by itself. "
            + "The computer keeps running, but may briefly lose its display."
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            Task {
                do {
                    try await self.restartJetKVM()
                } catch {
                    self.hud.show("The JetKVM didn't restart: \((error as? EngineError)?.message ?? error.localizedDescription)", for: 4)
                }
            }
        }
    }

    /// Restarts the JetKVM; the overlay says so until the session is back
    /// (it reconnects by itself).
    func restartJetKVM() async throws {
        restartedAt = DispatchTime.now().uptimeNanoseconds
        do {
            try await engine.run(EngineCommand(cmd: "reboot"))
        } catch {
            restartedAt = nil
            throw error
        }
    }

    /// The password the session uses (typed, or from the keychain).
    var knownPassword: String? { password ?? credentialProvider?(device) }

    /// The device's password was set, changed or turned off (nil) from
    /// JetKVM Setup: the session and the Keychain follow.
    func passwordChanged(to newPassword: String?) {
        password = newPassword
        onPasswordAccepted?(self, newPassword)
    }

    /// The setup sheet's model, once it has been shown.
    var setup: JetKVMSetupModel? { setupModel }

    /// Renders the setup sheet (self-test).
    func writeSetupSnapshot(to url: URL) -> Bool {
        // The frame view, so the sheet's background is in the picture too.
        guard let view = setupSheet?.contentView?.superview ?? setupSheet?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        return (try? rep.representation(using: .png, properties: [:])?.write(to: url)) != nil
    }

    /// Adds an address the JetKVM answers at and persists it.
    func addAddress(_ address: String) {
        guard device.addAddress(address) else { return }
        AppLog.log("\(device.name): added address \(address)")
        onAddressesChanged?(self)
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
        stillRefresh.stop()
        audio.stop()
        input.setCaptured(false)
        gameModeBinding.stop()
        for observer in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        sleepObservers = []
        statusTimer?.invalidate()
        stallTimer?.invalidate()
        setupModel?.cancel()
        ClipboardBridge.shared.unregister(self)
        roamingProbe?.cancel()
        pathMonitor?.cancel()
        mediaWindow?.close()
        serialWindow?.close()
        engine.stop()
        decoder.reset()
    }

    /// When the network comes back (Wi-Fi switch, VPN up, wake from sleep),
    /// reconnect at once instead of waiting out the retry backoff. A new
    /// network has roaming probe the addresses.
    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        var lastStatus: NWPath.Status?
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                defer { lastStatus = path.status }
                let key = Self.networkKey(path)
                if let known = self.lastNetworkKey, known != key {
                    AppLog.log("\(self.device.name): network changed (\(key.isEmpty ? "none" : key))")
                    self.roaming.networkChanged(at: ProcessInfo.processInfo.systemUptime)
                }
                self.lastNetworkKey = key
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

    /// Another app pasted into the window (a dictation app's text, with ⌘V
    /// or Edit › Paste): this Mac's clipboard is pasted on the remote
    /// computer, through clipboard sync when it runs (exactly, with ⌘V
    /// there), else typed; keys pressed meanwhile follow it. The clipboard
    /// is read now: such apps put the old one back right away, and mark
    /// theirs transient. False when off or there is nothing to paste (the ⌘V
    /// then goes to the remote).
    func pasteFromApp() -> Bool {
        guard canPasteFromApp, let item = NSPasteboard.general.pasteboardItems?.first,
              let items = ClipboardPolicy.select(types: item.types.map(\.rawValue), includingPrivate: true,
                                                 data: { item.data(forType: NSPasteboard.PasteboardType($0)) }) else { return false }
        // Sync sends this clip itself; the clipboard put back meanwhile follows once it's pasted.
        ClipboardBridge.shared.hold(self, sent: items, for: 2)
        appPasteID = engine.send(command: EngineCommand(cmd: "clipboardPaste", params: ClipboardPolicy.params(items)))
        input.holdKeys()
        AppLog.log("\(device.name): pasting another app's clipboard (\(items.keys.sorted().joined(separator: ", ")))")
        return true
    }

    var canPasteFromApp: Bool { LocalShortcuts.shared.pastesFromApps && !input.viewOnly }

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
                                                 matchScale: device.matchScale,
                                                 available: (Double(available.width), Double(available.height)),
                                                 extraHeight: Double(barHeight)) else { return }
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
        let bar = barHeight
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

    /// Called on the engine's I/O queue.
    func engine(_ engine: EngineProcess, didReceiveAudio frame: Data) {
        audio.receive(frame)
    }

    func engine(_ engine: EngineProcess, didUpdate snapshot: SessionSnapshot) {
        if snapshot.Phase != self.snapshot.Phase {
            AppLog.log("\(device.name): \(snapshot.Phase) (\(snapshot.Status))")
        }
        self.snapshot = snapshot
        stillRefresh.update(snapshot)
        if snapshot.Phase == "auth_failed" && !snapshot.Status.contains("locked") {
            // Wrong, empty or changed password: always ask (the engine has
            // stopped retrying). A lockout (429) must not trigger more tries.
            unverifiedPassword = nil
            promptForPassword()
        }
        if snapshot.Phase == "connected" && !wasConnected {
            wasConnected = true
            roaming.connected()
            restartedAt = nil // back after a restart
            connectedAt = DispatchTime.now().uptimeNanoseconds
            matchRemoteToWindow()
            learnCaptureLimit()
            if let accepted = unverifiedPassword {
                unverifiedPassword = nil
                onPasswordAccepted?(self, accepted)
            }
            device.lastConnected = Date()
            onConnected?(self)
            if showsSetupOnConnect {
                showsSetupOnConnect = false
                showSetup()
            } else {
                // Keeps the Devices window's setup status current; after the
                // picture has started.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.checkSetup() }
            }
        } else if snapshot.Phase != "connected" {
            if wasConnected {
                audio.streamEnded()
                releasePointerLock()
            }
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
        stillRefresh.update(stats: stats)
        checkTailscaleRelay()
        watchVideo()
        refreshStatus()
    }

    /// Once a second: frames arrive but none decode, or none reach the
    /// screen. The decoder asks for a keyframe whenever it waits for one;
    /// this catches what it cannot see (e.g. the engine's own wait) and logs
    /// render stalls, which a keyframe does not fix.
    private func watchVideo() {
        let stats = decoder.snapshot()
        // A frame identical to the shown one counts as shown.
        let presented = videoView.presentedFrames + videoView.unchangedFrames
        defer { (watchedReceived, watchedDecoded, watchedPresented) = (stats.received, stats.decoded, presented) }
        let decoded = stats.decoded
        let arriving = stats.received > watchedReceived
        guard arriving, !decoder.paused, snapshot.Phase == "connected" else {
            (decodeStalledFor, renderStalledFor) = (0, 0)
            return
        }
        if decoded == watchedDecoded {
            // From the second tick: at the first, a unit may just be in flight.
            decodeStalledFor += 1
            if decodeStalledFor >= 2 {
                AppLog.log("video watchdog: frames arrive but none decoded for \(decodeStalledFor) s; requesting a keyframe")
                engine.requestKeyframe()
            }
        } else {
            decodeStalledFor = 0
            renderStalledFor = presented == watchedPresented ? renderStalledFor + 1 : 0
            if renderStalledFor > 0 {
                AppLog.log("video watchdog: frames decode but none reached the screen for \(renderStalledFor) s")
            }
        }
    }

    func engine(_ engine: EngineProcess, didFinishCommand id: Int64, error: String?, invalid: String?) {
        if id == appPasteID {
            appPasteID = nil
            input.releaseHeldKeys()
        }
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

    /// Records clipboard sync's new setting (nil: removed), applies and
    /// persists it (ClipboardSync.swift).
    func updateClipboardSync(_ sync: ClipboardSync?) {
        device.clipboardSync = sync
        if sync?.enabled != true { clipboardLive = ClipboardLive() }
        applyClipboardSync()
        onClipboardChanged?(self)
    }

    func engine(_ engine: EngineProcess, didReceiveClipboard items: [String: Data]) {
        guard device.clipboardSync?.enabled == true else { return }
        ClipboardBridge.shared.write(items, from: device.id)
    }

    func engine(_ engine: EngineProcess, didUpdateClipboardState state: String, message: String?) {
        let live = ClipboardLive(state: state, message: message)
        guard live != clipboardLive else { return }
        AppLog.log("\(device.name): clipboard sync \(state)\(message.map { ": \($0)" } ?? "")")
        clipboardLive = live
        followClipboard(state == "active")
        setupModel?.clipboardLiveChanged()
    }

    func engine(_ engine: EngineProcess, didReportClipboardSetup step: String) {
        setupModel?.clipboardSetupStep(step)
    }

    func engineDidRestart(_ engine: EngineProcess, reason: String) {
        pendingPasteID = nil
        appPasteID = nil
        releasePointerLock()
        input.releaseAll()
        decoder.reset()
        audio.streamEnded()
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
        if let codec = audio.playingCodec { parts.append("audio \(codec)") }
        if let level = snapshot.QualityLevel, !level.isEmpty {
            parts.append(snapshot.AutoQuality == true ? "quality \(level) (auto)" : "quality \(level)")
        }
        if let fps = lastStats["FramesPerSecond"] as? Double { parts.append(String(format: "%.0f fps", fps)) }
        if let kbps = lastStats["BitrateKbps"] as? Double { parts.append(String(format: "%.1f Mbit/s", kbps / 1000)) }
        if let rtt = lastStats["RoundTripMs"] as? Double, rtt > 0 { parts.append(String(format: "RTT %.0f ms", rtt)) }
        if let path = lastStats["Path"] as? String, let name = Self.pathNames[path] {
            parts.append(path == "tailscale" && tailscaleRelay != nil ? "via Tailscale relay \(tailscaleRelay ?? "")" : "via \(name)")
        }
        if let lost = lastStats["PacketsLost"] as? Int, lost > 0 { parts.append("lost \(lost)") }
        parts.append(String(format: "decode %.1f ms", decoded.lastDecodeMs))
        if decoded.errors > 0 { parts.append("decode errors \(decoded.errors)") }
        if decoder.paused { parts.append("paused (hidden)") }
        if snapshot.PasteInProgress == true || pendingPasteID != nil { parts.append("pasting…") }
        if isGameMode { parts.append(pointerLock.engaged ? "Game Mode (mouse locked)" : "Game Mode") }
        if input.viewOnly {
            parts.append("view only")
        } else if input.captured {
            let captured = input.eventTapActive ? "captured incl. system shortcuts" : "captured (system shortcuts stay local: allow Accessibility)"
            parts.append("input \(captured) (⌃⌘ releases)")
            if input.secureInputActive { parts.append("⚠︎ Secure Input is on: system shortcuts stay local") }
        } else {
            parts.append("input released (click or press ⌘ twice to capture)")
        }
        if let extra { parts.append(extra) }
        statusLabel.stringValue = parts.joined(separator: "  ·  ")
    }

    // MARK: NSWindowDelegate

    /// A click on the remote screen or ⌘ pressed twice captures the
    /// keyboard; focus alone doesn't, so ⌘Tab passes through. Self-tests
    /// turn this off: the operator's own input must never reach the remote.
    var capturesOnRequest = true

    func windowDidBecomeKey(_ notification: Notification) {
        window?.makeFirstResponder(videoView)
        // Back from a shortcut that keeps control (the dictation app's
        // window): the keyboard goes to the remote again, its ⌘V too.
        if capturesOnRequest && input.focusRegained() { return }
        guard !captureHintShown && capturesOnRequest && !input.viewOnly else { return }
        // A click into the window captures at once; the hint is for focus
        // without one (⌘Tab, the Devices window), so it waits for that click.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.window?.isKeyWindow == true, !self.input.captured, !self.captureHintShown else { return }
            self.captureHintShown = true
            self.showCaptureHint(typed: false)
        }
    }

    /// How to hand the keyboard to the remote; after keys typed without
    /// control (they went nowhere), the picture flashes too.
    func showCaptureHint(typed: Bool) {
        hud.show("Click the screen or press ⌘ twice to control \(device.name)", for: 3.5, prominent: true, flashes: typed)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Focus left mid-press (⌘Tab during a drag): release everything on
        // the remote so nothing stays stuck. The cursor comes back too.
        input.focusLost()
        gameModeBinding.stop()
    }

    /// Hidden windows (another tab in front, minimized, covered, another
    /// Space) stay connected but get no video: the helper stops sending it,
    /// since a hidden app may be throttled by the system and could not keep
    /// up. Shown again, video resumes at a keyframe.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        let hidden = !window.occlusionState.contains(.visible)
        decoder.paused = hidden
        engine.setVideoPaused(hidden)
        refreshStatus()
    }

    /// Shows or hides the status bar. A window keeps its video area; in full
    /// screen the video area changes, and Match Window resizes the remote
    /// display to it.
    func setStatusBarVisible(_ visible: Bool) {
        guard statusBar.isHidden == visible, let window else { return }
        let delta = visible ? Self.statusBarHeight : -Self.statusBarHeight
        statusBar.isHidden = !visible
        statusBarHeightConstraint.constant = barHeight
        if !window.styleMask.contains(.fullScreen) && !window.isZoomed {
            var frame = window.frame
            frame.size.height += delta
            frame.origin.y -= delta
            window.setFrame(frame, display: true)
        }
        window.contentView?.layoutSubtreeIfNeeded()
        matchRemoteToWindow()
    }

    // MARK: Network path

    /// The network the video takes (engine stats "Path").
    private static let pathNames = ["lan": "LAN", "tailscale": "Tailscale", "vpn": "VPN", "internet": "internet"]

    /// Over Tailscale, whether the video goes direct or through a relay
    /// (DERP, much slower), from this Mac's Tailscale; every 30 s.
    private func checkTailscaleRelay() {
        guard lastStats["Path"] as? String == "tailscale", let remote = lastStats["PathRemote"] as? String else {
            tailscaleRelay = nil
            return
        }
        if let at = relayCheckedAt, Date().timeIntervalSince(at) < 30 { return }
        relayCheckedAt = Date()
        Task { [weak self] in
            let relay = await Task.detached { TailscaleCLI.relay(to: remote) }.value
            self?.tailscaleRelay = relay
        }
    }

    // MARK: Stall overlay

    /// Every 0.1 s: what the picture is waiting for, shown over the last
    /// frame once it has lasted long enough not to flicker.
    private func updateStallOverlay() {
        let now = DispatchTime.now().uptimeNanoseconds
        let shown = stallOverlay.content
        defer { if stallOverlay.content != shown { onStallOverlay?(stallOverlay.content) } }
        guard let reason = stallReason(now: now) else {
            stallSince = nil
            stallOverlay.show(nil)
            return
        }
        let since = stallSince ?? now
        stallSince = since
        if shown != nil || now - since >= 600_000_000 {
            stallOverlay.show(reason)
        }
    }

    private func stallReason(now: UInt64) -> StallOverlay.Content? {
        guard !isShutDown, window?.occlusionState.contains(.visible) == true else { return nil }
        let name = device.name
        // After a restart the app asked for, until the session is back (or 3
        // minutes): it retries and fails while the JetKVM boots.
        let restarting = restartedAt.map { now - $0 < 180_000_000_000 } ?? false
        if snapshot.Phase == "rebooting" || (restarting && snapshot.Phase != "connected") {
            return .init(title: "The JetKVM is restarting…", detail: "\(name) comes back once it is up again.", symbol: "restart")
        }
        switch snapshot.Phase {
        case "connected":
            break
        case "idle", "connecting":
            return .init(title: "Connecting to \(name)…", detail: address, symbol: "antenna.radiowaves.left.and.right")
        case "reconnecting", "disconnected":
            return .init(title: "Reconnecting to \(name)…", detail: "The connection dropped. Retrying automatically.",
                         symbol: "arrow.triangle.2.circlepath")
        case "other_session":
            // The app steps back instead of taking the device back at once.
            return .init(title: "\(name) is in use elsewhere", detail: "The JetKVM web page or another app connected to it.",
                         symbol: "person.2.fill", busy: false, action: .reconnect)
        case "auth_failed" where snapshot.Status.contains("locked"):
            return .init(title: "Too many wrong passwords", detail: snapshot.Status.prefix(1).uppercased() + snapshot.Status.dropFirst(),
                         symbol: "lock.fill", busy: false)
        default:
            return nil // a password prompt or an alert explains
        }
        // Connected: frames keep coming even from a still screen, so a gap
        // in what reaches the view is a stall.
        let pictureAt = shownAt.withLock { $0 }
        let lastPicture = max(pictureAt, connectedAt)
        guard now > lastPicture, now - lastPicture > 250_000_000 else { return nil }
        if let request = resizeRequest, now - request.at < 15_000_000_000 {
            return .init(title: "Resizing the remote display…",
                         detail: "Switching to \(request.mode). The computer re-detects its display.",
                         symbol: "arrow.up.left.and.arrow.down.right")
        }
        if let signal = snapshot.VideoSignal, !signal.isEmpty, signal != "ready" {
            return .init(title: "No picture from the computer",
                         detail: "HDMI: \(signal.replacingOccurrences(of: "_", with: " ")). It may be asleep or switched off.",
                         symbol: "display.trianglebadge.exclamationmark", busy: false, action: input.viewOnly ? nil : .wake)
        }
        // A sleeping display can keep the HDMI signal up and send no
        // picture: after a few seconds, offer to wake it.
        let seconds = Int(Double(now - lastPicture) / 1e9)
        let wake: StallOverlay.Action? = seconds >= 5 && !input.viewOnly ? .wake : nil
        if pictureAt < connectedAt {
            return .init(title: "Starting video…",
                         detail: wake == nil ? "Connected to \(name)." : "Connected, but no picture yet. The computer may be asleep.",
                         symbol: "play.display", action: wake)
        }
        return .init(title: "Waiting for video…",
                     detail: seconds < 2 ? "Connected, but the picture has paused." : "Connected, but no new picture for \(seconds) s.",
                     symbol: "hourglass", action: wake)
    }

    /// In full screen the menu bar (and with it the window's title bar and
    /// buttons) slides in when the pointer rests at the top edge, so full
    /// screen can be left with the mouse. The Dock stays hidden: the bottom
    /// edge belongs to the remote.
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        [.fullScreen, .hideDock, .autoHideMenuBar]
    }

    /// Full screen can't be resized, but a resizable window still takes a
    /// press on its last point or two as the start of a resize, so a press
    /// at the screen's edge never reached the remote (a window's resize edge
    /// there, a hot corner). The window is resizable only outside full screen.
    func windowDidEnterFullScreen(_ notification: Notification) {
        window?.styleMask.remove(.resizable)
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        window?.styleMask.insert(.resizable)
    }

    func windowWillClose(_ notification: Notification) {
        gameModeBinding.stop()
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

    /// View › Local Pointer: the local pointer over the remote picture (AppKit
    /// restores the arrow outside it and while the window is not key).
    var localPointer = LocalPointer.hidden {
        didSet { if localPointer != oldValue { window?.invalidateCursorRects(for: self) } }
    }
    /// What the picture's cursor rect shows, as last set (self-test report).
    private(set) var cursorRectPointer: LocalPointer?
    private var pointerRest = PointerRest()
    private var restTimer: Timer?

    /// Only while pointer input goes to the remote (view-only sessions keep
    /// it hidden, as before).
    private var shownPointer: LocalPointer { controller?.input.viewOnly == false ? localPointer : .hidden }

    private static let invisibleCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in true },
                                                  hotSpot: .zero)

    /// A white ring in a dark outline, legible on any picture, with its
    /// hotspot at the center; drawn for 1× and 2× displays, so crisp on both.
    private static let dotCursor: NSCursor = {
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size)
        for scale in [1, 2] {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = size // the context draws in points
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            // 8 pt across the white ring, 9.5 pt across its outline.
            let ring = NSBezierPath(ovalIn: NSRect(origin: .zero, size: size).insetBy(dx: 1.75, dy: 1.75))
            NSColor.black.withAlphaComponent(0.75).setStroke()
            ring.lineWidth = 3
            ring.stroke()
            NSColor.white.setStroke()
            ring.lineWidth = 1.5
            ring.stroke()
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
    }()

    private static func cursor(_ pointer: LocalPointer) -> NSCursor {
        switch pointer {
        case .hidden: return invisibleCursor
        case .dot: return dotCursor
        case .arrow: return .arrow
        }
    }

    /// The remote picture in view points (empty before the first frame).
    private var pictureRect: NSRect {
        let l = currentLayout()
        let scale = pointScale
        guard l.width > 0, l.height > 0, scale > 0 else { return .zero }
        // Physical pixels, origin top-left -> view points, origin bottom-left.
        return NSRect(x: l.x / scale, y: bounds.height - (l.y + l.height) / scale,
                      width: l.width / scale, height: l.height / scale).intersection(bounds)
    }

    override func resetCursorRects() {
        let rect = pictureRect
        cursorRectPointer = rect.isEmpty ? nil : shownPointer
        if let pointer = cursorRectPointer { addCursorRect(rect, cursor: Self.cursor(pointer)) }
    }

    /// A shown local pointer hides once it rests over the picture
    /// (PointerRest), leaving the remote cursor; the next move shows it.
    private func checkRest() {
        let now = ProcessInfo.processInfo.systemUptime
        switch pointerRest.decide(at: now, buttonsHeld: NSEvent.pressedMouseButtons != 0) {
        case .wait(let until):
            restTimer = Timer.scheduledTimer(withTimeInterval: until - now, repeats: false) { [weak self] _ in
                self?.restTimer = nil
                self?.checkRest()
            }
        case .hide:
            guard shownPointer != .hidden, let window, window.isKeyWindow, NSApp.isActive,
                  pictureRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return }
            NSCursor.setHiddenUntilMouseMoves(true)
        case .idle:
            break
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    private func routeMouse(_ event: NSEvent) {
        guard let controller else { return }
        let point = convert(event.locationInWindow, from: nil)
        let physical = physicalPoint(point)
        if overflows && !controller.input.relativeActive {
            // A remote screen larger than the view pans with the pointer:
            // at the view's left edge its left edge shows, and so on. (Not
            // under Game Mode's lock: the cursor stays frozen at the center.)
            let fx = bounds.width > 0 ? Double(point.x / bounds.width) : 0.5
            let fy = bounds.height > 0 ? Double(1 - point.y / bounds.height) : 0.5
            pan = (min(max(fx, 0), 1), min(max(fy, 0), 1))
        }
        controller.input.mouse(event, at: physical, in: currentLayout())
        if shownPointer != .hidden {
            pointerRest.moved(at: event.timestamp)
            if restTimer == nil { checkRest() }
        }
    }

    /// The timestamp of the last move given to the pointer lock: AppKit
    /// delivers each move twice (tracking area and window), and a delta
    /// counted twice would double the fallback path's speed.
    private var lastLockDeltaAt: TimeInterval = -1

    /// Game Mode without a GCMouse: the dissociated cursor's event deltas.
    private func lockDelta(_ event: NSEvent) {
        guard let controller, controller.pointerLock.engaged, event.timestamp != lastLockDeltaAt else { return }
        lastLockDeltaAt = event.timestamp
        controller.pointerLock.eventDelta(event)
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller else { return }
        if !controller.input.captured && controller.capturesOnRequest {
            controller.input.setCaptured(true)
        }
        routeMouse(event)
    }

    override func mouseMoved(with event: NSEvent) { lockDelta(event); routeMouse(event) }
    override func mouseDragged(with event: NSEvent) { lockDelta(event); routeMouse(event) }
    override func mouseUp(with event: NSEvent) { routeMouse(event) }
    override func rightMouseDown(with event: NSEvent) { routeMouse(event) }
    override func rightMouseDragged(with event: NSEvent) { lockDelta(event); routeMouse(event) }
    override func rightMouseUp(with event: NSEvent) { routeMouse(event) }
    override func otherMouseDown(with event: NSEvent) { routeMouse(event) }
    override func otherMouseDragged(with event: NSEvent) { lockDelta(event); routeMouse(event) }
    override func otherMouseUp(with event: NSEvent) { routeMouse(event) }
    override func scrollWheel(with event: NSEvent) { controller?.input.scroll(event) }

    /// Edit › Paste, which dictation apps also press (through Accessibility):
    /// this Mac's clipboard is pasted on the remote computer.
    @objc func paste(_ sender: Any?) {
        _ = controller?.pasteFromApp()
    }

    override func keyDown(with event: NSEvent) {
        guard let controller else { return super.keyDown(with: event) }
        if controller.input.handle(event) { return }
        // Typing without capture: say how, instead of a beep.
        _ = controller.input.captureGesture(event)
        if controller.capturesOnRequest && !controller.input.viewOnly {
            controller.showCaptureHint(typed: true)
        } else {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if controller?.input.handle(event) != true { super.keyUp(with: event) }
    }

    override func flagsChanged(with event: NSEvent) {
        guard let controller else { return super.flagsChanged(with: event) }
        if controller.input.handle(event) { return }
        if controller.capturesOnRequest && controller.input.captureGesture(event) { return }
        super.flagsChanged(with: event)
    }

    /// ⌘-shortcuts reach this before the menu bar: while captured they go to
    /// the remote (⌘Q quits the remote app, not this one).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let controller else { return super.performKeyEquivalent(with: event) }
        if controller.input.captured { return controller.input.handle(event) }
        // A ⌘V typed before taking control says how, as other keys do (only
        // another app's goes on to Edit › Paste).
        if event.type == .keyDown, event.keyCode == UInt16(kVK_ANSI_V),
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad]) == .command,
           !(event.cgEvent.map(InputController.isFromOtherApp) ?? false), controller.capturesOnRequest {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

extension CaptureVideoView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(paste(_:)) ? controller?.canPasteFromApp == true : true
    }
}

/// A transient hint over the video (how to release capture and the like),
/// in a pill at the top. A prominent hint (how to take control) is larger,
/// with a symbol and an accent edge; one that flashes (typing went nowhere,
/// easy to miss) also briefly dims the picture inside an accent frame.
final class HintView: NSView {
    private let panel = NSVisualEffectView()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let flash = NSView()
    private var hideWork: DispatchWorkItem?
    private var flashWork: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        flash.wantsLayer = true
        flash.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        flash.layer?.borderWidth = 3
        panel.material = .hudWindow
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 10
        panel.layer?.masksToBounds = true
        // The material alone is too light over a bright picture.
        let shade = NSView()
        shade.wantsLayer = true
        shade.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        icon.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        icon.contentTintColor = .labelColor
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 16, bottom: 9, right: 16)
        panel.addSubview(shade)
        panel.addSubview(stack)
        addSubview(flash)
        addSubview(panel)
        for view in [flash, panel, shade, stack] { view.translatesAutoresizingMaskIntoConstraints = false }
        for view in [flash, panel] {
            view.alphaValue = 0
            view.isHidden = true
        }
        NSLayoutConstraint.activate([
            flash.leadingAnchor.constraint(equalTo: leadingAnchor),
            flash.trailingAnchor.constraint(equalTo: trailingAnchor),
            flash.topAnchor.constraint(equalTo: topAnchor),
            flash.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            panel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
            shade.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            shade.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            shade.topAnchor.constraint(equalTo: panel.topAnchor),
            shade.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Never takes clicks from the video.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows `text` for `seconds`. A hint that flashes, shown again while
    /// it does (each key typed without control), keeps the flash on.
    func show(_ text: String, for seconds: TimeInterval, prominent: Bool = false, flashes: Bool = false) {
        label.stringValue = text
        label.font = .systemFont(ofSize: prominent ? 14 : 13, weight: prominent ? .semibold : .medium)
        icon.isHidden = !prominent
        effectiveAppearance.performAsCurrentDrawingAppearance {
            panel.layer?.borderColor = NSColor.controlAccentColor.cgColor
            flash.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
        panel.layer?.borderWidth = prominent ? 1.5 : 0
        hideWork?.cancel()
        flashWork?.cancel()
        fade(panel, in: true, duration: 0.15)
        hideWork = after(seconds) { $0.fade($0.panel, in: false, duration: 0.4) }
        fade(flash, in: flashes, duration: flashes ? 0.12 : 0.15)
        if flashes { flashWork = after(0.5) { $0.fade($0.flash, in: false, duration: 0.6) } }
    }

    private func after(_ seconds: TimeInterval, _ body: @escaping (HintView) -> Void) -> DispatchWorkItem {
        let work = DispatchWorkItem { [weak self] in if let self { body(self) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        return work
    }

    /// Hidden once faded out, so nothing is composited over the video.
    private func fade(_ view: NSView, in shown: Bool, duration: TimeInterval) {
        if shown { view.isHidden = false }
        NSAnimationContext.runAnimationGroup({ $0.duration = duration; view.animator().alphaValue = shown ? 1 : 0 }) {
            if view.alphaValue == 0 { view.isHidden = true }
        }
    }
}
