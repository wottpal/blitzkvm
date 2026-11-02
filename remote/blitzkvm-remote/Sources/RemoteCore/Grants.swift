import Foundation

/// Approvals that cover what follows for a while: an approver's "for 10
/// minutes" on a sudo or confirm ask lets the same user, under the same
/// anchor, from the same terminal and audit session, skip asking for that
/// kind. In memory only: a restart of the daemon ends every grant.
public struct Grants {
    public struct Key: Hashable {
        public var kind: String
        public var uid: uid_t
        public var anchor: Anchor
        public var tty: String?
        /// The audit session (a login, an SSH connection) of the requester.
        public var session: Int32?

        public init(kind: String, uid: uid_t, anchor: Anchor, tty: String?, session: Int32?) {
            self.kind = kind; self.uid = uid; self.anchor = anchor; self.tty = tty; self.session = session
        }
    }

    private var until: [Key: (until: Double, by: String?)] = [:]

    public init() {}

    /// `by`: the approver who granted it; a roster without them ends it.
    public mutating func add(_ key: Key, minutes: Int, now: Double, by approver: String? = nil) {
        until[key] = (now + Double(minutes) * 60, approver)
    }

    public mutating func covers(_ key: Key, now: Double) -> Bool {
        until = until.filter { $0.value.until > now }
        return until[key] != nil
    }

    /// Ends the grants of approvers no longer in the roster.
    public mutating func keep(approvers: Set<String>) {
        until = until.filter { $0.value.by.map(approvers.contains) ?? true }
    }

    public var count: Int { until.count }
}
