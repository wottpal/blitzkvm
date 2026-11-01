import ApprovalKit
import XCTest
@testable import BlitzKVM

final class PairingCodeTests: XCTestCase {
    func testFindsTheCodeInWhatWasScannedOrPasted() throws {
        let f = try Fixture()
        let code = try f.inviteCode()
        let invite = try XCTUnwrap(PairingCode.invite(from: code))
        XCTAssertEqual(invite.broker.id, f.brokerID)
        XCTAssertEqual(invite.name, "Desk JetKVM")
        XCTAssertEqual(invite.relay, Fixture.relay)
        XCTAssertEqual(invite.owner, f.owner.id)
        XCTAssertNotNil(PairingCode.invite(from: "  Pair with this:\n\(code)\n"))
        XCTAssertNotNil(PairingCode.invite(from: code.replacingOccurrences(of: "blitzkvm-pair:", with: "blitzkvm-pair://")))
        XCTAssertNotNil(PairingCode.invite(from: code.replacingOccurrences(of: "blitzkvm-pair:", with: "BLITZKVM-PAIR:")))
    }

    func testRefusesAnythingElse() throws {
        let f = try Fixture()
        XCTAssertNil(PairingCode.invite(from: ""))
        XCTAssertNil(PairingCode.invite(from: "https://example.com"))
        XCTAssertNil(PairingCode.invite(from: "blitzkvm-pair:"))
        XCTAssertNil(PairingCode.invite(from: String(try f.inviteCode().dropLast(6))))
        // A broker id that isn't its key's id.
        let invite: [String: Any] = [
            "v": 1, "name": "x", "owner": f.owner.id, "token": B64.encode(Wire.randomBytes(32)),
            "broker": ["id": SoftwareSigner().id, "key": B64.encode(f.brokerKey.publicKey), "seal": B64.encode(f.brokerSeal.publicKey)],
        ]
        XCTAssertNil(PairingCode.invite(from: PairingInvite.scheme + B64.encode(try JSONSerialization.data(withJSONObject: invite))))
    }

    func testFormat() {
        XCTAssertEqual(Format.grouped("0123456789abcdef01234567"), "0123 4567 89ab cdef 0123 4567")
        XCTAssertEqual(Format.grouped("abcdef"), "abcd ef")
        XCTAssertEqual(Format.timeLeft(42), "0:42")
        XCTAssertEqual(Format.timeLeft(90), "1:30")
        XCTAssertEqual(Format.host("https://relay.example.workers.dev/"), "relay.example.workers.dev")
        XCTAssertNil(Format.host(nil))
    }

    func testRelayErrors() {
        XCTAssertEqual(ErrorText.relayStatus("relay outbox: 403"), 403)
        XCTAssertNil(ErrorText.relayStatus("keychain"))
        XCTAssertEqual(ErrorText.describe(WireError.invalid("relay inbox: 403")), ErrorText.describeRelay(403))
    }
}
