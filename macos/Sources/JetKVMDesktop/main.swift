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
    var offerH265 = false
    var selfTestSeconds: Double?
    var crashEngineAfter: Double?
    var snapshotPath: String?
    var injectInput = false
    /// Never sends keyboard or mouse input (safe testing against a device
    /// whose target is this very Mac).
    var viewOnly = false
    var windowSize: (Double, Double)?
    var scaling: ScalingMode = .fit
    var profile: ModifierProfile = .mac

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
            case "--selftest": o.selfTestSeconds = next().flatMap(Double.init)
            case "--crash-engine-after": o.crashEngineAfter = next().flatMap(Double.init)
            case "--snapshot": o.snapshotPath = next()
            case "--inject-input": o.injectInput = true
            case "--view-only": o.viewOnly = true
            case "--window-size":
                let parts = (next() ?? "").split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 { o.windowSize = (parts[0], parts[1]) }
            case "--scale": o.scaling = next().flatMap(ScalingMode.init(rawValue:)) ?? .fit
            case "--profile": o.profile = next().flatMap(ModifierProfile.init(rawValue:)) ?? .mac
            default: break
            }
            i += 1
        }
        return o
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: Options
    private var windows: [DeviceWindowController] = []
    private var selfTest: SelfTest?

    init(options: Options) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        if let device = options.device {
            open(device: device)
        } else {
            promptForDevice()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        windows.forEach { $0.shutdown() }
    }

    private var current: DeviceWindowController? {
        windows.first { $0.window?.isKeyWindow == true } ?? windows.last
    }

    func open(device: String) {
        guard let engineURL = EngineProcess.locateHelper() else {
            fail("jetkvm-engine helper not found (set JETKVM_ENGINE or run `make app`)")
            return
        }
        let controller = DeviceWindowController(address: device, password: options.password, offerH265: options.offerH265, engineURL: engineURL)
        controller.videoView.scalingMode = options.scaling
        controller.input.modifierProfile = options.profile
        controller.input.viewOnly = options.viewOnly
        windows.append(controller)
        if let seconds = options.selfTestSeconds {
            selfTest = SelfTest(controller: controller, seconds: seconds, crashEngineAfter: options.crashEngineAfter, snapshotPath: options.snapshotPath)
            selfTest?.injectInput = options.injectInput
        }
        if let (w, h) = options.windowSize {
            controller.window?.setContentSize(NSSize(width: w, height: h))
        }
        controller.window?.center()
        controller.showWindow(nil)
        do {
            try controller.start()
        } catch {
            fail("could not start engine: \(error)")
        }
        selfTest?.start()
    }

    private func promptForDevice() {
        let alert = NSAlert()
        alert.messageText = "Connect to JetKVM"
        alert.informativeText = "Hostname or IP address (LAN, Tailscale or any VPN):"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "jetkvm.local"
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Quit")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
            open(device: field.stringValue)
        } else {
            NSApp.terminate(nil)
        }
    }

    private func fail(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        if options.selfTestSeconds != nil { exit(2) }
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide JetKVM Desktop", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit JetKVM Desktop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let deviceItem = NSMenuItem()
        let device = NSMenu(title: "Device")
        device.addItem(withTitle: "Connect…", action: #selector(connectAnother), keyEquivalent: "n").target = self
        device.addItem(withTitle: "Reconnect", action: #selector(reconnect), keyEquivalent: "r").target = self
        device.addItem(.separator())
        device.addItem(withTitle: "Paste Clipboard as Keystrokes", action: #selector(pasteClipboard), keyEquivalent: "v").keyEquivalentModifierMask = [.command, .option]
        device.items.last?.target = self
        device.addItem(withTitle: "Release All Keys", action: #selector(releaseAll), keyEquivalent: "").target = self
        device.addItem(withTitle: "Capture Keyboard", action: #selector(toggleCapture), keyEquivalent: "").target = self
        device.addItem(withTitle: "Enable System Shortcut Capture…", action: #selector(requestAccessibility), keyEquivalent: "").target = self
        device.addItem(.separator())
        for profile in ModifierProfile.allCases {
            let item = device.addItem(withTitle: profile == .mac ? "Remote Is a Mac (⌘ stays ⌘)" : "Remote Is a PC (⌘ ↔ Ctrl)", action: #selector(setProfile(_:)), keyEquivalent: "")
            item.representedObject = profile.rawValue
            item.target = self
        }
        device.addItem(withTitle: "Offer H.265 (reconnects)", action: #selector(toggleH265), keyEquivalent: "").target = self
        deviceItem.submenu = device
        main.addItem(deviceItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        for (title, mode, key) in [("Fit to Window", ScalingMode.fit, "0"), ("Actual Size (1:1)", ScalingMode.actualSize, "1"), ("Integer Scale", ScalingMode.integer, "2")] {
            let item = view.addItem(withTitle: title, action: #selector(setScaling(_:)), keyEquivalent: key)
            item.representedObject = mode.rawValue
            item.target = self
        }
        view.addItem(withTitle: "Invert Scrolling", action: #selector(toggleInvertScroll), keyEquivalent: "").target = self
        view.addItem(.separator())
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f").keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = view
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        main.addItem(windowItem)
        return main
    }

    @objc private func connectAnother() { promptForDevice() }
    @objc private func reconnect() { current?.reconnect() }
    @objc private func releaseAll() { current?.input.releaseAll() }
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
    @objc private func toggleInvertScroll() {
        guard let c = current else { return }
        c.input.invertScroll.toggle()
    }
    @objc private func pasteClipboard() {
        guard let c = current, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        c.engine.send(command: EngineCommand(cmd: "paste", text: text))
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
