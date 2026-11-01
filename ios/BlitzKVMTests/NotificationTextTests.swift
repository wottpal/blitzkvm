import ApprovalKit
import XCTest
@testable import BlitzKVM

/// What the notification service extension shows for a push.
final class NotificationTextTests: XCTestCase {
    func text(_ f: Fixture, _ userInfo: [AnyHashable: Any], brokers: [PairedBroker]? = nil, now: Int64? = nil) throws -> NotificationText? {
        let push = try XCTUnwrap(ApprovalPush(userInfo: userInfo))
        return PushedMessage(push, seal: f.phone.seal, brokers: try brokers ?? [f.pairedBroker()], now: now ?? f.now)
            .map(NotificationText.init)
    }

    func testRequestShowsTargetTitleAndCode() throws {
        let f = try Fixture()
        let ask = f.ask()
        let askEnv = try f.askEnvelope(ask)
        let box = try f.box(["op": "request", "request": try f.json(try f.requestEnvelope(askEnv))])
        let text = try XCTUnwrap(try text(f, f.userInfo(box: box)))
        XCTAssertEqual(text.title, "Mac mini: sudo shutdown -r now")
        XCTAssertEqual(text.body, "Code \(Wire.code(askDigest: askEnv.digest)) · sudo")
        XCTAssertEqual(text.thread, f.brokerID)
        XCTAssertEqual(text.requestID, ask.id)
        XCTAssertEqual(text.body.count, "Code 00 · sudo".count, "two-digit code")
    }

    func testKindNames() throws {
        let f = try Fixture()
        let cases = [(Kind.onePassword, "1Password"), (Kind.securityAgent, "Password dialog"), (Kind.unlock, "Unlock screen"),
                     (Kind.confirm, "Confirmation")]
        for (kind, name) in cases {
            let secret = Kind.isTyping(kind) ? SecretKind.mac : SecretKind.none
            let text = try XCTUnwrap(try text(f, f.userInfo(box: try f.requestBox(f.ask(kind: kind, title: "x", secret: secret)))))
            XCTAssertTrue(text.body.hasSuffix(" · \(name)"), text.body)
        }
    }

    func testAnythingThatDoesNotCheckOutKeepsTheGenericText() throws {
        let f = try Fixture()
        let ask = f.ask()
        // No box in the push (it didn't fit).
        XCTAssertNil(try text(f, f.userInfo(box: nil)))
        // A broker this iPhone isn't paired with.
        XCTAssertNil(try text(f, f.userInfo(box: try f.requestBox(ask), broker: SoftwareSigner().id)))
        // Paired, but not admitted yet (no roster).
        var unadmitted = try f.pairedBroker()
        unadmitted.roster = nil
        XCTAssertNil(try text(f, f.userInfo(box: try f.requestBox(ask)), brokers: [unadmitted]))
        // Sealed to someone else.
        let other = try f.box(["op": "request", "request": try f.json(try f.requestEnvelope(try f.askEnvelope(ask)))],
                              to: SealKey().publicKey)
        XCTAssertNil(try text(f, f.userInfo(box: other)))
        // Signed by another broker key, or another target key.
        let forgedBroker = try f.box(["op": "request", "request": try f.json(try f.requestEnvelope(try f.askEnvelope(ask), signer: SoftwareSigner()))])
        XCTAssertNil(try text(f, f.userInfo(box: forgedBroker)))
        let forgedTarget = try f.box(["op": "request", "request": try f.json(try f.requestEnvelope(try f.askEnvelope(ask, signer: SoftwareSigner())))])
        XCTAssertNil(try text(f, f.userInfo(box: forgedTarget)))
        // Expired by the time it arrives.
        XCTAssertNil(try text(f, f.userInfo(box: try f.requestBox(ask)), now: ask.expires))
        // Not a request (a status update).
        XCTAssertNil(try text(f, f.userInfo(box: try f.box(["op": "status", "id": ask.id, "state": "done"]))))
        // The genuine one still works.
        XCTAssertNotNil(try text(f, f.userInfo(box: try f.requestBox(ask))))
    }

    func testEnrollingNamesTheDevice() throws {
        let f = try Fixture()
        let newcomer = Fixture.softwareKeys()
        let enroll = try Envelope.sign(Enroll(token: Wire.randomBytes(32), approver: newcomer.approver(name: "Anna's iPhone", platform: "ios")),
                                       type: "enroll", with: newcomer.presence)
        let text = try XCTUnwrap(try text(f, f.userInfo(box: try f.box(["op": "enrolling", "enroll": try f.json(enroll)]))))
        XCTAssertEqual(text.title, "Desk JetKVM")
        XCTAssertEqual(text.body, "“Anna's iPhone” asks to pair. Open to review.")
        XCTAssertNil(text.requestID)
    }

    func testPushParsing() {
        XCTAssertNil(ApprovalPush(userInfo: [:]))
        XCTAssertNil(ApprovalPush(userInfo: ["bka": ["x": "AAAA"]]))
        XCTAssertNil(ApprovalPush(userInfo: ["bka": ["b": ""]]))
        XCTAssertEqual(ApprovalPush(userInfo: ["bka": ["b": "abc"]])?.box, nil)
        XCTAssertEqual(ApprovalPush(userInfo: ["bka": ["b": "abc", "x": "AQID"]])?.box, Data([1, 2, 3]))
        XCTAssertNil(ApprovalPush(userInfo: ["bka": ["b": "abc", "x": "AQ=="]])?.box, "padded base64 is refused")
    }
}
