import JetKVMCore
import XCTest
@testable import BlitzKVM

final class InputControllerTests: XCTestCase {
    /// A matched 1504-wide remote on a 1512 pt Retina screen in full screen:
    /// 8 px of margin left and right of the video.
    private let layout = VideoLayout(x: 8, y: 0, width: 3008, height: 1896, nearest: true)

    private func pointerReports(_ moves: [(Double, Double, UInt8)]) -> [Data] {
        let input = InputController()
        var sent: [Data] = []
        input.send = { sent.append($0) }
        for (px, py, buttons) in moves { input.mouse(at: (px, py), in: layout, buttons: buttons) }
        return sent
    }

    func testTheMarginKeepsThePointerOnTheVideoEdge() {
        // A fast move: the last event inside the video is 8 px short of its
        // edge, the next one is in the margin.
        let sent = pointerReports([(3008, 948, 0), (3022, 948, 0)])
        XCTAssertEqual(sent.last, EngineProtocol.absolutePointer(x: 32767, y: 16384, buttons: 0))
    }

    // MARK: Shortcuts for This Mac

    private let option = LocalShortcut.option
    private let fn = LocalShortcut.function

    /// A captured controller (no Accessibility prompt, no tap in tests).
    private func captured(_ shortcuts: [LocalShortcut]) -> (InputController, () -> [Data]) {
        UserDefaults.standard.set(true, forKey: InputController.askedForAccessibilityKey)
        let input = InputController()
        var sent: [Data] = []
        input.send = { sent.append($0) }
        input.localShortcuts = { shortcuts }
        input.setCaptured(true)
        sent.removeAll()
        return (input, { sent })
    }

    func testAKeyShortcutStaysHere() {
        let (input, _) = captured([LocalShortcut(keyCode: 2, modifiers: LocalShortcut.control | option, keyLabel: "D")])
        XCTAssertEqual(input.route(.keyDown, keyCode: 2, flags: LocalShortcut.control | option, fromApp: false), .local)
        XCTAssertEqual(input.route(.keyUp, keyCode: 2, flags: LocalShortcut.control | option, fromApp: false), .local)
        XCTAssertEqual(input.route(.keyDown, keyCode: 2, flags: LocalShortcut.control, fromApp: false), .remote)
        XCTAssertEqual(input.route(.keyUp, keyCode: 2, flags: 0, fromApp: false), .remote)
    }

    func testModifiersAloneStayHereUntilAllAreUp() {
        let (input, sent) = captured([LocalShortcut(keyCode: nil, modifiers: option | fn)])
        // ⌥ goes down on the remote first: nothing says yet it's the shortcut.
        let optionDown = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(option | 0x20)),
                                          timestamp: 1, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                          isARepeat: false, keyCode: 0x3A)!
        XCTAssertTrue(input.handle(optionDown))
        XCTAssertEqual(sent().last, EngineProtocol.key(hid: 0xE2, pressed: true))
        // fn completes it: ⌥ is lifted on the remote, and from now on
        // everything stays here.
        XCTAssertEqual(input.route(.flagsChanged, keyCode: 63, flags: option | fn, fromApp: false), .local)
        XCTAssertEqual(sent().last, EngineProtocol.key(hid: 0xE2, pressed: false))
        XCTAssertEqual(input.route(.keyDown, keyCode: 0, flags: option | fn, fromApp: false), .local)
        XCTAssertEqual(input.route(.flagsChanged, keyCode: 63, flags: option, fromApp: false), .local)
        XCTAssertEqual(input.route(.flagsChanged, keyCode: 0x3A, flags: 0, fromApp: false), .local)
        // All up: the next ⌥ goes to the remote again.
        XCTAssertEqual(input.route(.flagsChanged, keyCode: 0x3A, flags: option, fromApp: false), .remote)
    }

    func testAShortcutThatKeepsControlCapturesAgainWhenFocusReturns() {
        let dictation = LocalShortcut(keyCode: nil, modifiers: option | fn, keepsControl: true)
        let (input, _) = captured([dictation])
        XCTAssertEqual(input.route(.flagsChanged, keyCode: 63, flags: option | fn, fromApp: false), .local)
        // The dictation app's window takes focus, then hands it back.
        input.focusLost()
        XCTAssertFalse(input.captured)
        XCTAssertTrue(input.focusRegained())
        XCTAssertTrue(input.captured)
        // Again within the time (its window comes back to say it's done).
        input.focusLost()
        XCTAssertTrue(input.focusRegained())
        // Not after it, nor once released on purpose (⌃⌘).
        input.focusLost()
        XCTAssertFalse(input.focusRegained(now: ProcessInfo.processInfo.systemUptime + InputController.keepsControlFor))
        input.setCaptured(true)
        _ = input.route(.flagsChanged, keyCode: 63, flags: option | fn, fromApp: false)
        input.setCaptured(false)
        XCTAssertFalse(input.focusRegained())
    }

    func testAShortcutThatDoesntKeepControlLeavesFocusAlone() {
        let (input, _) = captured([LocalShortcut(keyCode: nil, modifiers: option | fn)])
        _ = input.route(.flagsChanged, keyCode: 63, flags: option | fn, fromApp: false)
        input.focusLost()
        XCTAssertFalse(input.focusRegained())
        XCTAssertFalse(input.captured)
    }

    func testAnotherAppsPasteIsHandledHere() {
        let (input, _) = captured([])
        var pastes = 0
        input.onPasteFromApp = { pastes += 1; return true }
        XCTAssertEqual(input.route(.keyDown, keyCode: 9, flags: LocalShortcut.command, fromApp: true), .drop)
        XCTAssertEqual(input.route(.keyUp, keyCode: 9, flags: LocalShortcut.command, fromApp: true), .drop)
        XCTAssertEqual(pastes, 1)
        // Typed ⌘V pastes the remote's clipboard, as always.
        XCTAssertEqual(input.route(.keyDown, keyCode: 9, flags: LocalShortcut.command, fromApp: false), .remote)
        // Nothing to paste: the app's ⌘V goes on to the remote.
        input.onPasteFromApp = { false }
        XCTAssertEqual(input.route(.keyDown, keyCode: 9, flags: LocalShortcut.command, fromApp: true), .remote)
    }

    func testKeysAfterAnAppsPasteWaitForIt() {
        let (input, sent) = captured([])
        input.onPasteFromApp = { input.holdKeys(); return true }
        // The dictation app holds ⌘ (sent), pastes, then presses Return.
        let commandDown = EngineProtocol.key(hid: 0xE3, pressed: true)
        let commandDownEvent = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(LocalShortcut.command | 0x08)), timestamp: 1, windowNumber: 0,
                                                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0x37)!
        XCTAssertTrue(input.handle(commandDownEvent))
        XCTAssertEqual(sent().last, commandDown)
        XCTAssertEqual(input.route(.keyDown, keyCode: 9, flags: LocalShortcut.command, fromApp: true), .drop)
        // ⌘ is lifted at once; Return waits for the paste.
        XCTAssertEqual(sent().last, EngineProtocol.key(hid: 0xE3, pressed: false))
        let returnKey = { (down: Bool) in
            NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: [], timestamp: 2, windowNumber: 0,
                             context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 0x24)!
        }
        XCTAssertTrue(input.handle(returnKey(true)))
        XCTAssertTrue(input.handle(returnKey(false)))
        let before = sent().count
        input.releaseHeldKeys()
        XCTAssertEqual(Array(sent().suffix(from: before)), [EngineProtocol.key(hid: 0x28, pressed: true), EngineProtocol.key(hid: 0x28, pressed: false)])
        // Not held any more.
        XCTAssertTrue(input.handle(returnKey(true)))
        XCTAssertEqual(sent().last, EngineProtocol.key(hid: 0x28, pressed: true))
    }

    func testRepeatedReportsAreSentOnce() {
        let sent = pointerReports([(1000, 500, 0), (1000, 500, 0), (1000, 500, 1), (1000, 500, 1), (1000, 500, 0)])
        XCTAssertEqual(sent.count, 3)
    }
}
