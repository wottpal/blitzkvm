import CryptoKit
import XCTest
@testable import ApprovalKit

/// approval/testdata/vectors.json: what the Go implementation made must
/// check out here, so Swift and Go speak the same protocol.
final class VectorTests: XCTestCase {
    struct Key: Decodable { let scalar: B64Data; let `public`: B64Data; let id: String }
    struct EnvelopeVector: Decodable {
        let env: Envelope
        let signedMessageHex: String
        let digest: String
        let derSignatureHex: String
        let signer: String
        let tampered: Envelope
    }
    struct BoxVector: Decodable { let recipient: String; let plaintext: String; let box: B64Data }
    struct SecretVector: Decodable { let recipient: String; let requestDigest: String; let plaintext: String; let box: B64Data }
    struct EnrollVector: Decodable { let token: B64Data; let approver: Approver; let pairing: B64Data; let mac: B64Data }
    struct Vectors: Decodable {
        let now: Int64
        let keys: [String: Key]
        let envelope: EnvelopeVector
        let box: BoxVector
        let secret: SecretVector
        let roster: Envelope
        let roster2: Envelope
        let request: Envelope
        let code: String
        let approve: Envelope
        let deny: Envelope
        let approveSignedByTransport: Envelope
        let relayAuth: Envelope
        let unlock: Envelope
        let enroll: EnrollVector
    }

    static let vectors: Vectors = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../approval/testdata/vectors.json").standardized
        return try! JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }()

    var v: Vectors { Self.vectors }
    func pub(_ name: String) -> Data { v.keys[name]!.public.data }

    func testKeyIDs() {
        for (name, key) in v.keys { XCTAssertEqual(Wire.kid(key.public.data), key.id, name) }
    }

    func testEnvelope() throws {
        let e = v.envelope
        try e.env.verify(type: "ask", key: pub(e.signer))
        XCTAssertEqual(Wire.hex(e.env.signedMessage), e.signedMessageHex)
        XCTAssertEqual(e.env.digestHex, e.digest)
        let der = try P256.Signing.ECDSASignature(derRepresentation: Data(hex: e.derSignatureHex)!)
        XCTAssertEqual(der.rawRepresentation, e.env.s.data)
        XCTAssertThrowsError(try e.tampered.verify(type: "ask", key: pub(e.signer)))
        XCTAssertThrowsError(try e.env.verify(type: "roster", key: pub(e.signer)))
    }

    func testBoxes() throws {
        let seal = SealKey(try P256.KeyAgreement.PrivateKey(rawRepresentation: v.keys[v.box.recipient]!.scalar.data))
        XCTAssertEqual(String(decoding: try seal.open(v.box.box.data), as: UTF8.self), v.box.plaintext)
        let reqSeal = SealKey(try P256.KeyAgreement.PrivateKey(rawRepresentation: v.keys[v.secret.recipient]!.scalar.data))
        let digest = Data(hex: v.secret.requestDigest)!
        let padded = try reqSeal.openSecret(v.secret.box.data, requestDigest: digest)
        XCTAssertEqual(padded.count % SecretPadding.block, 0)
        XCTAssertEqual(String(decoding: SecretPadding.unpad(padded), as: UTF8.self), v.secret.plaintext)
        XCTAssertThrowsError(try reqSeal.openSecret(v.secret.box.data, requestDigest: Data(repeating: 0, count: 32)))
        // And the other way: what Swift seals, Swift (and Go, see the Go test) opens.
        let box = try Box.seal(Data("hi".utf8), to: seal.publicKey)
        XCTAssertEqual(try seal.open(box), Data("hi".utf8))
    }

    func testRosterRequestDecision() throws {
        let roster = try Roster.accept(v.roster, current: nil)
        let roster2 = try Roster.accept(v.roster2, current: roster)
        XCTAssertEqual(roster2.seq, 2)
        XCTAssertThrowsError(try Roster.accept(v.roster, current: roster2))
        let req = try VerifiedRequest(v.request, roster: roster, now: v.now)
        XCTAssertEqual(req.code, v.code)
        XCTAssertEqual(req.ask.kind, Kind.onePassword)
        XCTAssertEqual(try req.verify(decision: v.approve, roster: roster, now: v.now).decision, DecisionValue.approve)
        XCTAssertEqual(try req.verify(decision: v.deny, roster: roster, now: v.now).decision, DecisionValue.deny)
        XCTAssertThrowsError(try req.verify(decision: v.approveSignedByTransport, roster: roster, now: v.now))
        XCTAssertThrowsError(try req.verify(decision: v.approve, roster: roster, now: v.now + 61)) // stale
        try v.relayAuth.verify(type: "relay", key: pub("phoneTransport"))
    }

    func testUnlockRequest() throws {
        let roster = try Roster.accept(v.roster, current: nil)
        let target = v.keys["target"]!.id
        XCTAssertEqual(try UnlockRequest.verify(v.unlock, roster: roster, target: target, now: v.now).approver,
                       v.keys["phonePresence"]!.id)
        XCTAssertThrowsError(try UnlockRequest.verify(v.unlock, roster: roster, target: "0123456789abcdef01234567", now: v.now))
        XCTAssertThrowsError(try UnlockRequest.verify(v.unlock, roster: roster, target: target, now: v.now + 61))
    }

    func testEnrollMAC() {
        let e = v.enroll
        XCTAssertEqual(Pairing.hash(e.token.data), e.pairing.data)
        XCTAssertEqual(Enroll.mac(token: e.token.data, approver: e.approver), e.mac.data)
        var enroll = Enroll(token: e.token.data, approver: e.approver)
        XCTAssertTrue(enroll.matches(token: e.token.data))
        XCTAssertFalse(enroll.matches(token: Data(repeating: 7, count: 32)))
        enroll.approver.name = "Someone else"
        XCTAssertFalse(enroll.matches(token: e.token.data), "the name is bound too")
    }

    func testSwiftDecisionVerifies() throws {
        let roster = try Roster.accept(v.roster, current: nil)
        let req = try VerifiedRequest(v.request, roster: roster, now: v.now)
        let presence = SoftwareSigner(try P256.Signing.PrivateKey(rawRepresentation: v.keys["phonePresence"]!.scalar.data))
        let env = try req.decide(DecisionValue.approve, secret: "pw", approver: presence.id, signer: presence, now: v.now)
        let d = try req.verify(decision: env, roster: roster, now: v.now)
        let reqSeal = SealKey(try P256.KeyAgreement.PrivateKey(rawRepresentation: v.keys["requestSeal"]!.scalar.data))
        XCTAssertEqual(SecretPadding.unpad(try reqSeal.openSecret(d.secret!.data, requestDigest: req.requestDigest)), Data("pw".utf8))
        if let out = ProcessInfo.processInfo.environment["APPROVALKIT_INTEROP_OUT"] {
            // Hands Swift-made data to the Go test (approval/wire, interop_test.go).
            let seal = SealKey(try P256.KeyAgreement.PrivateKey(rawRepresentation: v.keys["phoneSeal"]!.scalar.data))
            let box = try Box.seal(Data("from swift".utf8), to: seal.publicKey)
            let json = try JSONSerialization.data(withJSONObject: ["decision": String(decoding: Wire.encoder.encode(env), as: UTF8.self),
                                                                   "box": B64.encode(box)])
            try json.write(to: URL(fileURLWithPath: out))
        }
    }

    func testB64IsStrict() {
        XCTAssertNil(B64.decode("AAE="))
        XCTAssertNil(B64.decode("+/8"))
        XCTAssertEqual(B64.decode("AAE"), Data([0, 1]))
        XCTAssertEqual(B64.encode(Data([0xfb, 0xff])), "-_8")
    }
}
