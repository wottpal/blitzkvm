import ApprovalKit
import Foundation

/// What the relay's push carries: `{"bka":{"b":<broker id>,"x":<box b64>}}`;
/// `x` is missing when the box didn't fit (the app fetches its outbox).
struct ApprovalPush: Equatable {
    let brokerID: String
    let box: Data?

    init?(userInfo: [AnyHashable: Any]) {
        guard let bka = userInfo["bka"] as? [String: Any], let b = bka["b"] as? String, !b.isEmpty else { return nil }
        brokerID = b
        box = (bka["x"] as? String).flatMap(B64.decode)
    }
}

/// A pushed box, opened and checked against the paired broker's roster.
enum PushedMessage {
    case request(VerifiedRequest, broker: PairedBroker, roster: Roster)
    /// A device asked to pair (owners only).
    case enrolling(name: String, broker: PairedBroker)

    private struct Message: Decodable {
        let op: String
        let request: Envelope?
        let enroll: Envelope?
    }

    /// Opens a push's box with the approver's seal key. Nil for anything
    /// that doesn't open, isn't from a paired broker or doesn't verify.
    init?(_ push: ApprovalPush, seal: SealKey, brokers: [PairedBroker], now: Int64) {
        guard let box = push.box, let broker = brokers.first(where: { $0.id == push.brokerID }),
              let roster = broker.decodedRoster, let data = try? seal.open(box),
              let m = try? Wire.decoder.decode(Message.self, from: data) else { return nil }
        switch m.op {
        case "request":
            guard let env = m.request, let verified = try? VerifiedRequest(env, roster: roster, now: now) else { return nil }
            self = .request(verified, broker: broker, roster: roster)
        case "enrolling":
            // Self-signed by the new device's presence key, as the center checks it.
            guard let env = m.enroll, let peek = try? env.peek(Enroll.self),
                  let e = try? env.open(Enroll.self, type: "enroll", key: peek.approver.presence.data) else { return nil }
            self = .enrolling(name: e.approver.name, broker: broker)
        default:
            return nil
        }
    }
}

/// The text of an approval notification. Never carries a secret: asks
/// don't contain any, and stored passwords never leave the vault here.
struct NotificationText: Equatable {
    var title: String
    var body: String
    var thread: String
    var requestID: String?

    init(title: String, body: String, thread: String, requestID: String?) {
        self.title = title; self.body = body; self.thread = thread; self.requestID = requestID
    }

    /// "<target>: <ask title>" / "Code <code> · <kind>".
    init(request: VerifiedRequest, roster: Roster, brokerID: String) {
        let target = roster.target(request.ask.target)?.name ?? "Computer"
        self.init(title: "\(target): \(request.ask.title)", body: "Code \(request.code) · \(KindInfo.name(request.ask.kind))",
                  thread: brokerID, requestID: request.id)
    }

    init(_ message: PushedMessage) {
        switch message {
        case let .request(verified, broker, roster):
            self.init(request: verified, roster: roster, brokerID: broker.id)
        case let .enrolling(name, broker):
            self.init(title: broker.name, body: "“\(name)” asks to pair. Open to review.", thread: broker.id, requestID: nil)
        }
    }
}
