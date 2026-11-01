import ApprovalKit
import Carbon
import XCTest
@testable import RemoteCore

/// Key maps from the layouts this Mac ships, read the way the agent reads
/// the target's (UCKeyTranslate).
final class KeyLayoutTests: XCTestCase {
    let ansi = KeyLayout.keyboardType(kKeyboardANSI)!
    let iso = KeyLayout.keyboardType(kKeyboardISO)!

    func map(_ id: String, _ type: UInt32) throws -> [String: [Stroke]] {
        let data = try XCTUnwrap(KeyLayout.layoutData(id: id), "\(id) isn't installed")
        return KeyLayout.map(layout: data, keyboardType: type)
    }

    let shift = KeyLayout.shift, option = KeyLayout.option

    func testUSCoversPrintableASCII() throws {
        let m = try map("com.apple.keylayout.US", ansi)
        for v in 0x20...0x7E {
            XCTAssertNotNil(m[String(UnicodeScalar(UInt8(v)))], "U.S. lacks \(UnicodeScalar(UInt8(v)))")
        }
        XCTAssertEqual(m.count, 95)
        XCTAssertEqual(m["a"], [[0x04, 0]])
        XCTAssertEqual(m["A"], [[0x04, shift]])
        XCTAssertEqual(m["z"], [[0x1D, 0]])
        XCTAssertEqual(m["@"], [[0x1F, shift]])
        XCTAssertEqual(m[" "], [[0x2C, 0]])
        XCTAssertEqual(m["`"], [[0x35, 0]], "U.S. types ` directly (no dead key)")
        XCTAssertEqual(m["~"], [[0x35, shift]])
        XCTAssertEqual(m["\\"], [[0x31, 0]])
    }

    func testGerman() throws {
        let m = try map("com.apple.keylayout.German", ansi)
        XCTAssertEqual(m.count, 95, "German types all of printable ASCII: \(Set((0x20...0x7E).map { String(UnicodeScalar(UInt8($0))) }).subtracting(m.keys))")
        XCTAssertEqual(m["z"], [[0x1C, 0]], "where U.S. has Y")
        XCTAssertEqual(m["y"], [[0x1D, 0]])
        XCTAssertEqual(m["@"], [[0x0F, option]], "Option-L")
        XCTAssertEqual(m["{"], [[0x25, option]], "Option-8")
        XCTAssertEqual(m["\\"], [[0x24, shift | option]], "Shift-Option-7")
        // Dead keys: the accent alone is the dead key, then Space.
        XCTAssertEqual(m["^"], [[0x64, 0], KeyLayout.space], "the key left of 1 (kVK_ISO_Section) on ANSI")
        XCTAssertEqual(m["~"], [[0x11, option], KeyLayout.space], "Option-N")
        XCTAssertEqual(m["`"]?.last, KeyLayout.space)
        XCTAssertEqual(m["<"], [[0x35, 0]])
    }

    /// On a keyboard macOS takes for ISO the two keys swap: the same
    /// characters, the other usages.
    func testISOSwapsTheTwoKeys() throws {
        let a = try map("com.apple.keylayout.German", ansi), i = try map("com.apple.keylayout.German", iso)
        XCTAssertEqual(i["^"], [[0x35, 0], KeyLayout.space])
        XCTAssertEqual(i["<"], [[0x64, 0]])
        XCTAssertEqual(i[">"], [[0x64, shift]])
        for (c, strokes) in a where !strokes.contains(where: { [0x35, 0x64].contains($0[0]) }) {
            XCTAssertEqual(i[c], strokes, c)
        }
        XCTAssertEqual(KeyLayout.usage(keyCode: 0x0A, iso: false), 0x64)
        XCTAssertEqual(KeyLayout.usage(keyCode: 0x32, iso: false), 0x35)
        XCTAssertEqual(KeyLayout.usage(keyCode: 0x0A, iso: true), 0x35)
        XCTAssertEqual(KeyLayout.usage(keyCode: 0x32, iso: true), 0x64)
    }

    /// The static table: every usage once, the letters and digits where HID
    /// puts them, no keypad, Return or modifiers (only characters).
    func testTable() {
        let usages = Array(KeyLayout.usage.values)
        XCTAssertEqual(Set(usages).count, usages.count)
        XCTAssertEqual(KeyLayout.usage[0x00], 0x04) // A
        XCTAssertEqual(KeyLayout.usage[0x06], 0x1D) // Z
        XCTAssertEqual(KeyLayout.usage[0x1D], 0x27) // 0
        XCTAssertEqual(KeyLayout.usage[0x12], 0x1E) // 1
        XCTAssertNil(KeyLayout.usage[0x24]) // Return
        XCTAssertNil(KeyLayout.usage[0x52]) // keypad 0
        XCTAssertTrue(usages.allSatisfy { KeyLayout.isCharStroke([$0, 0]) })
    }

    /// The broker's rule (wire.CharStroke): character keys with Shift and
    /// Option at most, one or two strokes per character.
    func testValidation() throws {
        XCTAssertTrue(KeyLayout.isCharStroke([0x04, 0]))
        XCTAssertTrue(KeyLayout.isCharStroke([0x27, 0x02]))
        XCTAssertTrue(KeyLayout.isCharStroke([0x2C, 0x20]))
        XCTAssertTrue(KeyLayout.isCharStroke([0x38, 0x04 | 0x40 | 0x02]))
        XCTAssertTrue(KeyLayout.isCharStroke([0x64, 0]))
        for usage: UInt8 in [0x00, 0x03, 0x28, 0x29, 0x2A, 0x2B, 0x39, 0x4F, 0x65, 0xE1] {
            XCTAssertFalse(KeyLayout.isCharStroke([usage, 0]), String(usage, radix: 16))
        }
        for mods: UInt8 in [0x01, 0x08, 0x10, 0x80] { XCTAssertFalse(KeyLayout.isCharStroke([0x04, mods])) }
        XCTAssertFalse(KeyLayout.isCharStroke([0x04]))
        XCTAssertFalse(KeyLayout.isValid(["a": []]))
        XCTAssertFalse(KeyLayout.isValid(["a": [[4, 0], [4, 0], [4, 0]]]))
        XCTAssertFalse(KeyLayout.isValid(["ab": [[4, 0]]]))
        // What this Mac's layouts make passes, dead keys included.
        for id in ["com.apple.keylayout.US", "com.apple.keylayout.German"] {
            for type in [ansi, iso] { XCTAssertTrue(KeyLayout.isValid(try map(id, type)), id) }
        }
    }

    /// What the broker types with: every stroke uses Shift and Option at most.
    func testStrokesUseShiftAndOptionOnly() throws {
        for id in ["com.apple.keylayout.US", "com.apple.keylayout.German"] {
            for (_, strokes) in try map(id, ansi) {
                XCTAssertTrue(strokes.allSatisfy { $0.count == 2 && $0[1] & ~(shift | option) == 0 })
                XCTAssertLessThanOrEqual(strokes.count, 2)
            }
        }
    }

    func testCurrentInputSource() {
        // Whatever this Mac uses: it reads, and maps something.
        if let current = KeyLayout.current() {
            XCTAssertFalse(KeyLayout.map(layout: current.layout, keyboardType: current.keyboardType).isEmpty)
        }
    }
}
