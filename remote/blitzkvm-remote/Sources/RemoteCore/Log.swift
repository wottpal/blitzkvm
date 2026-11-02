import Foundation
import os

/// One log line to stderr (launchd writes the daemon's to a file) and to the
/// unified log (`log stream --predicate 'subsystem == "xyz.scio.blitzkvm.remote"'`).
/// Never log secrets: the daemon doesn't have them anyway.
public enum Log {
    static let logger = Logger(subsystem: "xyz.scio.blitzkvm.remote", category: "remote")
    private static let lock = NSLock()
    /// Tests turn stderr off.
    public static var toStderr = true

    /// launchd's log file (stderr): root's alone, and emptied at start once
    /// it grew past 5 MB.
    public static func boundStderr() {
        var st = stat()
        guard fstat(2, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return }
        _ = fchmod(2, 0o600)
        if st.st_size > 5 << 20 { _ = ftruncate(2, 0) }
    }

    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        guard toStderr else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        lock.lock()
        FileHandle.standardError.write(Data(line.utf8))
        lock.unlock()
    }
}
