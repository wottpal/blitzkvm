import Foundation

/// Maps macOS virtual key codes (kVK_*) to USB HID keyboard usages.
public enum KeyMap {
    /// Physical-position mapping: the remote's own layout decides which
    /// character a key produces, exactly like a USB keyboard would.
    public static let usage: [UInt16: UInt8] = [
        // Letters (ANSI positions)
        0x00: 0x04, 0x0B: 0x05, 0x08: 0x06, 0x02: 0x07, 0x0E: 0x08, 0x03: 0x09,
        0x05: 0x0A, 0x04: 0x0B, 0x22: 0x0C, 0x26: 0x0D, 0x28: 0x0E, 0x25: 0x0F,
        0x2E: 0x10, 0x2D: 0x11, 0x1F: 0x12, 0x23: 0x13, 0x0C: 0x14, 0x0F: 0x15,
        0x01: 0x16, 0x11: 0x17, 0x20: 0x18, 0x09: 0x19, 0x0D: 0x1A, 0x07: 0x1B,
        0x10: 0x1C, 0x06: 0x1D,
        // Digits row
        0x12: 0x1E, 0x13: 0x1F, 0x14: 0x20, 0x15: 0x21, 0x17: 0x22, 0x16: 0x23,
        0x1A: 0x24, 0x1C: 0x25, 0x19: 0x26, 0x1D: 0x27,
        // Control and punctuation
        0x24: 0x28, // Return
        0x35: 0x29, // Escape
        0x33: 0x2A, // Delete (Backspace)
        0x30: 0x2B, // Tab
        0x31: 0x2C, // Space
        0x1B: 0x2D, // - _
        0x18: 0x2E, // = +
        0x21: 0x2F, // [ {
        0x1E: 0x30, // ] }
        0x2A: 0x31, // \ |
        0x29: 0x33, // ; :
        0x27: 0x34, // ' "
        0x32: 0x35, // ` ~ (ANSI; on ISO keyboards this is the key left of Z)
        0x2B: 0x36, // , <
        0x2F: 0x37, // . >
        0x2C: 0x38, // / ?
        0x0A: 0x64, // ISO section key (§ ±), "non-US \\ and |"
        0x39: 0x39, // Caps Lock
        // Function keys
        0x7A: 0x3A, 0x78: 0x3B, 0x63: 0x3C, 0x76: 0x3D, 0x60: 0x3E, 0x61: 0x3F,
        0x62: 0x40, 0x64: 0x41, 0x65: 0x42, 0x6D: 0x43, 0x67: 0x44, 0x6F: 0x45,
        0x69: 0x68, 0x6B: 0x69, 0x71: 0x6A, 0x6A: 0x6B, 0x40: 0x6C, 0x4F: 0x6D,
        0x50: 0x6E, 0x5A: 0x6F,
        // Navigation
        0x72: 0x49, // Help → Insert
        0x73: 0x4A, // Home
        0x74: 0x4B, // Page Up
        0x75: 0x4C, // Forward Delete
        0x77: 0x4D, // End
        0x79: 0x4E, // Page Down
        0x7C: 0x4F, // Right
        0x7B: 0x50, // Left
        0x7D: 0x51, // Down
        0x7E: 0x52, // Up
        // Keypad
        0x47: 0x53, // Clear → Num Lock
        0x4B: 0x54, 0x43: 0x55, 0x4E: 0x56, 0x45: 0x57, 0x4C: 0x58,
        0x53: 0x59, 0x54: 0x5A, 0x55: 0x5B, 0x56: 0x5C, 0x57: 0x5D,
        0x58: 0x5E, 0x59: 0x5F, 0x5B: 0x60, 0x5C: 0x61, 0x52: 0x62,
        0x41: 0x63, 0x51: 0x67,
        // JIS
        0x5D: 0x89, // ¥
        0x5E: 0x87, // _ (Ro)
        0x66: 0x91, // 英数 (LANG2)
        0x68: 0x90, // かな (LANG1)
        0x6E: 0x65, // Context menu (PC keyboards)
    ]

    /// HID usages of modifier keys, keyed by macOS key code.
    public static let modifierUsage: [UInt16: UInt8] = [
        0x3B: 0xE0, // Left Control
        0x38: 0xE1, // Left Shift
        0x3A: 0xE2, // Left Option → Left Alt
        0x37: 0xE3, // Left Command → Left GUI
        0x3E: 0xE4, // Right Control
        0x3C: 0xE5, // Right Shift
        0x3D: 0xE6, // Right Option → Right Alt (AltGr)
        0x36: 0xE7, // Right Command → Right GUI
    ]

    /// Device-dependent modifier flag bits (NX_DEVICE*KEYMASK) that tell
    /// left and right modifiers apart in flagsChanged events.
    public static let modifierDeviceMask: [UInt16: UInt64] = [
        0x3B: 0x0000_0001, // left control
        0x38: 0x0000_0002, // left shift
        0x3C: 0x0000_0004, // right shift
        0x37: 0x0000_0008, // left command
        0x36: 0x0000_0010, // right command
        0x3A: 0x0000_0020, // left option
        0x3D: 0x0000_0040, // right option
        0x3E: 0x0000_2000, // right control
    ]

    public static let capsLockKeyCode: UInt16 = 0x39
    public static let capsLockUsage: UInt8 = 0x39

    /// HID usage for a key code from an ISO or ANSI keyboard, for a remote
    /// running `remote`.
    ///
    /// A Mac can't identify the JetKVM's keyboard and treats it as ANSI,
    /// turning each usage straight back into its key code, so key codes pass
    /// through unchanged and the same layout types the same characters. A PC
    /// types by physical position: on ISO keyboards macOS reports the key
    /// left of "1" (§ / ^) as kVK_ISO_Section and the key right of left Shift
    /// (` / <) as kVK_ANSI_Grave, the opposite of their PC positions, so they
    /// are swapped back to what a PC ISO keyboard sends.
    public static func hidUsage(keyCode: UInt16, isISO: Bool, remote: ModifierProfile) -> UInt8? {
        if isISO && remote == .pc {
            if keyCode == 0x0A { return 0x35 }
            if keyCode == 0x32 { return 0x64 }
        }
        return usage[keyCode]
    }
}

/// The remote's operating system: how Mac modifiers, and the two ISO keys
/// (KeyMap.hidUsage), map onto it.
public enum ModifierProfile: String, CaseIterable {
    /// Remote is a Mac: ⌘ stays GUI (⌘), ⌥ stays Alt (⌥).
    case mac
    /// Remote is Linux/Windows: swap ⌘ and ⌃, so ⌘C on the Mac sends Ctrl+C.
    case pc

    public func apply(_ usage: UInt8) -> UInt8 {
        guard self == .pc else { return usage }
        switch usage {
        case 0xE0: return 0xE3
        case 0xE3: return 0xE0
        case 0xE4: return 0xE7
        case 0xE7: return 0xE4
        default: return usage
        }
    }
}

/// A quick double press of ⌘ alone (⌘ ⌘): hands the keyboard to the remote
/// without a click. Any other key or modifier in between cancels it, so
/// shortcuts (⌘C, ⌘Tab) never count.
public struct DoubleCommandPress {
    /// The longest gap between the two presses.
    public var interval: TimeInterval = 0.4
    private var firstPress: TimeInterval?

    public init() {}

    /// A modifier change; true when it completes the double press.
    public mutating func flagsChanged(commandDown: Bool, othersDown: Bool, at time: TimeInterval) -> Bool {
        guard !othersDown else {
            firstPress = nil
            return false
        }
        guard commandDown else { return false } // a release: keep waiting
        if let first = firstPress, time - first <= interval {
            firstPress = nil
            return true
        }
        firstPress = time
        return false
    }

    /// Any other key cancels it.
    public mutating func keyPressed() {
        firstPress = nil
    }
}
