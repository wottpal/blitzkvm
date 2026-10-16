import XCTest
@testable import JetKVMCore

final class LocalShortcutTests: XCTestCase {
    func testTitlesFollowMacOSOrder() {
        XCTAssertEqual(LocalShortcut(keyCode: nil, modifiers: LocalShortcut.option | LocalShortcut.function).title, "⌥ fn")
        let all = LocalShortcut.control | LocalShortcut.option | LocalShortcut.shift | LocalShortcut.command
        XCTAssertEqual(LocalShortcut(keyCode: 2, modifiers: all, keyLabel: "D").title, "⌃⌥⇧⌘ D")
        XCTAssertEqual(LocalShortcut(keyCode: 0x60, modifiers: LocalShortcut.function, keyLabel: "F5").title, "fn F5")
        XCTAssertEqual(LocalShortcut(keyCode: 2, modifiers: all | LocalShortcut.function, keyLabel: "D").keys, ["⌃", "⌥", "⇧", "⌘", "fn", "D"])
        XCTAssertEqual(LocalShortcut(keyCode: 2, modifiers: all | LocalShortcut.function, keyLabel: "D").title, "⌃⌥⇧⌘ fn D")
    }

    func testShortcutsSavedBeforeKeepControlStillDecode() throws {
        let saved = Data(#"[{"modifiers":8912896},{"keyCode":2,"modifiers":786432,"keyLabel":"D"}]"#.utf8)
        let shortcuts = try JSONDecoder().decode([LocalShortcut].self, from: saved)
        XCTAssertEqual(shortcuts.map(\.title), ["⌥ fn", "⌃⌥ D"])
        XCTAssertEqual(shortcuts.map(\.keepsControl), [false, false])
        var kept = shortcuts[0]
        kept.keepsControl = true
        XCTAssertEqual(try JSONDecoder().decode(LocalShortcut.self, from: JSONEncoder().encode(kept)), kept)
    }

    func testMatchingIgnoresDeviceBitsAndCapsLock() {
        let shortcut = LocalShortcut(keyCode: 49, modifiers: LocalShortcut.option, keyLabel: "Space")
        let leftOptionDeviceBit: UInt64 = 0x20
        let capsLock: UInt64 = 0x1_0000
        XCTAssertTrue(shortcut.matches(keyCode: 49, flags: LocalShortcut.option | leftOptionDeviceBit | capsLock))
        XCTAssertFalse(shortcut.matches(keyCode: 49, flags: LocalShortcut.option | LocalShortcut.shift))
        XCTAssertFalse(shortcut.matches(keyCode: 48, flags: LocalShortcut.option))
        XCTAssertFalse(shortcut.matches(flags: LocalShortcut.option), "a key shortcut never matches modifiers alone")

        let dictation = LocalShortcut(keyCode: nil, modifiers: LocalShortcut.option | LocalShortcut.function)
        XCTAssertTrue(dictation.matches(flags: LocalShortcut.option | LocalShortcut.function | leftOptionDeviceBit))
        XCTAssertFalse(dictation.matches(flags: LocalShortcut.option))
        XCTAssertFalse(dictation.matches(keyCode: 49, flags: LocalShortcut.option | LocalShortcut.function))
    }

    func testRoundTripsThroughJSON() throws {
        let shortcuts = [LocalShortcut(keyCode: 2, modifiers: LocalShortcut.control, keyLabel: "D"),
                         LocalShortcut(keyCode: nil, modifiers: LocalShortcut.option | LocalShortcut.function)]
        XCTAssertEqual(try JSONDecoder().decode([LocalShortcut].self, from: JSONEncoder().encode(shortcuts)), shortcuts)
    }
}
