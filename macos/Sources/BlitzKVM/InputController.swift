import AppKit
import Carbon.HIToolbox
import JetKVMCore

/// Translates local keyboard, mouse and scroll input into engine frames.
///
/// Keyboard capture (a click on the remote screen or ⌘ pressed twice turns it
/// on, ⌃⌘ or leaving the window turns it off; focus alone never captures, so
/// ⌘Tab passes through):
/// every key, including ⌘-shortcuts that would otherwise hit this app's menus,
/// goes to the remote. With Accessibility permission an event tap also takes
/// system shortcuts (⌘Tab, ⌘Space, Mission Control) and other apps' global
/// hotkeys (Raycast, Alfred). The tap sits where HID events enter the window
/// server, ahead of every hotkey and other apps' session taps. Secure Event
/// Input (password fields, some password managers) silently disables taps,
/// so it is detected and reported.
final class InputController {
    var send: (Data) -> Void = { _ in }
    var onCaptureChange: ((Bool) -> Void)?
    var modifierProfile: ModifierProfile = .mac
    var invertScroll = false
    /// When set, nothing is ever sent and capture never engages.
    var viewOnly = false
    private(set) var captured = false
    private var pressedUsages = Set<UInt8>()
    private var lastButtons: UInt8 = 0
    private var scroll = ScrollAccumulator()
    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private let isISO: Bool
    private var chordArmed = false
    private var doubleCommand = DoubleCommandPress()

    init() {
        isISO = KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO
    }

    // MARK: Capture

    func setCaptured(_ on: Bool) {
        guard on != captured, !(on && viewOnly) else { return }
        captured = on
        if !on {
            releaseAll()
            removeEventTap()
        } else {
            if !Self.accessibilityTrusted(prompt: false) && !UserDefaults.standard.bool(forKey: Self.askedForAccessibilityKey) {
                // Ask once; afterwards the hint and the Device menu say how.
                UserDefaults.standard.set(true, forKey: Self.askedForAccessibilityKey)
                _ = Self.accessibilityTrusted(prompt: true)
            }
            ensureEventTap()
        }
        onCaptureChange?(on)
    }

    /// True when another app (e.g. a focused password field) enabled Secure
    /// Event Input: the event tap receives nothing then.
    var secureInputActive: Bool { IsSecureEventInputEnabled() }

    var eventTapActive: Bool { eventTap != nil && CGEvent.tapIsEnabled(tap: eventTap!) }

    /// The system prompt for Accessibility was shown once (it shows only once).
    static let askedForAccessibilityKey = "askedForAccessibility"

    static func accessibilityTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Installs the system-shortcut tap while captured, as soon as
    /// Accessibility is granted (called again every second, so a grant takes
    /// effect without re-capturing).
    func ensureEventTap() {
        guard captured, eventTap == nil else { return }
        guard Self.accessibilityTrusted(prompt: false) else {
            logTapState("off: Accessibility not granted")
            return
        }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: inputTapCallback, userInfo: userInfo) else {
            logTapState("off: the event tap could not be created")
            return
        }
        logTapState("on")
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        tapSource = source
    }

    private var lastTapState = ""

    private func logTapState(_ state: String) {
        guard state != lastTapState else { return }
        lastTapState = state
        AppLog.log("system shortcut capture \(state)")
    }

    private func removeEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            // Without invalidation the tap stays registered with the window
            // server (holding an unretained pointer to self).
            CFMachPortInvalidate(tap)
        }
        if let source = tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        tapSource = nil
    }

    fileprivate func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Keep the callback trivial and re-enable when macOS disables it.
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        default:
            break
        }
        guard captured, NSApp.isActive else { return Unmanaged.passUnretained(event) }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
            key(keyCode: keyCode, down: true)
        case .keyUp:
            key(keyCode: keyCode, down: false)
        case .flagsChanged:
            flagsChanged(keyCode: keyCode, rawFlags: event.flags.rawValue)
        default:
            return Unmanaged.passUnretained(event)
        }
        return nil // swallowed: the Mac never sees captured keys
    }

    /// While not captured: ⌘ pressed twice quickly (nothing else between)
    /// captures. True when it did.
    func captureGesture(_ event: NSEvent) -> Bool {
        guard !captured else { return false }
        if event.type != .flagsChanged {
            doubleCommand.keyPressed()
            return false
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let commandKey = event.keyCode == UInt16(kVK_Command) || event.keyCode == UInt16(kVK_RightCommand)
        let others = flags.subtracting([.command, .capsLock, .numericPad, .function])
        guard doubleCommand.flagsChanged(commandDown: commandKey && flags.contains(.command), othersDown: !others.isEmpty,
                                         at: event.timestamp) else { return false }
        setCaptured(true)
        return captured
    }

    // MARK: Keyboard (NSEvent path, used when no event tap is active)

    /// Returns true if the event was consumed.
    func handle(_ event: NSEvent) -> Bool {
        // With the tap active, captured keys are swallowed before AppKit
        // sees them; anything that still arrives here bypassed the tap
        // (Secure Event Input, tap briefly disabled) and must be forwarded.
        guard captured else { return false }
        switch event.type {
        case .keyDown:
            if !event.isARepeat { key(keyCode: event.keyCode, down: true) }
            return true
        case .keyUp:
            key(keyCode: event.keyCode, down: false)
            return true
        case .flagsChanged:
            flagsChanged(keyCode: event.keyCode, rawFlags: UInt64(event.modifierFlags.rawValue))
            return true
        default:
            return false
        }
    }

    private func key(keyCode: UInt16, down: Bool) {
        // ⌃⌘ followed by a key is a shortcut (⌃⌘Q, ⌃⌘F), not the release chord.
        if down { chordArmed = false }
        guard let usage = KeyMap.hidUsage(keyCode: keyCode, isISO: isISO) else { return }
        sendKey(usage, down: down)
    }

    private func flagsChanged(keyCode: UInt16, rawFlags: UInt64) {
        if keyCode == KeyMap.capsLockKeyCode {
            // Caps Lock is a toggle locally; the remote needs a key press.
            sendKey(KeyMap.capsLockUsage, down: true)
            sendKey(KeyMap.capsLockUsage, down: false)
            return
        }
        guard let usage = KeyMap.modifierUsage[keyCode], let mask = KeyMap.modifierDeviceMask[keyCode] else { return }
        let down = rawFlags & mask != 0
        sendKey(modifierProfile.apply(usage), down: down)
        checkReleaseChord(rawFlags: rawFlags)
    }

    /// ⌃⌘ pressed together (nothing else) releases capture, like VMware.
    private func checkReleaseChord(rawFlags: UInt64) {
        let control: UInt64 = 0x0000_0001 | 0x0000_2000
        let command: UInt64 = 0x0000_0008 | 0x0000_0010
        let others: UInt64 = 0x0000_0002 | 0x0000_0004 | 0x0000_0020 | 0x0000_0040
        let bothDown = rawFlags & control != 0 && rawFlags & command != 0 && rawFlags & others == 0
        if bothDown {
            chordArmed = true
        } else if chordArmed && rawFlags & (control | command) == 0 {
            chordArmed = false
            DispatchQueue.main.async { self.setCaptured(false) }
        }
    }

    private func sendKey(_ usage: UInt8, down: Bool) {
        guard !viewOnly else { return }
        if down {
            pressedUsages.insert(usage)
        } else {
            pressedUsages.remove(usage)
        }
        send(EngineProtocol.key(hid: usage, pressed: down))
    }

    /// Releases every key and button we pressed on the remote (focus loss,
    /// capture release): nothing may stay stuck down there.
    func releaseAll() {
        guard !viewOnly else { return }
        for usage in pressedUsages {
            send(EngineProtocol.key(hid: usage, pressed: false))
        }
        pressedUsages.removeAll()
        lastButtons = 0
        buttonState = 0
        scroll.reset()
        chordArmed = false
        send((try? EngineProtocol.command(EngineCommand(cmd: "releaseAll"))) ?? Data())
    }

    // MARK: Mouse

    private var buttonState: UInt8 = 0

    /// Pointer report for a mouse event. Button state is tracked from the
    /// events themselves (NSEvent buttonNumber 0…4 = left, right, middle,
    /// back, forward = HID bits 1, 2, 4, 8, 16), not from global hardware
    /// state, so presses that began outside the window are not reported.
    func mouse(_ event: NSEvent, at point: (Double, Double), in layout: VideoLayout) {
        let bit: UInt8 = event.buttonNumber < 5 ? UInt8(1) << UInt8(event.buttonNumber) : 0
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            buttonState |= bit
            chordArmed = false
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: buttonState &= ~bit
        default: break
        }
        mouse(at: point, in: layout, buttons: buttonState)
    }

    func mouse(at point: (Double, Double), in layout: VideoLayout, buttons: UInt8) {
        guard !viewOnly, let (x, y) = layout.absolutePosition(px: point.0, py: point.1) else { return }
        // Moves outside the video only matter while a button is held (drags).
        if !layout.contains(px: point.0, py: point.1) && buttons == 0 && lastButtons == 0 { return }
        lastButtons = buttons
        send(EngineProtocol.absolutePointer(x: x, y: y, buttons: buttons))
    }

    func scroll(_ event: NSEvent) {
        // macOS delivers scroll events to inactive windows; only a captured
        // (focused) session may scroll the remote.
        guard !viewOnly, captured else { return }
        var dy = Double(event.scrollingDeltaY)
        var dx = Double(event.scrollingDeltaX)
        if invertScroll { dy = -dy; dx = -dx }
        let ticks = scroll.add(deltaX: -dx, deltaY: dy, precise: event.hasPreciseScrollingDeltas)
        if ticks.y != 0 || ticks.x != 0 {
            send(EngineProtocol.wheel(y: ticks.y, x: ticks.x))
        }
    }
}

private func inputTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<InputController>.fromOpaque(userInfo).takeUnretainedValue()
    return controller.handleTap(type: type, event: event)
}
