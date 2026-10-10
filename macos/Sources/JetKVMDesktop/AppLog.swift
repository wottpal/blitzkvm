import Foundation

/// Appends diagnostics (including every engine helper's stderr) to
/// ~/Library/Logs/jetkvm-desktop/app.log, next to the Go client's logs. The
/// file is rotated to app.log.1 when it passes 10 MB. When started from a
/// terminal, lines are echoed to stderr too.
enum AppLog {
    private static let maxSize = 10 << 20
    private static let queue = DispatchQueue(label: "jetkvm.applog", qos: .utility)
    private static let echo = isatty(STDERR_FILENO) == 1
    private static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/jetkvm-desktop")
    // Queue state.
    private static var fd: Int32 = -1
    private static var size = 0

    static var path: String { directory.appendingPathComponent("app.log").path }

    /// Writes text, each line prefixed with `prefix`.
    static func write(_ text: String, prefix: String = "") {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { prefix + $0 + "\n" }.joined()
        guard !lines.isEmpty else { return }
        let data = Data(lines.utf8)
        queue.async {
            if fd < 0 || size > maxSize { reopen(rotating: fd >= 0 || currentSize() > maxSize) }
            if fd >= 0 {
                // O_APPEND: several app processes may share the file.
                _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                size += data.count
            }
            if echo { FileHandle.standardError.write(data) }
        }
    }

    static func log(_ message: String) {
        write(message, prefix: ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime, .withFractionalSeconds]) + " ")
    }

    /// Blocks until queued lines are written (before exiting).
    static func flush() {
        queue.sync {}
    }

    private static func currentSize() -> Int {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
    }

    private static func reopen(rotating: Bool) {
        if fd >= 0 { close(fd) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if rotating && currentSize() > maxSize {
            let old = directory.appendingPathComponent("app.log.1").path
            unlink(old)
            rename(path, old)
        }
        fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        size = currentSize()
    }
}
