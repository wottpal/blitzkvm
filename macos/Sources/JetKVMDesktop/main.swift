import AppKit
import JetKVMCore

/// AppKit drops keyUp events while ⌘ is held before they reach any view, so a
/// remote key pressed with ⌘ would never be released. Forward them.
final class JetKVMApplication: NSApplication {
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
    var offerH265: Bool?
    var selfTestSeconds: Double?
    var crashEngineAfter: Double?
    var snapshotPath: String?
    var injectInput = false
    /// Never sends keyboard or mouse input (safe testing against a device
    /// whose target is this very Mac).
    var viewOnly = false
    var windowSize: (Double, Double)?
    var scaling: ScalingMode?
    var profile: ModifierProfile?

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
            case "--h265": o.offerH265 = true
            case "--h264": o.offerH265 = false
            case "--selftest": o.selfTestSeconds = next().flatMap(Double.init)
            case "--crash-engine-after": o.crashEngineAfter = next().flatMap(Double.init)
            case "--snapshot": o.snapshotPath = next()
            case "--inject-input": o.injectInput = true
            case "--view-only": o.viewOnly = true
            case "--scale": o.scaling = next().flatMap(ScalingMode.init(rawValue:))
            case "--profile": o.profile = next().flatMap(ModifierProfile.init(rawValue:))
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
        return model
    }()
    private var devicesWindow: DevicesWindowController?
    private var windows: [DeviceWindowController] = []
    private var selfTest: SelfTest?

    init(options: Options) {
        self.options = options
    }

    private var isSelfTest: Bool { options.selfTestSeconds != nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        if let address = options.device {
            connectAdHoc(address)
        } else {
            showDevices()
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
    }

    private var current: DeviceWindowController? {
        windows.first { $0.window?.isKeyWindow == true } ?? windows.last { $0.window?.isVisible == true }
    }

    // MARK: Connecting

    @objc func showDevices() {
        if devicesWindow == nil {
            devicesWindow = DevicesWindowController(model: devicesModel)
            devicesWindow?.window?.center()
        }
        devicesModel.reload()
        devicesWindow?.showWindow(nil)
        devicesWindow?.window?.makeKeyAndOrderFront(nil)
    }

    /// `--device address`: use the saved device with that address, or a new
    /// one that is saved after the first successful connect.
    private func connectAdHoc(_ address: String) {
        var device = store.device(matchingAddress: address) ?? Device(name: address, addresses: [address])
        if let h265 = options.offerH265 { device.offerH265 = h265 }
        if let scaling = options.scaling { device.scalingMode = scaling.rawValue }
        if let profile = options.profile { device.modifierProfile = profile.rawValue }
        if isSelfTest {
            // Self-tests never touch the device library or Keychain.
            open(device, address: address, password: options.password)
        } else {
            connect(device)
        }
    }

    func connect(_ device: Device) {
        if let existing = windows.first(where: { $0.device.id == device.id && $0.window?.isVisible == true }) {
            // A second session would take over the first one on the device.
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        Task { @MainActor in
            let result = await AddressProbe.choose(addresses: device.addresses, expectedDeviceID: device.deviceID,
                                                   fetch: AddressProbe.httpFetch())
            switch result {
            case .success(let (address, identity)):
                var pinned = device
                if pinned.deviceID == nil {
                    pinned.deviceID = identity.deviceId
                    self.migrateCredential(from: device, to: pinned)
                }
                let password = self.options.password ?? Keychain.password(account: pinned.credentialAccount)
                self.open(pinned, address: address, password: password)
            case .failure(.identityMismatch(let expected, let found)):
                self.alert("Refusing to connect to \(device.name)",
                           detail: "The address answered as device \(found), but this entry belongs to \(expected). No password was sent.")
            case .failure(.unreachable):
                let a = NSAlert()
                a.messageText = "\(device.name) is not reachable"
                a.informativeText = "Tried: \(device.addresses.joined(separator: ", ")). Check the network or VPN."
                a.addButton(withTitle: "Try Anyway")
                a.addButton(withTitle: "Cancel")
                if a.runModal() == .alertFirstButtonReturn, let first = device.addresses.first {
                    self.open(device, address: first, password: self.options.password ?? Keychain.password(account: device.credentialAccount))
                }
            }
        }
    }

    /// The first connect learns the device ID; a password stored under the
    /// address moves to the ID so it follows the device.
    private func migrateCredential(from old: Device, to new: Device) {
        guard old.credentialAccount != new.credentialAccount,
              let password = Keychain.password(account: old.credentialAccount) else { return }
        Keychain.setPassword(password, account: new.credentialAccount)
        Keychain.deletePassword(account: old.credentialAccount)
    }

    private func open(_ device: Device, address: String, password: String?) {
        guard let engineURL = EngineProcess.locateHelper() else {
            fail("jetkvm-engine helper not found (set JETKVM_ENGINE or run `make app`)")
            return
        }
        let controller = DeviceWindowController(device: device, address: address, password: password, engineURL: engineURL)
        controller.input.viewOnly = options.viewOnly
        if !isSelfTest {
            controller.onConnected = { [weak self] c in
                self?.store.upsert(c.device)
                try? self?.store.save()
                self?.devicesModel.reload()
            }
            controller.onPasswordEntered = { c, password in
                Keychain.setPassword(password, account: c.device.credentialAccount)
            }
        }
        windows.removeAll { $0.window?.isVisible != true }
        let tabHost = windows.last?.window
        windows.append(controller)
        if let seconds = options.selfTestSeconds {
            selfTest = SelfTest(controller: controller, seconds: seconds, crashEngineAfter: options.crashEngineAfter, snapshotPath: options.snapshotPath)
            selfTest?.injectInput = options.injectInput
        }
        if let (w, h) = options.windowSize {
            controller.window?.setContentSize(NSSize(width: w, height: h))
        }
        if let tabHost, let window = controller.window {
            // Additional devices open as tabs of the current window.
            tabHost.addTabbedWindow(window, ordered: .above)
        } else {
            controller.window?.center()
        }
        controller.showWindow(nil)
        devicesWindow?.close()
        do {
            try controller.start()
        } catch {
            fail("could not start engine: \(error)")
        }
        selfTest?.start()
    }

    private func alert(_ message: String, detail: String) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = detail
        a.runModal()
    }

    private func fail(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        if isSelfTest { _exit(2) }
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
        appMenu.addItem(withTitle: "Hide JetKVM Desktop", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit JetKVM Desktop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        let device = NSMenu(title: "Device")
        device.addItem(item("Devices…", #selector(showDevices), key: "n"))
        device.addItem(item("Reconnect", #selector(reconnect), key: "r"))
        device.addItem(item("Open Device Web Settings…", #selector(openWebUI)))
        device.addItem(.separator())
        device.addItem(item("Paste Clipboard as Keystrokes", #selector(pasteClipboard), key: "v", mods: [.command, .option]))
        device.addItem(item("Cancel Paste", #selector(cancelPaste)))
        device.addItem(item("Release All Keys", #selector(releaseAll)))
        device.addItem(item("Capture Keyboard", #selector(toggleCapture)))
        device.addItem(item("Enable System Shortcut Capture…", #selector(requestAccessibility)))
        device.addItem(.separator())
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
        device.addItem(.separator())
        for profile in ModifierProfile.allCases {
            let i = item(profile == .mac ? "Remote Is a Mac (⌘ stays ⌘)" : "Remote Is a PC (⌘ ↔ Ctrl)", #selector(setProfile(_:)))
            i.representedObject = profile.rawValue
            device.addItem(i)
        }
        device.addItem(item("Use H.265 (reconnects)", #selector(toggleH265)))
        let deviceItem = NSMenuItem()
        deviceItem.submenu = device
        main.addItem(deviceItem)

        let view = NSMenu(title: "View")
        for (title, mode, key) in [("Fit to Window", ScalingMode.fit, "0"), ("Actual Size (1:1)", ScalingMode.actualSize, "1"), ("Integer Scale", ScalingMode.integer, "2")] {
            let i = item(title, #selector(setScaling(_:)), key: key)
            i.representedObject = mode.rawValue
            view.addItem(i)
        }
        view.addItem(item("Fit Window to Remote Screen", #selector(fitWindow), key: "0", mods: [.command, .option]))
        view.addItem(item("Lock Aspect Ratio", #selector(toggleAspectLock)))
        view.addItem(item("Invert Scrolling", #selector(toggleInvertScroll)))
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
    @objc private func releaseAll() { current?.input.releaseAll() }
    @objc private func cancelPaste() { current?.cancelPaste() }
    @objc private func toggleCapture() {
        guard let c = current else { return }
        c.input.setCaptured(!c.input.captured)
    }
    @objc private func requestAccessibility() { _ = InputController.accessibilityTrusted(prompt: true) }
    @objc private func setProfile(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let p = ModifierProfile(rawValue: raw) { current?.input.modifierProfile = p }
    }
    @objc private func toggleH265() {
        guard let c = current else { return }
        c.reconnect(offerH265: !c.offerH265)
    }
    @objc private func setScaling(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let m = ScalingMode(rawValue: raw) { current?.videoView.scalingMode = m }
    }
    @objc private func fitWindow() { current?.fitWindowToRemote() }
    @objc private func toggleAspectLock() {
        guard let c = current else { return }
        c.lockAspect(!c.isAspectLocked)
    }
    @objc private func toggleInvertScroll() {
        guard let c = current else { return }
        c.input.invertScroll.toggle()
    }
    @objc private func pasteClipboard() {
        guard let c = current, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        c.paste(text)
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

    @objc private func atxAction(_ sender: NSMenuItem) {
        guard let c = current, let action = sender.representedObject as? String, confirm(sender.title, on: c) else { return }
        c.sendRPC("setATXPowerAction", params: .object(["action": .string(action)]))
    }

    @objc private func dcPower(_ sender: NSMenuItem) {
        guard let c = current, let on = sender.representedObject as? Bool, confirm(sender.title, on: c) else { return }
        c.sendRPC("setDCPowerState", params: .object(["enabled": .bool(on)]))
    }
}

// Writing to a crashed helper's pipe must fail with EPIPE, not kill the app.
signal(SIGPIPE, SIG_IGN)

let options = Options.parse(CommandLine.arguments)
let app = JetKVMApplication.shared
let delegate = AppDelegate(options: options)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
