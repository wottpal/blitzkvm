import ApprovalKit
import XCTest
@testable import BlitzKVM

/// What the review screen offers for a request.
final class ReviewContentTests: XCTestCase {
    func content(_ f: Fixture, _ ask: Ask, stored: Bool = false) throws -> ReviewContent {
        let roster = try f.rosterEnvelope().peek(Roster.self)
        return ReviewContent(ask: ask, code: "42", roster: roster, brokerName: "Desk JetKVM", secretStored: stored)
    }

    func testGrantOnlyWhenGrantable() throws {
        let f = try Fixture()
        XCTAssertTrue(try content(f, f.ask(grantable: true)).canGrant)
        XCTAssertFalse(try content(f, f.ask(grantable: false)).canGrant)
        XCTAssertFalse(try content(f, f.ask(kind: Kind.securityAgent, secret: SecretKind.mac)).canGrant)
    }

    func testPasswordRowOnlyWhenTheAskTakesOne() throws {
        let f = try Fixture()
        XCTAssertNil(try content(f, f.ask()).secret)
        let mac = try XCTUnwrap(try content(f, f.ask(kind: Kind.securityAgent, secret: SecretKind.mac), stored: true).secret)
        XCTAssertEqual(mac, ReviewContent.SecretNeed(kind: SecretKind.mac, name: "Mac password", stored: true))
        let op = try XCTUnwrap(try content(f, f.ask(kind: Kind.onePassword, secret: SecretKind.onePassword)).secret)
        XCTAssertEqual(op.name, "1Password password")
        XCTAssertFalse(op.stored)
    }

    func testTargetCodeRequesterAndEvidence() throws {
        let f = try Fixture()
        let requester = Requester(uid: 501, user: "alex", tty: "ttys003", chain: [
            ApprovalKit.Process(pid: 4242, name: "sudo", path: "/usr/bin/sudo", args: ["sudo", "shutdown", "-r", "now"], signer: "apple"),
            ApprovalKit.Process(pid: 4100, name: "zsh", path: "/bin/zsh", signer: "developer:ABCDE12345"),
            ApprovalKit.Process(pid: 4000, name: "agent", signer: "unsigned"),
        ])
        let evidence = Evidence(locked: false, secureInput: SecureInput(pid: 7000, bundle: "com.1password.1password", team: "2BUA8C4S2C"),
                                window: Rect(x: 552, y: 219, w: 400, h: 346), display: Size(w: 1504, h: 948))
        let c = try content(f, f.ask(requester: requester, evidence: evidence))
        XCTAssertEqual(c.title, "sudo shutdown -r now")
        XCTAssertEqual(c.detail, "Restart now")
        XCTAssertEqual(c.targetName, "Mac mini")
        XCTAssertEqual(c.code, "42")
        XCTAssertEqual(c.kindName, "sudo")
        XCTAssertEqual(c.requester, "alex (uid 501) · ttys003")
        XCTAssertEqual(c.chain.map(\.name), ["sudo", "zsh", "agent"])
        XCTAssertEqual(c.chain[0].arguments, "sudo shutdown -r now")
        XCTAssertEqual(c.chain.map { $0.signer?.trusted }, [true, true, false])
        XCTAssertEqual(c.chain[1].signer?.label, "Developer ID ABCDE12345")
        XCTAssertEqual(c.evidence.map(\.label), ["Screen", "Secure input", "Dialog"])
        XCTAssertEqual(c.evidence[1].value, "com.1password.1password (2BUA8C4S2C)")
        XCTAssertEqual(c.evidence[2].value, "400 × 346 at 552, 219 of 1504 × 948")
    }

    func testUnknownTargetAndNoRequester() throws {
        let f = try Fixture()
        var ask = f.ask()
        ask.target = SoftwareSigner().id
        let c = try content(f, ask)
        XCTAssertEqual(c.targetName, "Unknown computer")
        XCTAssertNil(c.requester)
        XCTAssertTrue(c.chain.isEmpty)
        XCTAssertTrue(c.evidence.isEmpty)
    }
}
