import CryptoKit
import Foundation
import XCTest
@testable import ApprovalKit
@testable import BlitzKVM

/// A broker, its target and its owner, played by the test with software
/// keys, and this iPhone's software keys. Messages are built through
/// ApprovalKit's public API; only ApproverKeys needs its internal
/// initializer (the Simulator's Secure Enclave refuses keys).
struct Fixture {
    static let relay = "https://relay.example.workers.dev"

    let brokerKey = SoftwareSigner()
    let brokerSeal = SealKey()
    let targetKey = SoftwareSigner()
    let ownerPresence = SoftwareSigner()
    let ownerTransport = SoftwareSigner()
    let ownerSeal = SealKey()
    let phone: ApproverKeys
    let now = Int64(Date().timeIntervalSince1970)

    init() throws {
        phone = Self.softwareKeys()
    }

    static func softwareKeys() -> ApproverKeys {
        ApproverKeys(presence: SoftwareSigner(), transport: SoftwareSigner(), seal: SealKey(), hardwareBacked: false)
    }

    var brokerID: String { brokerKey.id }

    var brokerInfo: BrokerInfo {
        BrokerInfo(id: brokerKey.id, key: B64Data(brokerKey.publicKey), seal: B64Data(brokerSeal.publicKey))
    }

    var owner: Approver {
        Approver(name: "Studio Mac", platform: "macos", presence: ownerPresence.publicKey,
                 transport: ownerTransport.publicKey, seal: ownerSeal.publicKey)
    }

    /// The owner's roster with this iPhone admitted and one computer.
    func rosterEnvelope(seq: UInt64 = 2, targetName: String = "Mac mini") throws -> Envelope {
        let roster = Roster(seq: seq, issued: now, broker: brokerInfo, relay: Self.relay, owners: [owner.id],
                            approvers: [owner, phone.approver(name: "iPhone", platform: "ios")],
                            targets: [Target(name: targetName, key: targetKey.publicKey)])
        return try Envelope.sign(roster, type: "roster", with: ownerPresence)
    }

    func pairedBroker() throws -> PairedBroker {
        PairedBroker(broker: brokerInfo, name: "Desk JetKVM", relay: Self.relay, direct: nil, ownerHint: owner.id,
                     roster: try rosterEnvelope())
    }

    /// The owner's pairing code, as its Mac shows it.
    func inviteCode() throws -> String {
        let invite: [String: Any] = [
            "v": 1, "name": "Desk JetKVM", "relay": Self.relay, "owner": owner.id,
            "token": B64.encode(Wire.randomBytes(32)),
            "broker": ["id": brokerKey.id, "key": B64.encode(brokerKey.publicKey), "seal": B64.encode(brokerSeal.publicKey)],
        ]
        return PairingInvite.scheme + B64.encode(try JSONSerialization.data(withJSONObject: invite))
    }

    func ask(kind: String = Kind.sudo, title: String = "sudo shutdown -r now", secret: String = SecretKind.none,
             grantable: Bool = false, requester: Requester? = nil, evidence: Evidence? = nil, lifetime: Int64 = 60) -> Ask {
        Ask(target: targetKey.id, kind: kind, title: title, detail: "Restart now", requester: requester, evidence: evidence,
            secret: secret, grantable: grantable, requestedBy: kind == Kind.unlock ? phone.id : nil, issued: now, lifetime: lifetime)
    }

    func askEnvelope(_ ask: Ask, signer: SoftwareSigner? = nil) throws -> Envelope {
        try Envelope.sign(ask, type: "ask", with: signer ?? targetKey)
    }

    /// The broker's request for an ask (Request has no public initializer:
    /// the payload is written as JSON).
    func requestEnvelope(_ askEnv: Envelope, signer: SoftwareSigner? = nil) throws -> Envelope {
        let ask = try askEnv.peek(Ask.self)
        let payload: [String: Any] = ["v": 1, "ask": try json(askEnv), "seal": B64.encode(SealKey().publicKey),
                                      "issued": ask.issued, "expires": ask.expires]
        return try Envelope.sign(bytes: JSONSerialization.data(withJSONObject: payload), type: "request", with: signer ?? brokerKey)
    }

    func json(_ env: Envelope) throws -> Any { try JSONSerialization.jsonObject(with: Wire.encoder.encode(env)) }

    /// A message sealed to this iPhone, as the broker sends it.
    func box(_ message: [String: Any], to seal: Data? = nil) throws -> Data {
        try Box.seal(JSONSerialization.data(withJSONObject: message), to: seal ?? phone.seal.publicKey)
    }

    func requestBox(_ ask: Ask) throws -> Data {
        try box(["op": "request", "request": try json(try requestEnvelope(try askEnvelope(ask)))])
    }

    func rosterBox() throws -> Data { try box(["op": "roster", "roster": try json(try rosterEnvelope())]) }

    /// The relay's push payload.
    func userInfo(box: Data?, broker: String? = nil) -> [AnyHashable: Any] {
        var bka: [String: Any] = ["b": broker ?? brokerID]
        if let box { bka["x"] = B64.encode(box) }
        return ["aps": ["alert": ["title": "Approval requested", "body": "Open to review"]], "bka": bka]
    }
}
