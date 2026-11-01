import Foundation
import IOKit

/// The console session as the window server publishes it in the IORegistry
/// (IOConsoleUsers): readable by any user, no permission, no prompt.
public struct ConsoleState: Equatable {
    public var uid: uid_t?
    /// Present only while the screen is locked.
    public var locked: Bool
    /// The process holding secure input (a focused password field), if any.
    public var secureInputPID: Int32?

    public init(uid: uid_t? = nil, locked: Bool = false, secureInputPID: Int32? = nil) {
        self.uid = uid; self.locked = locked; self.secureInputPID = secureInputPID
    }
}

public enum Console {
    public static func read() -> ConsoleState {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard let value = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue(), let sessions = value as? [[String: Any]] else { return ConsoleState() }
        return parse(sessions)
    }

    /// The on-console session's state; other sessions (fast user switching)
    /// don't own the screen.
    public static func parse(_ sessions: [[String: Any]]) -> ConsoleState {
        guard let s = sessions.first(where: { ($0["kCGSSessionOnConsoleKey"] as? NSNumber)?.boolValue == true }) else {
            return ConsoleState()
        }
        return ConsoleState(uid: (s["kCGSSessionUserIDKey"] as? NSNumber).map { uid_t($0.uint32Value) },
                            locked: (s["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false,
                            secureInputPID: (s["kCGSSessionSecureInputPID"] as? NSNumber).map { $0.int32Value })
    }
}
