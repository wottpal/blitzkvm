import Foundation

enum Format {
    /// A key id in groups of four ("1a2b 3c4d …"), for reading aloud.
    static func grouped(_ id: String) -> String {
        stride(from: 0, to: id.count, by: 4).map { i in
            let start = id.index(id.startIndex, offsetBy: i)
            return String(id[start..<(id.index(start, offsetBy: 4, limitedBy: id.endIndex) ?? id.endIndex)])
        }.joined(separator: " ")
    }

    /// A relay URL's host, as the UI names it.
    static func host(_ url: String?) -> String? {
        guard let url, let host = URL(string: url)?.host() else { return nil }
        return host
    }

    /// "0:42", "1:30": the time left of a request.
    static func timeLeft(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
