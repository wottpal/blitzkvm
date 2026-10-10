import Foundation

/// Turns serial console output into plain text for display. JetKVM's
/// console broker passes ANSI CSI/OSC sequences through and shows other
/// control characters as names (<BS>); this removes the ANSI sequences,
/// turns line endings into single line breaks and drops stray control
/// characters. Sequences split across chunks are handled; a sequence that
/// never ends (line noise at the wrong baud rate) cannot swallow output.
public struct SerialTextFilter {
    private var pending: [Character] = []
    /// A carriage return was seen; the next character decides whether it
    /// was a line ending (CR, CRLF, CR CR LF) or a return to line start.
    private var afterCR = false
    /// Longest sequence held back while waiting for its end.
    static let maxPending = 256

    public init() {}

    public mutating func feed(_ chunk: String) -> String {
        var input = pending
        input.append(contentsOf: chunk)
        pending = []
        var out = ""
        var i = 0
        while i < input.count {
            let c = input[i]
            if c == "\u{1B}" {
                switch Self.escapeEnd(input, from: i) {
                case .complete(let end):
                    i = end + 1
                    continue
                case .aborted(let resume):
                    i = resume // drop the broken sequence, keep what follows
                    continue
                case .incomplete:
                    if input.count - i <= Self.maxPending {
                        pending = Array(input[i...])
                        return out
                    }
                    i += 1 // too long to be a real sequence: drop the ESC
                    continue
                }
            }
            switch c {
            case "\r\n", "\n":
                out.append("\n")
                afterCR = false
            case "\r":
                afterCR = true
            case "\t":
                emit(c, into: &out)
            default:
                if let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1,
                   scalar.value < 0x20 || scalar.value == 0x7F {
                    break // bell, backspace, …
                }
                emit(c, into: &out)
            }
            i += 1
        }
        return out
    }

    private mutating func emit(_ c: Character, into out: inout String) {
        if afterCR {
            // A lone CR (progress output): start a new line instead of
            // overwriting, which plain text cannot do.
            out.append("\n")
            afterCR = false
        }
        out.append(c)
    }

    private enum Escape { case complete(Int), aborted(Int), incomplete }

    /// Controls that cancel an escape sequence (CAN, SUB, ESC) or that no
    /// sequence contains (line breaks).
    private static func aborts(_ c: Character) -> Bool {
        ["\u{18}", "\u{1A}", "\u{1B}", "\n", "\r", "\r\n"].contains(c)
    }

    private static func escapeEnd(_ s: [Character], from start: Int) -> Escape {
        guard start + 1 < s.count else { return .incomplete }
        let kind = s[start + 1]
        var j = start + 2
        switch kind {
        case "[": // CSI: parameters, then a final byte @…~
            while j < s.count {
                if aborts(s[j]) { return .aborted(j) }
                if let v = s[j].asciiValue, (0x40...0x7E).contains(v) { return .complete(j) }
                j += 1
            }
            return .incomplete
        case "]": // OSC: until BEL or ESC \\
            while j < s.count {
                if s[j] == "\u{07}" { return .complete(j) }
                if s[j] == "\u{1B}" {
                    guard j + 1 < s.count else { return .incomplete }
                    return s[j + 1] == "\\" ? .complete(j + 1) : .aborted(j)
                }
                if aborts(s[j]) { return .aborted(j) }
                j += 1
            }
            return .incomplete
        default:
            // ESC, intermediates 0x20–0x2F, then a final byte (e.g. ESC ( B).
            j = start + 1
            while j < s.count, let v = s[j].asciiValue, (0x20...0x2F).contains(v) { j += 1 }
            guard j < s.count else { return .incomplete }
            return aborts(s[j]) ? .aborted(j) : .complete(j)
        }
    }
}

/// Keys typed in the serial console, as the bytes a terminal sends.
public enum SerialKeys {
    public static let controlC = "\u{03}"
    public static let controlD = "\u{04}"
    public static let escape = "\u{1B}"
}
