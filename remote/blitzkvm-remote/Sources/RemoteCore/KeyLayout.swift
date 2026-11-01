import ApprovalKit
import Carbon
import Foundation

/// The key map a secret is typed with: for every printable ASCII character,
/// the strokes the JetKVM's keyboard needs on this Mac's active input
/// source. Computed in the user's session (the agent), where the input
/// source lives, from the layout's own data (UCKeyTranslate): no
/// permission, no prompt.
public enum KeyLayout {
    /// Modifier bits of a stroke (HID boot report).
    public static let shift: UInt8 = 0x02, option: UInt8 = 0x04 // Left Shift, Left Alt

    /// macOS virtual key code → HID usage for the keys a secret may use,
    /// for a keyboard macOS treats as ANSI (the JetKVM's, unless Keyboard
    /// Setup Assistant was told otherwise). The keypad is left out: its
    /// keys depend on Num Lock.
    public static let usage: [UInt16: UInt8] = [
        0x00: 0x04, 0x0B: 0x05, 0x08: 0x06, 0x02: 0x07, 0x0E: 0x08, 0x03: 0x09, 0x05: 0x0A, 0x04: 0x0B,
        0x22: 0x0C, 0x26: 0x0D, 0x28: 0x0E, 0x25: 0x0F, 0x2E: 0x10, 0x2D: 0x11, 0x1F: 0x12, 0x23: 0x13,
        0x0C: 0x14, 0x0F: 0x15, 0x01: 0x16, 0x11: 0x17, 0x20: 0x18, 0x09: 0x19, 0x0D: 0x1A, 0x07: 0x1B,
        0x10: 0x1C, 0x06: 0x1D, // letters
        0x12: 0x1E, 0x13: 0x1F, 0x14: 0x20, 0x15: 0x21, 0x17: 0x22, 0x16: 0x23, 0x1A: 0x24, 0x1C: 0x25,
        0x19: 0x26, 0x1D: 0x27, // digits
        0x31: 0x2C, // Space
        0x1B: 0x2D, 0x18: 0x2E, 0x21: 0x2F, 0x1E: 0x30, 0x2A: 0x31, 0x29: 0x33, 0x27: 0x34,
        0x2B: 0x36, 0x2F: 0x37, 0x2C: 0x38, // punctuation
        0x32: 0x35, // kVK_ANSI_Grave: the key left of 1 on ANSI
        0x0A: 0x64, // kVK_ISO_Section: the key right of left Shift on ISO
    ]

    public static let space: Stroke = [0x2C, 0]

    /// A stroke that types a character (the broker's wire.CharStroke): a
    /// character key (letters and digits 0x04–0x27, space and punctuation
    /// 0x2C–0x38, the ISO key 0x64; not Return, Escape, Backspace or Tab)
    /// with Shift and Option at most. Anything else in a secret step could
    /// send the rest of a password elsewhere (⌘Tab).
    public static func isCharStroke(_ s: Stroke) -> Bool {
        guard s.count == 2 else { return false }
        let k = s[0]
        return ((0x04...0x27).contains(k) || (0x2C...0x38).contains(k) || k == 0x64) && s[1] & ~0x66 == 0
    }

    /// A key map the broker takes: one character per entry, typed by one or
    /// two character strokes. The daemon drops a map that breaks this.
    public static func isValid(_ map: [String: [Stroke]]) -> Bool {
        map.allSatisfy { c, strokes in c.unicodeScalars.count == 1 && (1...2).contains(strokes.count) && strokes.allSatisfy(isCharStroke) }
    }

    /// The HID usage for a key code. On a keyboard macOS takes for ISO it
    /// swaps the two keys (a § key left of 1 reports kVK_ISO_Section), so
    /// the usage that reaches each key code swaps too.
    public static func usage(keyCode: UInt16, iso: Bool) -> UInt8? {
        if iso {
            if keyCode == 0x0A { return 0x35 }
            if keyCode == 0x32 { return 0x64 }
        }
        return usage[keyCode]
    }

    /// UCKeyTranslate's modifier states (EventModifiers >> 8), plainest
    /// first, with the stroke's modifier byte.
    static let modifiers: [(state: UInt32, hid: UInt8)] = [(0, 0), (0x02, shift), (0x08, option), (0x0A, shift | option)]

    /// The key map for a layout (`uchr` data) on a keyboard type. A character
    /// takes the plainest strokes that type it; one that only a dead key
    /// types is the dead key, then Space.
    public static func map(layout: Data, keyboardType: UInt32) -> [String: [Stroke]] {
        let iso = KBGetLayoutType(Int16(truncatingIfNeeded: keyboardType)) == kKeyboardISO
        let keys = usage.keys.sorted { usage[$0]! < usage[$1]! }
        var out: [String: [Stroke]] = [:]
        layout.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let uchr = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            func translate(_ key: UInt16, _ state: UInt32, _ dead: inout UInt32) -> String? {
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                guard UCKeyTranslate(uchr, key, UInt16(kUCKeyActionDown), state, keyboardType, 0, &dead, 4, &length,
                                     &chars) == noErr else { return nil }
                return String(utf16CodeUnits: chars, count: length)
            }
            func printable(_ s: String?) -> String? {
                guard let s, s.unicodeScalars.count == 1, let v = s.unicodeScalars.first?.value, (0x20...0x7E).contains(v) else {
                    return nil
                }
                return s
            }
            // Keys that type the character themselves.
            for (state, hid) in modifiers {
                for key in keys {
                    var dead: UInt32 = 0
                    guard let c = printable(translate(key, state, &dead)), dead == 0, out[c] == nil,
                          let u = self.usage(keyCode: key, iso: iso) else { continue }
                    out[c] = [[u, hid]]
                }
            }
            // Dead keys, then Space: the accent alone (^ ` ~ on many layouts).
            for (state, hid) in modifiers {
                for key in keys {
                    var dead: UInt32 = 0
                    guard translate(key, state, &dead)?.isEmpty == true, dead != 0,
                          let c = printable(translate(0x31, 0, &dead)), out[c] == nil,
                          let u = self.usage(keyCode: key, iso: iso) else { continue }
                    out[c] = [[u, hid], space]
                }
            }
        }
        return out
    }

    /// The active input source (the agent, on the main thread) and the
    /// keyboard type to read it with: the last-used keyboard's, which on the
    /// target is the JetKVM's.
    public static func current() -> (id: String, layout: Data, keyboardType: UInt32)? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let data = data(of: source) else { return nil }
        return (id(of: source) ?? "?", data, UInt32(LMGetKbdType()))
    }

    /// An installed layout's data, by input source id (tests).
    public static func layoutData(id: String) -> Data? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first else { return nil }
        return data(of: source)
    }

    /// A keyboard type macOS classifies as `layoutType` (kKeyboardANSI, …).
    public static func keyboardType(_ layoutType: Int) -> UInt32? {
        (UInt32(40)..<256).first { Int(KBGetLayoutType(Int16($0))) == layoutType }
    }

    static func data(of source: TISInputSource) -> Data? {
        guard let p = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(p).takeUnretainedValue() as Data
    }

    static func id(of source: TISInputSource) -> String? {
        guard let p = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }
}
