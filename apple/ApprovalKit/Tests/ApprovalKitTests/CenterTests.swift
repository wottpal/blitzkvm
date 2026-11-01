import CryptoKit
import XCTest
@testable import ApprovalKit

/// The approver's state machine, against a broker played by the test.
@MainActor
final class CenterTests: XCTestCase {
    final class Recorder: CenterTransport {
        var sent: [(Data, String)] = []
        func send(box: Data, to broker: PairedBroker) { sent.append((box, broker.id)) }
    }

    let brokerKey = SoftwareSigner(), brokerSeal = SealKey(), target = SoftwareSigner()
    var brokerInfo: BrokerInfo { BrokerInfo(id: brokerKey.id, key: B64Data(brokerKey.publicKey), seal: B64Data(brokerSeal.publicKey)) }

    func keys() -> ApproverKeys {
        ApproverKeys(presence: SoftwareSigner(), transport: SoftwareSigner(), seal: SealKey(), hardwareBacked: false)
    }

    /// Opens what the center sent to the broker.
    func opened(_ r: Recorder) throws -> [String: Any] {
        let data = try brokerSeal.open(r.sent.removeLast().0)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func envelope(_ any: Any?) throws -> Envelope {
        try Wire.decoder.decode(Envelope.self, from: JSONSerialization.data(withJSONObject: any!))
    }

    func box(_ message: [String: Any], to keys: ApproverKeys) throws -> Data {
        try Box.seal(JSONSerialization.data(withJSONObject: message), to: keys.seal.publicKey)
    }

    func testOwnerPairsAPhoneAndBothApprove() throws {
        let macKeys = keys(), phoneKeys = keys()
        let mac = ApprovalCenter(keys: macKeys, name: "Mac", platform: "macos", file: nil)
        let macOut = Recorder()
        mac.transport = macOut
        let genesis = try mac.genesis(broker: brokerInfo, name: "Mac mini", direct: "http://192.168.1.40", relay: nil,
                                      presence: macKeys.presence)
        XCTAssertNoThrow(try Roster.accept(genesis, current: nil))
        XCTAssertTrue(mac.isOwner(brokerKey.id))

        // The owner adds the target (after installing it).
        try mac.update(brokerKey.id, presence: macKeys.presence) { $0.targets.append(Target(name: "Mac mini", key: self.target.publicKey)) }
        XCTAssertEqual(try opened(macOut)["op"] as? String, "roster")

        // Pairing: invite, the phone joins, the broker tells the owner.
        let invite = try mac.invite(brokerKey.id, presence: macKeys.presence)
        XCTAssertEqual(try opened(macOut)["op"] as? String, "pairing")
        let qr = PairingInvite(qrString: invite.qrString)
        XCTAssertNotNil(qr)
        let phone = ApprovalCenter(keys: phoneKeys, name: "iPhone", platform: "ios", file: nil)
        let phoneOut = Recorder()
        phone.transport = phoneOut
        let enrollBox = try phone.join(qr!)
        let enrollMsg = try JSONSerialization.jsonObject(with: brokerSeal.open(enrollBox)) as! [String: Any]
        // A broker that saw the pairing (its hash) offers a device of its own:
        // without the token its MAC fails, and the owner never sees it.
        let evil = SoftwareSigner()
        let evilApprover = Approver(name: "iPhone", platform: "ios", presence: evil.publicKey, transport: evil.publicKey,
                                    seal: SealKey().publicKey)
        var forgedEnroll = Enroll(token: Data(repeating: 9, count: 32), approver: evilApprover)
        forgedEnroll.pairing = try Wire.decoder.decode(Envelope.self, from: JSONSerialization.data(withJSONObject: enrollMsg["enroll"]!))
            .peek(Enroll.self).pairing
        let forgedEnrollEnv = try Envelope.sign(forgedEnroll, type: "enroll", with: evil)
        mac.receive(box: try box(["op": "enrolling", "enroll": try JSONSerialization.jsonObject(with: Wire.encoder.encode(forgedEnrollEnv))],
                                 to: macKeys), from: brokerKey.id)
        XCTAssertTrue(mac.enrollments.isEmpty, "a forged enrollment reached the owner")
        mac.receive(box: try box(["op": "enrolling", "enroll": enrollMsg["enroll"]!], to: macKeys), from: brokerKey.id)
        XCTAssertEqual(mac.enrollments.first?.approver.name, "iPhone")
        try mac.admit(mac.enrollments[0], owner: true, presence: macKeys.presence)
        let rosterMsg = try opened(macOut)
        XCTAssertTrue(mac.enrollments.isEmpty)

        // The phone takes the roster only from the owner who invited it.
        let stranger = SoftwareSigner()
        var forged = try Roster.accept(try envelope(rosterMsg["roster"]), current: nil)
        forged.approvers.append(Approver(name: "x", platform: "ios", presence: stranger.publicKey,
                                         transport: stranger.publicKey, seal: SealKey().publicKey))
        forged.owners = [stranger.id]
        let forgedEnv = try Envelope.sign(forged, type: "roster", with: stranger)
        phone.receive(box: try box(["op": "roster", "roster": try JSONSerialization.jsonObject(with: Wire.encoder.encode(forgedEnv))], to: phoneKeys), from: brokerKey.id)
        XCTAssertNil(phone.roster(brokerKey.id))
        phone.receive(box: try box(["op": "roster", "roster": rosterMsg["roster"]!], to: phoneKeys), from: brokerKey.id)
        XCTAssertEqual(phone.roster(brokerKey.id)?.owners.count, 2)

        // A request reaches the phone; it approves with a grant.
        let roster = phone.roster(brokerKey.id)!
        let now = Int64(Date().timeIntervalSince1970)
        let ask = try Envelope.sign(Ask(target: target.id, kind: Kind.sudo, title: "sudo true", grantable: true, issued: now),
                                    type: "ask", with: target)
        let reqSeal = SealKey()
        let req = try Envelope.sign(Request(ask: ask, seal: B64Data(reqSeal.publicKey), issued: now, expires: now + 60),
                                    type: "request", with: brokerKey)
        var seen: OpenRequest?
        phone.onRequest = { seen = $0 }
        let reqJSON = try JSONSerialization.jsonObject(with: Wire.encoder.encode(req))
        phone.receive(box: try box(["op": "request", "request": reqJSON], to: phoneKeys), from: brokerKey.id)
        phone.receive(box: try box(["op": "request", "request": reqJSON], to: phoneKeys), from: brokerKey.id) // once
        XCTAssertEqual(phone.requests.count, 1)
        XCTAssertEqual(seen?.verified.code, Wire.code(askDigest: ask.digest))
        try phone.approve(phone.requests[0], grant: true, secret: nil, presence: phoneKeys.presence)
        let decision = try envelope(try opened(phoneOut)["decision"])
        let verified = try VerifiedRequest(req, roster: roster, now: now)
        XCTAssertEqual(try verified.verify(decision: decision, roster: roster, now: now).grant, 10)

        phone.receive(box: try box(["op": "status", "id": verified.id, "state": "done"], to: phoneKeys), from: brokerKey.id)
        XCTAssertTrue(phone.requests.isEmpty)
        XCTAssertEqual(phone.history.first?.state, "done")

        // The owner revokes the phone.
        try mac.revoke(phoneKeys.id, brokerID: brokerKey.id, presence: macKeys.presence)
        XCTAssertNil(mac.roster(brokerKey.id)?.approver(phoneKeys.id))
    }

    func testRequestsFromStrangersAreDropped() throws {
        let k = keys()
        let center = ApprovalCenter(keys: k, name: "Mac", platform: "macos", file: nil)
        _ = try center.genesis(broker: brokerInfo, name: "x", direct: nil, relay: nil, presence: k.presence)
        let now = Int64(Date().timeIntervalSince1970)
        let ask = try Envelope.sign(Ask(target: target.id, kind: Kind.sudo, title: "sudo", issued: now), type: "ask", with: target)
        let req = try Envelope.sign(Request(ask: ask, seal: B64Data(SealKey().publicKey), issued: now, expires: now + 60),
                                    type: "request", with: brokerKey)
        center.receive(box: try box(["op": "request", "request": try JSONSerialization.jsonObject(with: Wire.encoder.encode(req))], to: k),
                       from: brokerKey.id)
        XCTAssertTrue(center.requests.isEmpty, "a target outside the roster")
    }

    func testVaultRoundTrip() throws {
        let vault = SecretVault(store: MemoryBlobStore())
        try vault.store("pässwörd^`", target: "t", kind: SecretKind.mac)
        XCTAssertTrue(vault.has(target: "t", kind: SecretKind.mac))
        if ApproverKeys.hasSecureEnclave { return } // reading would prompt for Touch ID
        XCTAssertEqual(try vault.secret(target: "t", kind: SecretKind.mac, context: nil), "pässwörd^`")
    }

    func testRelayURL() {
        XCTAssertEqual(BoxChannel.relayURL(base: "https://relay.example.workers.dev", broker: "b", approver: "a")?.absoluteString,
                       "wss://relay.example.workers.dev/v1/b/b/approver/a")
        XCTAssertEqual(BoxChannel.directURL(deviceBase: URL(string: "http://192.168.1.40")!)?.absoluteString,
                       "ws://192.168.1.40/approvals/v1/ws")
    }
}
