import ApprovalKit
import Foundation

/// One line on the host link (PROTOCOL.md, "Link"): every op's fields in
/// one struct, as the broker's linkMsg has them.
public struct LinkMessage: Codable {
    public var op: String
    public var broker: String?
    public var nonce: B64Data?
    public var auth: Envelope?
    public var roster: Envelope?
    public var ask: Envelope?
    public var request: Envelope?
    public var decision: Envelope?
    public var id: String?
    public var reason: String?
    public var seq: Int?
    public var step: Step?
    public var ok: Bool?
    public var error: String?
    public var note: String?
    /// stepped, for a secret step: characters fully typed (also on failure).
    public var typed: Int?
    /// unlock: an approver's signed request (UnlockRequest).
    public var unlock: Envelope?

    public init(op: String, broker: String? = nil, nonce: B64Data? = nil, auth: Envelope? = nil, roster: Envelope? = nil,
                ask: Envelope? = nil, request: Envelope? = nil, decision: Envelope? = nil, id: String? = nil,
                reason: String? = nil, seq: Int? = nil, step: Step? = nil, ok: Bool? = nil, error: String? = nil,
                note: String? = nil, typed: Int? = nil, unlock: Envelope? = nil) {
        self.op = op; self.broker = broker; self.nonce = nonce; self.auth = auth; self.roster = roster; self.ask = ask
        self.request = request; self.decision = decision; self.id = id; self.reason = reason; self.seq = seq
        self.step = step; self.ok = ok; self.error = error; self.note = note; self.typed = typed
        self.unlock = unlock
    }
}

/// One line on the daemon's local socket.
///
/// Requesters: `confirm` (any user) and `pam` (root: the PAM module's
/// client) each send one request, then read `info` lines and one `result`;
/// so does `maintain` (an owner's signed order, from any user).
/// The agent sends `agent`, then `facts` whenever they change; the daemon
/// sends it `refresh` (answer with facts now, echoing `seq`) and `activate`.
public struct LocalMessage: Codable, Equatable {
    public var op: String
    // confirm
    public var title: String?
    public var detail: String?
    public var grant: Bool?
    public var timeout: Int?
    // pam
    public var user: String?
    public var service: String?
    public var tty: String?
    public var pid: Int32?
    // replies to requesters
    public var text: String?
    public var result: String?
    // agent
    public var facts: AgentFacts?
    public var seq: Int?
    public var app: AppRef?
    // maintain: an owner's signed order
    public var order: Envelope?

    public init(op: String, title: String? = nil, detail: String? = nil, grant: Bool? = nil, timeout: Int? = nil,
                user: String? = nil, service: String? = nil, tty: String? = nil, pid: Int32? = nil, text: String? = nil,
                result: String? = nil, facts: AgentFacts? = nil, seq: Int? = nil, app: AppRef? = nil, order: Envelope? = nil) {
        self.op = op; self.title = title; self.detail = detail; self.grant = grant; self.timeout = timeout
        self.user = user; self.service = service; self.tty = tty; self.pid = pid; self.text = text
        self.result = result; self.facts = facts; self.seq = seq; self.app = app; self.order = order
    }
}

/// How a request ended, as the requester's client reports it.
public enum Outcome: String, Codable {
    case approved, denied, timeout, unavailable, refused

    /// confirm's exit status: 0 approved, 1 denied, 2 anything else.
    public var confirmExit: Int32 {
        switch self {
        case .approved: return 0
        case .denied: return 1
        default: return 2
        }
    }
}
