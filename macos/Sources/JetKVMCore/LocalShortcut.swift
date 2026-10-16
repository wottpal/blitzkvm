import Foundation

/// A key combination that stays on this Mac while the keyboard goes to the
/// remote computer: a key with modifiers (⌃⌥D), or modifiers alone (⌥ fn,
/// as dictation apps use). Settings › Shortcuts.
public struct LocalShortcut: Codable, Equatable, Hashable, Identifiable {
    /// The key (a Mac virtual key code); nil for modifiers alone.
    public var keyCode: UInt16?
    /// The modifiers held (`LocalShortcut.flagsMask` bits of CGEventFlags).
    public var modifiers: UInt64
    /// How the key was labeled when recorded ("D", "Space").
    public var keyLabel: String?
    /// The window takes the keyboard back when it's in front again after
    /// the shortcut (a dictation app's window came and went).
    public var keepsControl: Bool

    public init(keyCode: UInt16?, modifiers: UInt64, keyLabel: String? = nil, keepsControl: Bool = false) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.flagsMask
        self.keyLabel = keyLabel
        self.keepsControl = keepsControl
    }

    // Shortcuts saved before keepsControl existed decode without it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(keyCode: try container.decodeIfPresent(UInt16.self, forKey: .keyCode),
                  modifiers: try container.decode(UInt64.self, forKey: .modifiers),
                  keyLabel: try container.decodeIfPresent(String.self, forKey: .keyLabel),
                  keepsControl: try container.decodeIfPresent(Bool.self, forKey: .keepsControl) ?? false)
    }

    /// The keys pressed: one shortcut per combination.
    public var id: String { "\(keyCode.map(String.init) ?? "-"):\(modifiers)" }

    // CGEventFlags bits (device independent).
    public static let shift: UInt64 = 0x0002_0000
    public static let control: UInt64 = 0x0004_0000
    public static let option: UInt64 = 0x0008_0000
    public static let command: UInt64 = 0x0010_0000
    public static let function: UInt64 = 0x0080_0000
    public static let flagsMask = shift | control | option | command | function

    private static let symbols: [(UInt64, String)] = [(control, "⌃"), (option, "⌥"), (shift, "⇧"), (command, "⌘")]

    /// The keys one by one, in the order macOS shows them: ⌃ ⌥ ⇧ ⌘ fn D.
    public var keys: [String] {
        Self.symbols.filter { modifiers & $0.0 != 0 }.map(\.1)
            + (modifiers & Self.function != 0 ? ["fn"] : [])
            + (keyCode != nil ? [keyLabel ?? "Key"] : [])
    }

    /// "⌃⌥⇧⌘ fn D": the modifier symbols together, fn and the key apart.
    public var title: String {
        let symbols = Self.symbols.filter { modifiers & $0.0 != 0 }.map(\.1)
        return ([symbols.joined()].filter { !$0.isEmpty } + keys.dropFirst(symbols.count)).joined(separator: " ")
    }

    /// A key pressed with `flags` (CGEventFlags) is this shortcut.
    public func matches(keyCode: UInt16, flags: UInt64) -> Bool {
        self.keyCode == keyCode && flags & Self.flagsMask == modifiers
    }

    /// Modifiers alone, now `flags`, are this shortcut.
    public func matches(flags: UInt64) -> Bool {
        keyCode == nil && modifiers != 0 && flags & Self.flagsMask == modifiers
    }
}
