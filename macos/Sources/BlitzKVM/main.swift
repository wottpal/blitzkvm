import AppKit
import JetKVMCore

/// AppKit drops keyUp events while ⌘ is held before they reach any view, so a
/// remote key pressed with ⌘ would never be released. Forward them.
final class BlitzKVMApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyUp, event.modifierFlags.contains(.command) {
            keyWindow?.sendEvent(event)
            return
        }
        super.sendEvent(event)
    }
}

struct Options {
    var device: String?
    var password: String?
    var selfTestSeconds: Double?
    var crashEngineAfter: Double?
    var snapshotPath: String?
    /// `--latency-probe N`: measure input-to-photon latency N times (LatencyProbe).
    var latencyProbe: Int?
    var injectInput = false
    /// Self-test: also upload, mount and eject an image and use the serial
    /// console (emulator only).
    var exerciseExtras = false
    /// Never sends keyboard or mouse input (safe testing against a device
    /// whose target is this very Mac).
    var viewOnly = false
    var hideAfter: Double?
    var maxFreezeMs: Double?
    var qualityChanges: [(Double, String)] = []
    var toggleStatusBarAfter: Double?
    var windowSize: (Double, Double)?
    var fullScreen = false
    var matchScale: Double?
    /// --match-refresh: Hz, or 0 for automatic.
    var matchRefresh: Int?
    var scalingFilter: ScalingFilter?
    var localPointer: LocalPointer?
    var scaling: ScalingMode?
    var profile: ModifierProfile?
    /// Self-test: open JetKVM Setup and run `check`, `install-tailscale`,
    /// `login` (Tailscale), `restart`, `install-firmware`, `password=<new password>`
    /// or `browser-access=off`/`=on`.
    var setup: String?
    /// Self-test: render the setup sheet to this PNG at the end.
    var setupSnapshot: String?
    /// Self-test: send the wake-only signal once connected (no keystrokes).
    var wake = false
    /// Self-test: type with pauses and check the still refreshes (SelfTest.typePauses).
    var typePauses = false
    /// Self-test: play the device's audio (silently) and expect this codec
    /// ("opus", "pcmu") or none ("none"). Without it, self-tests play none.
    var expectAudio: String?
    /// `--open settings|shortcuts|permissions|licenses|devices`: opens that
    /// window (or Settings tab) at launch (and logs its window number, for
    /// `screencapture -l`).
    var openWindow: String?

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        o.password = ProcessInfo.processInfo.environment["JETKVM_PASSWORD"]
        o.device = ProcessInfo.processInfo.environment["JETKVM_DEVICE"]
        var i = 1
        func next() -> String? {
            i += 1
            return i < args.count ? args[i] : nil
        }
        while i < args.count {
            switch args[i] {
            case "--device": o.device = next()
            case "--h264": EngineProcess.offerH265 = false // self-tests against the emulator's live pattern
            case "--selftest": o.selfTestSeconds = next().flatMap(Double.init)
            case "--crash-engine-after": o.crashEngineAfter = next().flatMap(Double.init)
            case "--snapshot": o.snapshotPath = next()
            case "--latency-probe": o.latencyProbe = next().flatMap(Int.init)
            case "--inject-input": o.injectInput = true
            case "--hide-after": o.hideAfter = next().flatMap(Double.init)
            case "--max-freeze-ms": o.maxFreezeMs = next().flatMap(Double.init)
            case "--toggle-status-bar-after": o.toggleStatusBarAfter = next().flatMap(Double.init)
            case "--set-quality-after":
                // "4:balanced,9:maximum": seconds into the run, ladder level.
                o.qualityChanges = (next() ?? "").split(separator: ",").compactMap { part in
                    let p = part.split(separator: ":")
                    guard p.count == 2, let s = Double(p[0]) else { return nil }
                    return (s, String(p[1]))
                }
            case "--exercise-extras": o.exerciseExtras = true
            case "--view-only": o.viewOnly = true
            case "--scale": o.scaling = next().flatMap(ScalingMode.init(rawValue:))
            case "--match-scale": o.matchScale = next().flatMap(Double.init)
            case "--match-refresh": o.matchRefresh = next().map { Int($0) ?? 0 }
            case "--scaling-filter": o.scalingFilter = next().flatMap(ScalingFilter.init(rawValue:))
            case "--local-pointer": o.localPointer = next().flatMap(LocalPointer.init(rawValue:))
            case "--full-screen": o.fullScreen = true
            case "--profile": o.profile = next().flatMap(ModifierProfile.init(rawValue:))
            case "--setup": o.setup = next()
            case "--setup-snapshot": o.setupSnapshot = next()
            case "--wake": o.wake = true
            case "--type-pauses": o.typePauses = true
            case "--expect-audio": o.expectAudio = next()
            case "--open": o.openWindow = next()
            case "--window-size":
                let parts = (next() ?? "").split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 { o.windowSize = (parts[0], parts[1]) }
            default: break
            }
            i += 1
        }
        return o
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: Options
    private let store = DeviceStore(url: DeviceStore.defaultURL())
    private lazy var devicesModel: DevicesModel = {
        let model = DevicesModel(store: store)
        model.onConnect = { [weak self] device in self?.connect(device) }
        model.onSetUp = { [weak self] device in self?.setUp(device) }
        model.onShowSettings = { [weak self] in self?.showSettings() }
        model.onSaved = { [weak self] device in
            self?.windows.first { $0.device.id == device.id }?.libraryEdited(device)
        }
        return model
    }()
    private var devicesWindow: DevicesWindowController?
    private var licensesWindow: LicensesWindowController?
    private var settingsWindow: SettingsWindowController?
    /// Created at launch; self-tests don't check for updates (unless given a
    /// test feed).
    private var updater: Updater!
    private lazy var permissions = MainActor.assumeIsolated { PermissionsModel() }
    /// Open device windows (including minimized ones). Removed only when a
    /// window closes, which also stops its engine.
    private var windows: [DeviceWindowController] = [] {
        didSet { devicesModel.openDeviceIDs = Set(windows.map(\.device.id)) }
    }
    /// Devices whose address probe is still running (double-click guard).
    private var connecting = Set<String>() {
        didSet { devicesModel.probingDeviceIDs = connecting }
    }
    /// Devices whose setup sheet opens once they connect.
    private var pendingSetup = Set<String>()
    /// Devices typed ad hoc (--device) that are saved on first connect.
    private var adHocDeviceIDs = Set<String>()
    private var selfTest: SelfTest?
    private var latencyProbe: LatencyProbe?
    /// View › Match Window Refresh (rebuilt when opened).
    private var refreshMenu: NSMenu?

    init(options: Options) {
        self.options = options
    }

    private var isSelfTest: Bool { options.selfTestSeconds != nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        updater = MainActor.assumeIsolated { Updater(start: !isSelfTest || Updater.feedOverride != nil) }
        NSApp.mainMenu = buildMenu()
        if let address = options.device {
            connectAdHoc(address)
        } else {
            showDevices()
        }
        switch options.openWindow {
        case "settings", "shortcuts", "permissions":
            showSettings()
            settingsWindow?.select(SettingsTab(rawValue: options.openWindow?.capitalized ?? "") ?? .general)
            AppLog.log("opened settings: window number \(settingsWindow?.window?.windowNumber ?? 0)")
        case "licenses":
            showLicenses()
            AppLog.log("opened licenses: window number \(licensesWindow?.window?.windowNumber ?? 0)")
        case "devices":
            showDevices()
            AppLog.log("opened devices: window number \(devicesWindow?.window?.windowNumber ?? 0)")
        default: break
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showDevices() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        windows.forEach { $0.shutdown() }
        AppLog.flush()
    }

    /// The device window menu actions apply to: the key window, or the main
    /// window while a panel (e.g. Devices) is key. Never a background tab.
    private var current: DeviceWindowController? {
        windows.first { $0.window?.isKeyWindow == true } ?? windows.first { $0.window?.isMainWindow == true }
    }

    // MARK: Connecting

    @objc func showDevices() {
        if devicesWindow == nil {
            devicesWindow = DevicesWindowController(model: devicesModel, permissions: permissions)
            devicesWindow?.window?.center()
        }
        devicesModel.reload()
        devicesWindow?.showWindow(nil)
        devicesWindow?.window?.makeKeyAndOrderFront(nil)
    }

    /// Connects (unless a window is open) and shows the setup sheet.
    private func setUp(_ device: Device) {
        if let existing = windows.first(where: { $0.device.id == device.id }) {
            existing.window?.makeKeyAndOrderFront(nil)
            existing.showSetup()
            return
        }
        pendingSetup.insert(device.id)
        connect(device)
    }

    /// `--device address`: use the saved device with that address, or a new
    /// one that is saved after the first successful connect.
    private func connectAdHoc(_ address: String) {
        let saved = store.device(matchingAddress: address)
        var device = saved ?? Device(name: address, addresses: [address])
        if saved == nil { adHocDeviceIDs.insert(device.id) }
        if let scaling = options.scaling { device.scaling = scaling }
        if let scale = options.matchScale { device.matchScale = scale }
        if let refresh = options.matchRefresh { device.matchWindowRefresh = refresh == 0 ? nil : refresh }
        if let profile = options.profile { device.modifierProfile = profile.rawValue }
        if isSelfTest {
            // Self-tests never touch the device library or Keychain.
            open(device, address: address, password: options.password)
        } else {
            connect(device)
        }
    }

    func connect(_ device: Device) {
        if let existing = windows.first(where: { $0.device.id == device.id }) {
            // A second session would take over the first one on the device.
            if existing.window?.isMiniaturized == true { existing.window?.deminiaturize(nil) }
            existing.window?.makeKeyAndOrderFront(nil)
            if existing.snapshot.Phase == "auth_failed" || existing.snapshot.Phase == "other_session" {
                existing.reconnect() // picks up credentials edited in the library
            }
            return
        }
        guard !connecting.contains(device.id) else { return }
        connecting.insert(device.id)
        Task { @MainActor in
            defer { self.connecting.remove(device.id) }
            let result = await AddressProbe.choose(addresses: device.addresses, expectedDeviceID: device.deviceID,
                                                   fetch: AddressProbe.httpFetch(certSHA256: device.certificateSHA256, log: { AppLog.log($0) }))
            switch result {
            case .success(let (address, identity)):
                var pinned = device
                if pinned.deviceID == nil, let id = identity.deviceId {
                    pinned.deviceID = id
                    self.migrateCredential(from: device, to: pinned)
                }
                let password = self.options.password ?? Keychain.password(account: pinned.credentialAccount)
                self.open(pinned, address: address, password: password)
            case .failure(.identityMismatch(let expected, let found)):
                self.alert("Refusing to connect to \(device.name)",
                           detail: "The address answered as device \(found), but this entry belongs to \(expected). No password was sent.")
            case .failure(.unreachable):
                // No quick answer (asleep, VPN still coming up, Local Network
                // permission pending): open the window anyway; it shows the
                // progress and the engine keeps retrying. The engine still
                // verifies a pinned device ID (and certificate) before any
                // input; an unpinned device gets no stored password.
                AppLog.log("probe: no answer from \(device.addresses.joined(separator: ", ")); connecting anyway")
                guard let first = device.addresses.first else { return }
                let password = device.deviceID == nil ? self.options.password : (self.options.password ?? Keychain.password(account: device.credentialAccount))
                self.open(device, address: first, password: password, reprobe: true)
            }
        }
    }

    /// The first connect learns the device ID; a password stored under the
    /// address moves to the ID so it follows the device.
    private func migrateCredential(from old: Device, to new: Device) {
        guard old.credentialAccount != new.credentialAccount,
              let password = Keychain.password(account: old.credentialAccount) else { return }
        if Keychain.setPassword(password, account: new.credentialAccount) {
            Keychain.deletePassword(account: old.credentialAccount)
        }
    }

    private func open(_ device: Device, address: String, password: String?, reprobe: Bool = false) {
        guard let engineURL = EngineProcess.locateHelper() else {
            fail("blitzkvm-engine helper not found (set BLITZKVM_ENGINE or run `make app`)")
            return
        }
        let controller = DeviceWindowController(device: device, address: address, password: password, engineURL: engineURL)
        controller.input.viewOnly = options.viewOnly
        controller.scalingFilterOverride = options.scalingFilter
        controller.localPointerOverride = options.localPointer
        if isSelfTest { controller.playsAudioOverride = options.expectAudio != nil }
        controller.reprobeAddresses = reprobe
        controller.showsSetupOnConnect = pendingSetup.remove(device.id) != nil || options.setup != nil
        if !isSelfTest {
            controller.onConnected = { [weak self] c in self?.recordConnection(c.device) }
            controller.onCertificateChange = { [weak self] c in self?.recordCertificate(c.device) }
            controller.onIdentityLearned = { [weak self] c, before in
                // Password-protected devices reveal their ID only after login.
                self?.migrateCredential(from: before, to: c.device)
                self?.recordConnection(c.device)
            }
            controller.onPasswordAccepted = { c, password in
                if let password {
                    Keychain.setPassword(password, account: c.device.credentialAccount)
                } else {
                    Keychain.deletePassword(account: c.device.credentialAccount)
                }
            }
            controller.credentialProvider = { Keychain.password(account: $0.credentialAccount) }
        }
        controller.onClose = { [weak self] c in self?.windows.removeAll { $0 === c } }
        if !isSelfTest {
            controller.onPreferencesChanged = { [weak self] c in self?.recordPreferences(c.device) }
            controller.onAddressesChanged = { [weak self] c in self?.recordAddresses(c.device) }
            controller.onSetupChecked = { [weak self] c, summary in self?.recordSetup(summary, for: c.device) }
            controller.onClipboardChanged = { [weak self] c in self?.recordClipboard(c.device) }
        }
        let tabHost = (windows.first { $0.window?.isKeyWindow == true } ?? windows.last)?.window
        windows.append(controller)
        if let seconds = options.selfTestSeconds {
            selfTest = SelfTest(controller: controller, seconds: seconds, crashEngineAfter: options.crashEngineAfter, snapshotPath: options.snapshotPath)
            selfTest?.injectInput = options.injectInput
            selfTest?.hideAfter = options.hideAfter
            selfTest?.maxFreezeMs = options.maxFreezeMs
            selfTest?.qualityChanges = options.qualityChanges
            selfTest?.toggleStatusBarAfter = options.toggleStatusBarAfter
            selfTest?.exerciseExtras = options.exerciseExtras
            selfTest?.setupAction = options.setup
            selfTest?.setupSnapshotPath = options.setupSnapshot
            selfTest?.wake = options.wake
            selfTest?.typePauses = options.typePauses
            selfTest?.expectAudio = options.expectAudio
        }
        if let (w, h) = options.windowSize {
            controller.setContentSizeKeepingIt(NSSize(width: w, height: h))
        }
        if let tabHost, let window = controller.window {
            // Additional devices open as tabs of the current window.
            tabHost.addTabbedWindow(window, ordered: .above)
        } else {
            controller.window?.center()
        }
        controller.showWindow(nil)
        if options.fullScreen { controller.window?.toggleFullScreen(nil) }
        devicesWindow?.close()
        do {
            try controller.start()
        } catch {
            fail("could not start engine: \(error)")
        }
        selfTest?.start()
        if let samples = options.latencyProbe {
            latencyProbe = LatencyProbe(controller: controller, samples: samples)
            latencyProbe?.start()
        }
    }

    /// Persists what a connection learned (device ID, last use) without
    /// overwriting edits made in the library meanwhile; a device deleted
    /// from the library is not resurrected.
    private func recordConnection(_ device: Device) {
        if var saved = store.device(id: device.id) {
            saved.deviceID = saved.deviceID ?? device.deviceID
            saved.lastConnected = device.lastConnected
            store.upsert(saved)
        } else if adHocDeviceIDs.remove(device.id) != nil {
            store.upsert(device)
        } else {
            return
        }
        try? store.save()
        devicesModel.reload()
    }

    /// Persists preferences changed from the menus.
    private func recordPreferences(_ device: Device) {
        guard var saved = store.device(id: device.id) else { return }
        saved.modifierProfile = device.modifierProfile
        saved.viewMode = device.viewMode
        saved.exactPixelScaling = device.exactPixelScaling
        saved.invertScroll = device.invertScroll
        saved.autoQuality = device.autoQuality
        saved.qualityLevel = device.qualityLevel
        store.upsert(saved)
        try? store.save()
        devicesModel.reload()
    }

    /// Persists addresses the window added (the JetKVM's tailnet name).
    private func recordAddresses(_ device: Device) {
        guard var saved = store.device(id: device.id) else { return }
        for address in device.addresses { _ = saved.addAddress(address) }
        store.upsert(saved)
        try? store.save()
        devicesModel.reload()
    }

    /// Persists clipboard sync's setup and setting.
    private func recordClipboard(_ device: Device) {
        guard var saved = store.device(id: device.id) else { return }
        saved.clipboardSync = device.clipboardSync
        store.upsert(saved)
        try? store.save()
        devicesModel.reload()
    }

    /// Persists what JetKVM Setup found, for the Devices window.
    private func recordSetup(_ summary: SetupSummary, for device: Device) {
        guard var saved = store.device(id: device.id) else { return }
        let merged = summary.merged(over: saved.setup)
        guard merged != saved.setup else { return }
        saved.setup = merged
        store.upsert(saved)
        try? store.save()
        devicesModel.reload()
    }

    /// Persists a learned (or cleared, to trust a new one) certificate pin.
    private func recordCertificate(_ device: Device) {
        guard var saved = store.device(id: device.id) else { return }
        saved.certificateSHA256 = device.certificateSHA256
        store.upsert(saved)
        try? store.save()
    }

    private func alert(_ message: String, detail: String) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = detail
        a.runModal()
    }

    private func fail(_ message: String) {
        AppLog.log(message)
        if isSelfTest {
            AppLog.flush()
            _exit(2)
        }
        alert(message, detail: "")
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        func item(_ title: String, _ action: Selector, key: String = "", mods: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target ?? self
            return i
        }

        let appMenu = NSMenu()
        appMenu.addItem(item("About BlitzKVM", #selector(showAbout)))
        appMenu.addItem(item("Check for Updates…", #selector(Updater.checkForUpdates(_:)), target: updater))
        appMenu.addItem(item("Licenses…", #selector(showLicenses)))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(showSettings), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide BlitzKVM", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit BlitzKVM", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Standard Edit menu so text fields (password sheet, device editor)
        // support paste, copy and undo. While input is captured the video
        // view consumes key equivalents before the menu sees them.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)

        let device = NSMenu(title: "Device")
        device.addItem(item("Devices", #selector(showDevices), key: "n"))
        device.addItem(item("Reconnect", #selector(reconnect), key: "r"))
        device.addItem(item("Device Settings", #selector(showDeviceSettings)))
        device.addItem(item("Set Up JetKVM", #selector(showSetup)))
        device.addItem(item("Open JetKVM Web Interface", #selector(openWebUI)))
        device.addItem(.separator())
        device.addItem(item("Paste Clipboard as Keystrokes", #selector(pasteClipboard), key: "v", mods: [.command, .option]))
        device.addItem(item("Cancel Paste", #selector(cancelPaste)))
        device.addItem(item("Release All Keys", #selector(releaseAll)))
        device.addItem(item("Capture Keyboard", #selector(toggleCapture)))
        device.addItem(item("Enable System Shortcut Capture", #selector(requestAccessibility)))
        device.addItem(.separator())
        device.addItem(item("Wake Computer", #selector(wakeComputer)))
        device.addItem(item("Restart JetKVM", #selector(restartJetKVM)))
        let power = NSMenu(title: "Power")
        for (title, action) in [("ATX: Press Power Button", "power-short"), ("ATX: Hold Power Button (Force Off)", "power-long"), ("ATX: Press Reset", "reset")] {
            let i = item(title, #selector(atxAction(_:)))
            i.representedObject = action
            power.addItem(i)
        }
        power.addItem(.separator())
        for (title, on) in [("DC Power On", true), ("DC Power Off", false)] {
            let i = item(title, #selector(dcPower(_:)))
            i.representedObject = on
            power.addItem(i)
        }
        let powerItem = NSMenuItem(title: "Power", action: nil, keyEquivalent: "")
        powerItem.submenu = power
        device.addItem(powerItem)
        device.addItem(item("Virtual Media", #selector(showVirtualMedia), key: "m", mods: [.command, .shift]))
        device.addItem(item("Serial Console", #selector(showSerialConsole), key: "l", mods: [.command, .shift]))
        let extensions = NSMenu(title: "Extension Port")
        for (title, id) in [("None", ""), ("ATX Power Control", "atx-power"), ("DC Power Control", "dc-power"), ("Serial Console", "serial-console")] {
            let i = item(title, #selector(setExtension(_:)))
            i.representedObject = id
            extensions.addItem(i)
        }
        let extensionsItem = NSMenuItem(title: "Extension Port", action: nil, keyEquivalent: "")
        extensionsItem.submenu = extensions
        device.addItem(extensionsItem)
        device.addItem(.separator())
        for profile in ModifierProfile.allCases {
            let i = item(profile == .mac ? "Remote Is a Mac (⌘ stays ⌘)" : "Remote Is a PC (⌘ ↔ Ctrl)", #selector(setProfile(_:)))
            i.representedObject = profile.rawValue
            device.addItem(i)
        }
        device.addItem(.separator())
        device.addItem(item("Invert Scrolling", #selector(toggleInvertScroll)))
        let deviceItem = NSMenuItem()
        deviceItem.submenu = device
        main.addItem(deviceItem)

        let view = NSMenu(title: "View")
        for (index, mode) in ScalingMode.allCases.enumerated() {
            let i = item(mode.menuTitle, #selector(setScaling(_:)), key: "\(index + 1)")
            i.representedObject = mode.rawValue
            view.addItem(i)
        }
        let matchScale = NSMenu(title: "Match Window Scale")
        for scale in Device.matchScales {
            let i = item(Self.matchScaleTitle(scale), #selector(setMatchScale(_:)))
            i.representedObject = scale
            matchScale.addItem(i)
        }
        let matchScaleItem = NSMenuItem(title: "Match Window Scale", action: nil, keyEquivalent: "")
        matchScaleItem.submenu = matchScale
        view.addItem(matchScaleItem)
        // Rebuilt when opened: each rate shows the size the window gets.
        let matchRefresh = NSMenu(title: "Match Window Refresh")
        matchRefresh.delegate = self
        refreshMenu = matchRefresh
        let matchRefreshItem = NSMenuItem(title: "Match Window Refresh", action: nil, keyEquivalent: "")
        matchRefreshItem.submenu = matchRefresh
        view.addItem(matchRefreshItem)
        let filters = NSMenu(title: "Scaling Filter")
        for filter in ScalingFilter.allCases {
            let i = item(filter.menuTitle, #selector(setScalingFilter(_:)))
            i.representedObject = filter.rawValue
            filters.addItem(i)
            if filter == .automatic { filters.addItem(.separator()) }
        }
        let filtersItem = NSMenuItem(title: "Scaling Filter", action: nil, keyEquivalent: "")
        filtersItem.submenu = filters
        view.addItem(filtersItem)
        view.addItem(item("Exact Pixels at Whole-Number Scales", #selector(toggleExactPixels)))
        view.addItem(.separator())
        let quality = NSMenu(title: "Stream Quality")
        quality.addItem(item("Automatic (Adapts to the Network)", #selector(toggleAdaptiveQuality)))
        quality.addItem(.separator())
        for (title, level) in Self.qualityLevels {
            let i = item(title, #selector(setQualityLevel(_:)))
            i.representedObject = level
            quality.addItem(i)
        }
        let qualityItem = NSMenuItem(title: "Stream Quality", action: nil, keyEquivalent: "")
        qualityItem.submenu = quality
        view.addItem(qualityItem)
        view.addItem(item("Play Audio", #selector(togglePlayAudio)))
        view.addItem(.separator())
        view.addItem(item("Show Status Bar", #selector(toggleStatusBar), key: "/"))
        let pointers = NSMenu(title: "Local Pointer")
        for pointer in LocalPointer.allCases {
            let i = item(pointer.menuTitle, #selector(setLocalPointer(_:)))
            i.representedObject = pointer.rawValue
            pointers.addItem(i)
        }
        let pointersItem = NSMenuItem(title: "Local Pointer", action: nil, keyEquivalent: "")
        pointersItem.submenu = pointers
        view.addItem(pointersItem)
        view.addItem(.separator())
        view.addItem(item("Fit Window to Remote Screen", #selector(fitWindow), key: "0", mods: [.command, .option]))
        view.addItem(item("Lock Aspect Ratio", #selector(toggleAspectLock)))
        view.addItem(.separator())
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), key: "f", mods: [.command, .control], target: nil))
        let viewItem = NSMenuItem()
        viewItem.submenu = view
        main.addItem(viewItem)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Show Next Tab", action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "}")
        windowMenu.addItem(withTitle: "Show Previous Tab", action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: "{")
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        main.addItem(windowItem)
        return main
    }

    @objc private func reconnect() { current?.reconnect() }
    @objc private func showVirtualMedia() { current?.showVirtualMedia() }
    @objc private func showSerialConsole() { current?.showSerialConsole() }
    @objc private func setExtension(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { current?.setExtension(id) }
    }
    @objc private func releaseAll() { current?.input.releaseAll() }
    @objc private func cancelPaste() { current?.cancelPaste() }
    @objc private func toggleCapture() {
        guard let c = current else { return }
        c.input.setCaptured(!c.input.captured)
    }
    @objc private func requestAccessibility() { _ = InputController.accessibilityTrusted(prompt: true) }
    @objc private func setProfile(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let p = ModifierProfile(rawValue: raw) {
            current?.updatePreferences { $0.modifierProfile = p.rawValue }
        }
    }
    @objc private func setScaling(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let m = ScalingMode(rawValue: raw) { current?.pickScaling(m) }
    }
    @objc private func toggleExactPixels() { current?.updatePreferences { $0.exactPixels.toggle() } }
    @objc private func setMatchScale(_ sender: NSMenuItem) {
        if let scale = sender.representedObject as? Double { current?.setMatchScale(scale) }
    }
    @objc private func setMatchRefresh(_ sender: NSMenuItem) {
        let refresh = sender.representedObject as? Int
        current?.setMatchRefresh(refresh == 0 ? nil : refresh)
    }
    @objc private func setScalingFilter(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let filter = ScalingFilter(rawValue: raw) else { return }
        DeviceWindowController.scalingFilter = filter
        windows.forEach { $0.videoView.scalingFilter = filter }
    }
    @objc private func toggleStatusBar() {
        DeviceWindowController.showsStatusBar.toggle()
        windows.forEach { $0.setStatusBarVisible(DeviceWindowController.showsStatusBar) }
    }
    @objc private func togglePlayAudio() {
        DeviceWindowController.playsAudio.toggle()
        windows.forEach { $0.setPlaysAudio(DeviceWindowController.playsAudio) }
    }
    @objc private func setLocalPointer(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let pointer = LocalPointer(rawValue: raw) else { return }
        DeviceWindowController.localPointer = pointer
        windows.forEach { $0.videoView.localPointer = pointer }
    }

    /// "200% (Larger Text)" … "50% (More Space)": how large the remote
    /// desktop looks compared with a local window.
    static func matchScaleTitle(_ scale: Double) -> String {
        let percent = "\(Int((scale * 100).rounded()))%"
        switch scale {
        case Device.matchScales.first: return "\(percent) (Larger Text)"
        case 1: return "\(percent) (Default)"
        case Device.matchScales.last: return "\(percent) (More Space)"
        default: return percent
        }
    }

    /// The engine's quality ladder (pkg/session/autoquality.go), best first.
    static let qualityLevels: [(String, String)] = [
        ("Maximum (Fast LAN)", "maximum"), ("High", "high"), ("Balanced", "balanced"),
        ("Low", "low"), ("Minimal (Slow Links)", "minimal"),
    ]
    @objc private func toggleAdaptiveQuality() {
        guard let c = current else { return }
        c.setAdaptiveQuality(!c.device.adaptiveQuality)
    }
    @objc private func setQualityLevel(_ sender: NSMenuItem) {
        if let level = sender.representedObject as? String { current?.setQualityLevel(level) }
    }
    @objc private func fitWindow() { current?.fitWindowToRemote() }
    @objc private func toggleAspectLock() {
        guard let c = current else { return }
        c.lockAspect(!c.isAspectLocked)
    }
    @objc private func toggleInvertScroll() { current?.updatePreferences { $0.invertScroll.toggle() } }
    @objc private func pasteClipboard() {
        guard let c = current, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        c.paste(text)
    }
    @objc private func showSetup() { current?.showSetup() }

    /// The device library's editor for the current window's device, as a
    /// sheet of that window; saving updates the window at once (onSaved).
    @objc private func showDeviceSettings() {
        guard let c = current else { return }
        c.showDeviceSettings(store.device(id: c.device.id) ?? c.device) { [weak self] device, password in
            self?.devicesModel.save(device, password: password)
        }
    }

    /// The welcome screen, to check or grant the app's permissions.
    @objc private func showAbout() {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]
        let credits = NSMutableAttributedString(string: "A native macOS client for JetKVM.\nStarted from jetkvm-desktop by Lars Karlslund.\n", attributes: attributes)
        let repo = "https://github.com/wottpal/blitzkvm"
        credits.append(NSAttributedString(string: "github.com/wottpal/blitzkvm", attributes: attributes.merging([.link: URL(string: repo) as Any]) { $1 }))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showLicenses() {
        if licensesWindow == nil { licensesWindow = LicensesWindowController() }
        licensesWindow?.showWindow(nil)
        licensesWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = MainActor.assumeIsolated { SettingsWindowController(updater: updater, permissions: permissions) }
        }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openWebUI() {
        guard let c = current else { return }
        let base = c.address.contains("://") ? c.address : "http://" + c.address
        if let url = URL(string: base) { NSWorkspace.shared.open(url) }
    }

    /// Power actions act on real hardware; always confirm.
    private func confirm(_ title: String, on c: DeviceWindowController) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = "This acts on the computer attached to \(c.device.name) immediately."
        a.alertStyle = .warning
        a.addButton(withTitle: "Do It")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    @objc private func wakeComputer() { current?.wakeComputer() }

    @objc private func restartJetKVM() { current?.confirmRestart() }

    @objc private func atxAction(_ sender: NSMenuItem) {
        guard let c = current, let action = sender.representedObject as? String, confirm(sender.title, on: c) else { return }
        c.sendRPC("setATXPowerAction", params: .object(["action": .string(action)]))
    }

    @objc private func dcPower(_ sender: NSMenuItem) {
        guard let c = current, let on = sender.representedObject as? Bool, confirm(sender.title, on: c) else { return }
        c.sendRPC("setDCPowerState", params: .object(["enabled": .bool(on)]))
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Match Window Refresh: what each rate gives the current window, e.g.
    /// "60 Hz · 2432×1004" or "25 Hz · 3008×1268 (Full Size)".
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === refreshMenu else { return }
        menu.removeAllItems()
        func entry(_ title: String, _ refresh: Int) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: #selector(setMatchRefresh(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = refresh
            return i
        }
        guard let c = current else {
            menu.addItem(entry("Automatic (Largest Picture)", 0))
            return
        }
        let full = c.matchFullSize
        func label(_ mode: RemoteDisplay.Mode) -> String {
            "\(mode.size)" + (mode.size == full ? " (Full Size)" : "")
        }
        let automatic = c.matchMode(refresh: nil)
        menu.addItem(entry("Automatic (Largest Picture): \(automatic.refresh) Hz · \(label(automatic))", 0))
        menu.addItem(.separator())
        for refresh in RemoteDisplay.refreshRates {
            menu.addItem(entry("\(refresh) Hz · \(label(c.matchMode(refresh: refresh)))", refresh))
        }
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// Checks the active extension port; actions on the device need a session.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let c = current
        switch menuItem.action {
        case #selector(setScaling(_:)):
            menuItem.state = c?.device.scaling.rawValue == menuItem.representedObject as? String ? .on : .off
            return c != nil
        case #selector(showSetup), #selector(showDeviceSettings):
            return c != nil
        case #selector(openWebUI):
            // Not while JetKVM Setup found browser access off (BlitzKVM firmware D16).
            return c != nil && c?.setup?.browserAccess.value != false
        case #selector(restartJetKVM):
            return c?.snapshot.Phase == "connected"
        case #selector(wakeComputer):
            return c?.snapshot.Phase == "connected" && c?.input.viewOnly == false
        case #selector(toggleExactPixels):
            menuItem.state = c?.device.exactPixels == true ? .on : .off
            return c != nil
        case #selector(setMatchRefresh(_:)):
            let chosen = c?.device.matchWindowRefresh ?? 0
            menuItem.state = chosen == menuItem.representedObject as? Int ? .on : .off
            return c?.device.scaling == .matchWindow
        case #selector(setScalingFilter(_:)):
            menuItem.state = DeviceWindowController.scalingFilter.rawValue == menuItem.representedObject as? String ? .on : .off
            return true
        case #selector(setMatchScale(_:)):
            menuItem.state = c?.device.matchScale == menuItem.representedObject as? Double ? .on : .off
            return c?.device.scaling == .matchWindow
        case #selector(toggleStatusBar):
            menuItem.state = DeviceWindowController.showsStatusBar ? .on : .off
            return true
        case #selector(togglePlayAudio):
            menuItem.state = DeviceWindowController.playsAudio ? .on : .off
            return true
        case #selector(setLocalPointer(_:)):
            menuItem.state = DeviceWindowController.localPointer.rawValue == menuItem.representedObject as? String ? .on : .off
            return true
        case #selector(toggleInvertScroll):
            menuItem.state = c?.device.invertScroll == true ? .on : .off
            return c != nil
        case #selector(setProfile(_:)):
            menuItem.state = c?.device.modifierProfile == menuItem.representedObject as? String ? .on : .off
            return c != nil
        case #selector(toggleAspectLock):
            menuItem.state = c?.isAspectLocked == true ? .on : .off
            return c != nil
        case #selector(toggleAdaptiveQuality):
            menuItem.state = c?.device.adaptiveQuality == true ? .on : .off
            return c != nil
        case #selector(setQualityLevel(_:)):
            let manual = c?.device.adaptiveQuality == false
            menuItem.state = manual && c?.device.qualityLevel == menuItem.representedObject as? String ? .on : .off
            return c?.snapshot.Phase == "connected"
        default:
            break
        }
        if menuItem.action == #selector(setExtension(_:)) {
            let active = current?.snapshot.ActiveExtension ?? ""
            menuItem.state = active == (menuItem.representedObject as? String) ? .on : .off
            return current?.snapshot.Phase == "connected"
        }
        if menuItem.action == #selector(showVirtualMedia) {
            return current?.snapshot.Phase == "connected"
        }
        return true
    }
}

// Writing to a crashed helper's pipe must fail with EPIPE, not kill the app.
signal(SIGPIPE, SIG_IGN)

let options = Options.parse(CommandLine.arguments)
let app = BlitzKVMApplication.shared
let delegate = AppDelegate(options: options)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
