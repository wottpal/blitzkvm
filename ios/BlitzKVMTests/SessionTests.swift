import ApprovalKit
import XCTest
@testable import BlitzKVM

/// The session without the network: pairing state from an invite and a
/// roster, pushed requests, the review of a real OpenRequest, removal.
@MainActor
final class SessionTests: XCTestCase {
    func pairedSession(_ f: Fixture) throws -> ApproverSession {
        let session = ApproverSession(keys: f.phone, store: MemoryBlobStore(), name: "iPhone", file: nil)
        let invite = try XCTUnwrap(PairingCode.invite(from: try f.inviteCode()))
        _ = try session.center.join(invite)
        XCTAssertFalse(session.isAdmitted(f.brokerID))
        session.center.receive(box: try f.rosterBox(), from: f.brokerID)
        XCTAssertTrue(session.isAdmitted(f.brokerID))
        return session
    }

    func testPushedRequestReachesTheReview() throws {
        let f = try Fixture()
        let session = try pairedSession(f)
        let ask = f.ask(grantable: true)
        let id = session.receive(push: f.userInfo(box: try f.requestBox(ask)))
        XCTAssertEqual(id, ask.id)
        let r = try XCTUnwrap(session.center.requests.first)
        XCTAssertEqual(r.id, ask.id)
        let c = ReviewContent(r, broker: session.center.broker(r.brokerID), secretStored: false)
        XCTAssertEqual(c.targetName, "Mac mini")
        XCTAssertEqual(c.brokerName, "Desk JetKVM")
        XCTAssertEqual(c.code, r.verified.code)
        XCTAssertTrue(c.canGrant)

        // The same push again (the outbox repeats it): still one request.
        session.receive(push: f.userInfo(box: try f.requestBox(ask)))
        XCTAssertEqual(session.center.requests.count, 1)
    }

    func testNotificationRequestKeyWins() throws {
        let f = try Fixture()
        let session = try pairedSession(f)
        var info = f.userInfo(box: nil)
        info[AppConfig.requestKey] = "0123456789abcdef0123456789abcdef"
        XCTAssertEqual(session.receive(push: info), "0123456789abcdef0123456789abcdef")
    }

    func testTargetsAndApproverNames() throws {
        let f = try Fixture()
        let session = try pairedSession(f)
        XCTAssertEqual(session.targets.map(\.target.name), ["Mac mini"])
        XCTAssertEqual(session.approverName(f.owner.id, brokerID: f.brokerID), "Studio Mac")
        XCTAssertEqual(session.approverName(f.phone.id, brokerID: f.brokerID), "this iPhone")
        XCTAssertNil(session.approverName(nil, brokerID: f.brokerID))
    }

    func testRemovingAJetKVMForgetsItsPasswords() throws {
        let f = try Fixture()
        let session = try pairedSession(f)
        let target = f.targetKey.id
        try session.vault.store("pässwörd", target: target, kind: SecretKind.mac)
        XCTAssertTrue(session.hasPassword(target: target, kind: SecretKind.mac))
        session.remove(try XCTUnwrap(session.center.broker(f.brokerID)))
        XCTAssertTrue(session.center.brokers.isEmpty)
        XCTAssertFalse(session.hasPassword(target: target, kind: SecretKind.mac))
    }

    func testPairingWithoutRelayFailsBeforeJoining() async throws {
        let f = try Fixture()
        let session = ApproverSession(keys: f.phone, store: MemoryBlobStore(), name: "iPhone", file: nil)
        var invite = try XCTUnwrap(PairingCode.invite(from: try f.inviteCode()))
        invite.relay = nil
        session.pair(invite, name: "iPhone")
        for _ in 0..<50 where session.pairing == .idle { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(session.pairing, .failed(ApproverSession.noRelayMessage("Desk JetKVM")))
        XCTAssertTrue(session.center.brokers.isEmpty, "nothing is remembered")
    }
}
