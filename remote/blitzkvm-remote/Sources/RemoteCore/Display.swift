import Foundation

/// Text from processes (arguments, paths, names, a confirm question, a
/// broker's reason) made safe to show: approvers and terminals render it,
/// so nothing in it may pass for something else. Control characters become
/// visible escapes (\n, \t, \x1b), bidi controls become \u{202E}, and a
/// command's arguments are shell-quoted, so one argument can't pose as two.
public enum Display {
    public static let truncated = "…(truncated)"

    static let bidi: Set<UInt32> = [0x200E, 0x200F, 0x061C, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
                                    0x2066, 0x2067, 0x2068, 0x2069]

    /// One string, at most `maxBytes` UTF-8 bytes (truncation is marked).
    public static func safe(_ s: String, maxBytes: Int = .max) -> String {
        clip(s.unicodeScalars.map(escape), maxBytes: maxBytes)
    }

    /// A command line: each argument made safe, and quoted when it holds
    /// anything but plain word characters.
    public static func command(_ args: [String], maxBytes: Int = .max) -> String {
        var tokens: [String] = []
        for (i, a) in args.enumerated() {
            if i > 0 { tokens.append(" ") }
            tokens.append(contentsOf: quoted(a))
        }
        return clip(tokens, maxBytes: maxBytes)
    }

    static func escape(_ c: Unicode.Scalar) -> String {
        switch c.value {
        case 0x0A: return "\\n"
        case 0x09: return "\\t"
        case 0x0D: return "\\r"
        case 0x00..<0x20, 0x7F, 0x80..<0xA0: return String(format: "\\x%02x", c.value)
        case _ where bidi.contains(c.value) || hidden(c): return String(format: "\\u{%04X}", c.value)
        default: return String(c)
        }
    }

    /// What renders as a line break or not at all: line and paragraph
    /// separators, format characters (zero-width ones, tags) and other
    /// default-ignorable code points; a request could fake a line with them,
    /// or hide a letter.
    static func hidden(_ c: Unicode.Scalar) -> Bool {
        switch c.properties.generalCategory {
        case .lineSeparator, .paragraphSeparator, .format, .control: return true
        default: return c.properties.isDefaultIgnorableCodePoint
        }
    }

    static let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")

    /// An argument as shell tokens: as is, or in single quotes (a quote
    /// inside becomes '\'').
    static func quoted(_ a: String) -> [String] {
        let escaped = a.unicodeScalars.map(escape)
        if !a.isEmpty, a.unicodeScalars.allSatisfy(plain.contains) { return escaped }
        return ["'"] + escaped.map { $0 == "'" ? "'\\''" : $0 } + ["'"]
    }

    /// Joins tokens, stopping between them before `maxBytes` (an escape is
    /// never cut in half).
    static func clip(_ tokens: [String], maxBytes: Int) -> String {
        let total = tokens.reduce(0) { $0 + $1.utf8.count }
        guard total > maxBytes else { return tokens.joined() }
        let budget = max(0, maxBytes - truncated.utf8.count)
        var out = ""
        var used = 0
        for t in tokens {
            guard used + t.utf8.count <= budget else { break }
            out += t
            used += t.utf8.count
        }
        return out + truncated
    }
}
