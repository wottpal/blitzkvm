import ApprovalKit
import Foundation

/// What the review screen shows for a request: plain values, so the rules
/// (grant only when grantable, a password row only when the ask needs one)
/// are testable without views.
struct ReviewContent: Equatable {
    struct ProcessRow: Equatable, Identifiable {
        let id: Int
        let name: String
        let pid: Int
        let path: String?
        let arguments: String?
        let signer: Signer?
    }

    struct Signer: Equatable {
        let label: String
        /// Apple or a Developer ID; ad hoc and unsigned code is flagged.
        let trusted: Bool
    }

    struct Fact: Equatable, Identifiable {
        var id: String { label }
        let label: String
        let value: String
    }

    struct SecretNeed: Equatable {
        let kind: String
        let name: String
        let stored: Bool
    }

    let title: String
    let detail: String?
    let kind: String
    let kindName: String
    let symbol: String
    let targetName: String
    let brokerName: String
    let code: String
    let requester: String?
    let chain: [ProcessRow]
    let evidence: [Fact]
    /// "Approve for 10 Minutes" is offered.
    let canGrant: Bool
    /// The password this ask can take, and whether one is stored.
    let secret: SecretNeed?
    let expires: Date
    /// Unlock asks: the approver that asked for it, and whether that was
    /// another device than this iPhone.
    let requestedBy: String?
    let requestedElsewhere: Bool

    /// `me` is this iPhone's approver id.
    init(ask: Ask, code: String, roster: Roster?, brokerName: String, secretStored: Bool, me: String? = nil) {
        title = ask.title
        detail = ask.detail.flatMap { $0.isEmpty ? nil : $0 }
        kind = ask.kind
        kindName = KindInfo.name(ask.kind)
        symbol = KindInfo.symbol(ask.kind)
        targetName = roster?.target(ask.target)?.name ?? "Unknown computer"
        self.brokerName = brokerName
        self.code = code
        canGrant = ask.isGrantable
        secret = ask.secret == SecretKind.none ? nil
            : SecretNeed(kind: ask.secret, name: KindInfo.secretName(ask.secret), stored: secretStored)
        expires = Date(timeIntervalSince1970: TimeInterval(ask.expires))
        if let id = ask.requestedBy {
            requestedBy = id == me ? "this iPhone" : roster?.approver(id)?.name ?? "an approver no longer listed"
            requestedElsewhere = id != me
        } else {
            requestedBy = nil
            requestedElsewhere = false
        }

        if let r = ask.requester {
            var who = "\(r.user) (uid \(r.uid))"
            if let tty = r.tty, !tty.isEmpty { who += " · \(tty)" }
            requester = who
            chain = r.chain.prefix(8).enumerated().map { i, p in
                let args = p.args.map { $0.joined(separator: " ") }.flatMap { $0.isEmpty ? nil : String($0.prefix(400)) }
                return ProcessRow(id: i, name: p.name, pid: p.pid, path: p.path, arguments: args, signer: p.signer.map(Self.signer))
            }
        } else {
            requester = nil
            chain = []
        }

        var facts: [Fact] = []
        if let e = ask.evidence {
            facts.append(Fact(label: "Screen", value: e.locked ? "Locked" : "Unlocked"))
            if let s = e.secureInput {
                facts.append(Fact(label: "Secure input", value: s.team.map { "\(s.bundle) (\($0))" } ?? s.bundle))
            }
            if let w = e.window {
                let n = Self.number
                var where_ = "\(n(w.w)) × \(n(w.h)) at \(n(w.x)), \(n(w.y))"
                if let d = e.display { where_ += " of \(n(d.w)) × \(n(d.h))" }
                facts.append(Fact(label: "Dialog", value: where_))
            }
        }
        evidence = facts
    }

    init(_ request: OpenRequest, broker: PairedBroker?, secretStored: Bool, me: String? = nil) {
        self.init(ask: request.ask, code: request.verified.code, roster: broker?.decodedRoster,
                  brokerName: broker?.name ?? "JetKVM", secretStored: secretStored, me: me)
    }

    /// A screen coordinate from the ask, whole; "?" for one no screen has
    /// (Int(_:) would trap on it).
    static func number(_ value: Double) -> String {
        value.isFinite && abs(value) < 1_000_000 ? String(Int(value)) : "?"
    }

    static func signer(_ raw: String) -> Signer {
        switch raw {
        case "apple": return Signer(label: "Apple", trusted: true)
        case "adhoc": return Signer(label: "Ad hoc signed", trusted: false)
        case "unsigned": return Signer(label: "Unsigned", trusted: false)
        default:
            if raw.hasPrefix("developer:") { return Signer(label: "Developer ID \(raw.dropFirst("developer:".count))", trusted: true) }
            return Signer(label: raw, trusted: false)
        }
    }
}
