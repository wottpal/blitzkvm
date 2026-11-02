import Combine
import Foundation

/// A broker this approver is paired with.
public struct PairedBroker: Codable, Identifiable, Hashable, Sendable {
    public var id: String { broker.id }
    public var broker: BrokerInfo
    public var name: String
    public var relay: String?
    /// The JetKVM's base URL (Macs connect directly when they can).
    public var direct: String?
    /// The owner who invited this approver: the only signer a first roster
    /// is accepted from.
    public var ownerHint: String?
    /// The roster sequence the invite was made at: an older first roster
    /// (a replay) isn't taken.
    public var minSeq: UInt64?
    public var roster: Envelope?
    /// This owner's newest roster until the broker has it: sent again when
    /// the broker answers with an older one.
    public var pendingRoster: Envelope?

    public init(broker: BrokerInfo, name: String, relay: String?, direct: String?, ownerHint: String?, roster: Envelope?,
                minSeq: UInt64? = nil) {
        self.broker = broker; self.name = name; self.relay = relay; self.direct = direct
        self.ownerHint = ownerHint; self.roster = roster; self.minSeq = minSeq
    }

    public var decodedRoster: Roster? { roster.flatMap { try? $0.peek(Roster.self) } }
}

/// What an owner shows in a QR code to pair another device.
public struct PairingInvite: Codable, Sendable {
    public var v = 1
    public var broker: BrokerInfo
    public var name: String
    public var relay: String?
    public var direct: String?
    public var token: B64Data
    public var owner: String
    public var seq: UInt64?

    public static let scheme = "blitzkvm-pair:"
    public var qrString: String { Self.scheme + B64.encode((try? Wire.encoder.encode(self)) ?? Data()) }

    public init?(qrString: String) {
        guard qrString.hasPrefix(Self.scheme), let data = B64.decode(String(qrString.dropFirst(Self.scheme.count))),
              let invite = try? Wire.decoder.decode(PairingInvite.self, from: data), invite.v == 1,
              invite.broker.id == Wire.kid(invite.broker.key.data) else { return nil }
        self = invite
    }

    init(broker: BrokerInfo, name: String, relay: String?, direct: String?, token: Data, owner: String, seq: UInt64?) {
        self.broker = broker; self.name = name; self.relay = relay; self.direct = direct
        self.token = B64Data(token); self.owner = owner; self.seq = seq
    }
}

/// A request waiting for this approver, or one it saw end.
public struct OpenRequest: Identifiable, Hashable, Sendable {
    public var id: String { verified.id }
    public let brokerID: String
    public let verified: VerifiedRequest
    public let received: Date
    public var state = "pending"
    public var by: String?
    public var note: String?
    public var ask: Ask { verified.ask }

    public init(brokerID: String, verified: VerifiedRequest, received: Date, state: String = "pending",
                by: String? = nil, note: String? = nil) {
        self.brokerID = brokerID; self.verified = verified; self.received = received
        self.state = state; self.by = by; self.note = note
    }
}

/// A device that asked to become an approver (shown to owners).
public struct Enrollment: Identifiable, Hashable, Sendable {
    public var id: String { approver.id }
    public let brokerID: String
    public let approver: Approver
}

/// Delivers boxes to a broker (directly or through the relay).
@MainActor
public protocol CenterTransport: AnyObject {
    func send(box: Data, to broker: PairedBroker)
}

/// The approver's state: paired brokers and their rosters, open requests,
/// enrollments; makes decisions and, for owners, rosters. Platform code
/// owns the transports, the UI and the biometric prompt.
@MainActor
public final class ApprovalCenter: ObservableObject {
    @Published public private(set) var brokers: [PairedBroker] = []
    @Published public private(set) var requests: [OpenRequest] = []
    @Published public private(set) var history: [OpenRequest] = []
    @Published public private(set) var enrollments: [Enrollment] = []

    public let keys: ApproverKeys
    public let name: String
    public let platform: String
    public weak var transport: CenterTransport?
    /// Called for each new request (post a notification).
    public var onRequest: ((OpenRequest) -> Void)?
    /// Called when a request ends, approved or not.
    public var onStatus: ((OpenRequest) -> Void)?
    public var now: () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    private let file: URL?
    /// Pairing tokens this owner issued (in memory): an enrollment is
    /// offered only with a valid MAC under one of them.
    /// Open invites by pairing hash, with the signed pairing that goes to
    /// the broker again on every sync until it expires (a channel may be
    /// down when the code is shown).
    private var invites: [Data: (token: Data, broker: String, expires: Int64, pairing: Envelope)] = [:]

    public init(keys: ApproverKeys, name: String, platform: String, file: URL?) {
        self.keys = keys; self.name = name; self.platform = platform; self.file = file
        if let file, let data = try? Data(contentsOf: file),
           let saved = try? Wire.decoder.decode([PairedBroker].self, from: data) {
            brokers = saved
        }
    }

    public var me: Approver { keys.approver(name: name, platform: platform) }

    public func broker(_ id: String) -> PairedBroker? { brokers.first { $0.id == id } }

    public func roster(_ brokerID: String) -> Roster? { broker(brokerID)?.decodedRoster }

    public func isOwner(_ brokerID: String) -> Bool { roster(brokerID)?.isOwner(keys.id) ?? false }

    private func save() {
        guard let file, let data = try? Wire.encoder.encode(brokers) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private func upsert(_ b: PairedBroker) {
        if let i = brokers.firstIndex(where: { $0.id == b.id }) { brokers[i] = b } else { brokers.append(b) }
        save()
    }

    public func remove(brokerID: String) {
        brokers.removeAll { $0.id == brokerID }
        requests.removeAll { $0.brokerID == brokerID }
        save()
    }

    /// Updates where a broker is reached (the app learns the device URL).
    public func setDirect(_ url: String?, brokerID: String) {
        guard var b = broker(brokerID) else { return }
        b.direct = url
        upsert(b)
    }

    // MARK: Incoming

    private struct Message: Decodable {
        let op: String
        let roster: Envelope?
        let request: Envelope?
        let enroll: Envelope?
        let id: String?
        let state: String?
        let by: String?
        let note: String?
    }

    /// Opens and handles a box from a broker.
    public func receive(box: Data, from brokerID: String) {
        guard let data = try? keys.seal.open(box), let m = try? Wire.decoder.decode(Message.self, from: data) else { return }
        switch m.op {
        case "roster": if let env = m.roster { brokerRoster(env, brokerID: brokerID) }
        case "request": if let env = m.request { add(request: env, brokerID: brokerID) }
        case "status": if let id = m.id, let state = m.state { status(id: id, state: state, by: m.by, note: m.note, brokerID: brokerID) }
        case "enrolling": if let env = m.enroll { enrolling(env, brokerID: brokerID) }
        default: break
        }
    }

    /// A roster from the broker. One older than a change this owner made
    /// means the change didn't arrive (no channel was up, a box expired):
    /// it goes again, and stays pending until the broker has it.
    func brokerRoster(_ env: Envelope, brokerID: String) {
        if var b = broker(brokerID), let pending = b.pendingRoster, let mine = try? pending.peek(Roster.self),
           let theirs = try? env.peek(Roster.self) {
            if theirs.seq < mine.seq {
                send(["op": "roster", "roster": json(pending)], to: brokerID)
                return
            }
            b.pendingRoster = nil // delivered, or another owner's is newer
            upsert(b)
        }
        _ = try? accept(roster: env, brokerID: brokerID)
    }

    /// A change this owner made that the broker hasn't confirmed yet.
    public func isUndelivered(_ brokerID: String) -> Bool { broker(brokerID)?.pendingRoster != nil }

    @discardableResult
    func accept(roster env: Envelope, brokerID: String) throws -> Roster {
        guard var b = broker(brokerID) else { throw WireError.roster("unknown broker") }
        let current = b.decodedRoster
        if current == nil, let hint = b.ownerHint, env.k != hint { throw WireError.roster("first roster from another owner") }
        let roster = try Roster.accept(env, current: current)
        if current == nil, let min = b.minSeq, roster.seq < min { throw WireError.roster("older than the invite") }
        guard roster.broker == b.broker else { throw WireError.roster("another broker") }
        b.roster = env
        // The roster says where the relay is, also when it says there's none.
        b.relay = roster.relay
        upsert(b)
        // Requests from targets that left, enrollments that were admitted.
        requests.removeAll { $0.brokerID == brokerID && roster.target($0.ask.target) == nil }
        enrollments.removeAll { $0.brokerID == brokerID && roster.approver($0.approver.id) != nil }
        return roster
    }

    func add(request env: Envelope, brokerID: String) {
        guard let roster = roster(brokerID), let verified = try? VerifiedRequest(env, roster: roster, now: now()),
              !requests.contains(where: { $0.id == verified.id }), !history.contains(where: { $0.id == verified.id }) else { return }
        let r = OpenRequest(brokerID: brokerID, verified: verified, received: Date())
        requests.append(r)
        onRequest?(r)
    }

    func status(id: String, state: String, by: String?, note: String?, brokerID: String? = nil) {
        guard let i = requests.firstIndex(where: { $0.id == id && (brokerID == nil || $0.brokerID == brokerID) }) else { return }
        requests[i].state = state
        requests[i].by = by ?? requests[i].by
        requests[i].note = note
        if state == "approved", Kind.isTyping(requests[i].ask.kind) { return } // the screen steps follow
        let r = requests.remove(at: i)
        history.insert(r, at: 0)
        if history.count > 30 { history.removeLast() }
        onStatus?(r)
    }

    /// An enrollment is offered only when its MAC checks out under a token
    /// this owner issued for this broker: the broker (or the relay) can't
    /// slip in a device of its own, they never see the token.
    func enrolling(_ env: Envelope, brokerID: String) {
        guard isOwner(brokerID), let peek = try? env.peek(Enroll.self),
              let e = try? env.open(Enroll.self, type: "enroll", key: peek.approver.presence.data),
              e.approver.id == Wire.kid(e.approver.presence.data),
              let invite = invites[e.pairing.data], invite.broker == brokerID, invite.expires > now(),
              e.matches(token: invite.token),
              roster(brokerID)?.approver(e.approver.id) == nil,
              !enrollments.contains(where: { $0.id == e.approver.id }) else { return }
        invites[e.pairing.data] = nil // one device per invite
        enrollments.append(Enrollment(brokerID: brokerID, approver: e.approver))
    }

    /// Drops requests whose time ran out.
    public func expire() {
        let t = now()
        for r in requests where r.ask.expires <= t { status(id: r.id, state: "expired", by: nil, note: nil) }
    }

    // MARK: Outgoing

    private func send(_ message: [String: Any], to brokerID: String) {
        guard let b = broker(brokerID), let data = try? JSONSerialization.data(withJSONObject: message),
              let box = try? Box.seal(data, to: b.broker.seal.data) else { return }
        transport?.send(box: box, to: b)
    }

    private func json(_ env: Envelope) -> Any { (try? JSONSerialization.jsonObject(with: Wire.encoder.encode(env))) ?? [:] }

    /// Approves with the presence key (bound to an evaluated context).
    public func approve(_ r: OpenRequest, grant: Bool, secret: String?, presence: EnvelopeSigner) throws {
        let env = try r.verified.decide(DecisionValue.approve, grant: grant, secret: secret, approver: keys.id,
                                        signer: presence, now: now())
        send(["op": "decision", "decision": json(env)], to: r.brokerID)
    }

    /// Denies with the transport key (no biometrics needed to say no).
    public func deny(_ r: OpenRequest) throws {
        let env = try r.verified.decide(DecisionValue.deny, approver: keys.id, signer: keys.transport, now: now())
        send(["op": "decision", "decision": json(env)], to: r.brokerID)
    }

    /// Asks for the roster and the open requests, and passes on this
    /// owner's open pairings again (the broker takes each once).
    public func sync(_ brokerID: String) {
        send(["op": "sync"], to: brokerID)
        for invite in invites.values where invite.broker == brokerID && invite.expires > now() {
            send(["op": "pairing", "pairing": json(invite.pairing)], to: brokerID)
        }
    }

    /// Asks the target to unlock its screen: it raises an unlock ask naming
    /// this approver, which then needs an approval (Touch ID / Face ID).
    public func unlock(_ brokerID: String, target: String) throws {
        let request = try Envelope.sign(UnlockRequest(broker: brokerID, target: target, approver: keys.id, issued: now()),
                                        type: "unlock", with: keys.transport)
        send(["op": "unlock", "unlock": json(request)], to: brokerID)
    }

    /// The name of the approver who asked for an unlock (nil otherwise).
    public func requester(of r: OpenRequest) -> String? {
        guard let id = r.ask.requestedBy else { return nil }
        if id == keys.id { return "you" }
        return roster(r.brokerID)?.approver(id)?.name ?? "an approver no longer listed"
    }

    // MARK: Owners

    /// A first roster that makes this approver the owner, for the JetKVM's
    /// setApprovalsEnabled.
    public func genesis(broker: BrokerInfo, name: String, direct: String?, relay: String?,
                        presence: EnvelopeSigner) throws -> Envelope {
        let roster = Roster(seq: 1, issued: now(), broker: broker, relay: relay, owners: [keys.id],
                            approvers: [me], targets: [])
        let env = try Envelope.sign(roster, type: "roster", with: presence)
        upsert(PairedBroker(broker: broker, name: name, relay: relay, direct: direct, ownerHint: keys.id, roster: env))
        return env
    }

    /// Signs the next roster after `change` and sends it.
    @discardableResult
    public func update(_ brokerID: String, presence: EnvelopeSigner, change: (inout Roster) -> Void) throws -> Envelope {
        guard var roster = roster(brokerID), roster.isOwner(keys.id) else { throw WireError.roster("not an owner") }
        change(&roster)
        roster.seq += 1
        roster.issued = now()
        let env = try Envelope.sign(roster, type: "roster", with: presence)
        try accept(roster: env, brokerID: brokerID)
        if var b = broker(brokerID) {
            b.pendingRoster = env
            upsert(b)
        }
        send(["op": "roster", "roster": json(env)], to: brokerID)
        return env
    }

    /// Issues a one-time pairing token and returns the invite to show.
    public func invite(_ brokerID: String, presence: EnvelopeSigner) throws -> PairingInvite {
        guard let b = broker(brokerID), isOwner(brokerID) else { throw WireError.roster("not an owner") }
        let token = Wire.randomBytes(32)
        let expires = now() + 300
        let pairing = try Envelope.sign(Pairing(token: token, expires: expires), type: "pairing", with: presence)
        invites = invites.filter { $0.value.expires > now() }
        invites[Pairing.hash(token)] = (token, brokerID, expires, pairing)
        send(["op": "pairing", "pairing": json(pairing)], to: brokerID)
        return PairingInvite(broker: b.broker, name: b.name, relay: b.relay, direct: b.direct, token: token, owner: keys.id,
                             seq: b.decodedRoster?.seq)
    }

    /// Admits an enrolled device; `owner` also makes it an owner.
    public func admit(_ e: Enrollment, owner: Bool, presence: EnvelopeSigner) throws {
        try update(e.brokerID, presence: presence) { roster in
            roster.approvers.append(e.approver)
            if owner { roster.owners.append(e.approver.id) }
        }
        enrollments.removeAll { $0.id == e.id }
    }

    public func decline(_ e: Enrollment) { enrollments.removeAll { $0.id == e.id } }

    /// Forgets an invite that wasn't used (the pairing sheet closed): its
    /// QR code can't enroll anyone any more.
    public func withdraw(_ invite: PairingInvite) {
        invites[Pairing.hash(invite.token.data)] = nil
    }

    /// Removes an approver (and its ownership).
    public func revoke(_ approverID: String, brokerID: String, presence: EnvelopeSigner) throws {
        try update(brokerID, presence: presence) { roster in
            roster.approvers.removeAll { $0.id == approverID }
            roster.owners.removeAll { $0 == approverID }
        }
    }

    // MARK: Joining

    /// Pairs with an invite: remembers the broker and returns the
    /// enrollment box to send (relay `enroll` endpoint, or a direct socket).
    public func join(_ invite: PairingInvite) throws -> Data {
        let enroll = try Envelope.sign(Enroll(token: invite.token.data, approver: me), type: "enroll", with: keys.presence)
        let message = try JSONSerialization.data(withJSONObject: ["op": "enroll", "enroll": json(enroll)])
        let box = try Box.seal(message, to: invite.broker.seal.data)
        if broker(invite.broker.id) == nil {
            upsert(PairedBroker(broker: invite.broker, name: invite.name, relay: invite.relay, direct: invite.direct,
                                ownerHint: invite.owner, roster: nil, minSeq: invite.seq))
        }
        return box
    }
}
