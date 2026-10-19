import XCTest
@testable import JetKVMCore

/// A device listed as its LAN address first and its tailnet name second.
final class AddressRoamingTests: XCTestCase {
    private let addresses = ["192.168.1.40", "kvm.example.ts.net"]
    private var lan: String { addresses[0] }
    private var tailnet: String { addresses[1] }

    /// The first probe found `current` answering at t = 0.
    private func roaming(at current: String, answered: Bool = true) -> AddressRoaming {
        AddressRoaming(current: current, answered: answered, at: 0)
    }

    func testSessionFromPhase() {
        XCTAssertEqual(AddressRoaming.Session(phase: "connected", path: "lan"), .connected(lanPicture: true))
        XCTAssertEqual(AddressRoaming.Session(phase: "connected", path: "tailscale"), .connected(lanPicture: false))
        XCTAssertEqual(AddressRoaming.Session(phase: "connected", path: nil), .connected(lanPicture: false))
        for phase in ["idle", "connecting", "reconnecting"] {
            XCTAssertEqual(AddressRoaming.Session(phase: phase, path: nil), .connecting, phase)
        }
        XCTAssertEqual(AddressRoaming.Session(phase: "disconnected", path: nil), .waiting)
        for phase in ["other_session", "auth_failed", "fatal_error", "rebooting"] {
            XCTAssertEqual(AddressRoaming.Session(phase: phase, path: nil), .paused, phase)
        }
    }

    func testLeavingHomeMovesToTheTailnet() {
        var r = roaming(at: lan)
        r.connected()
        // Connected through the most preferred address: nothing to probe for.
        XCTAssertFalse(r.probeDue(addresses, session: .connected(lanPicture: true), at: 100))
        // The lid closes at home and opens elsewhere: the session drops.
        r.networkChanged(at: 200)
        XCTAssertFalse(r.probeDue(addresses, session: .connecting, at: 200.2))
        XCTAssertTrue(r.probeDue(addresses, session: .connecting, at: 200.5))
        XCTAssertEqual(r.decide(addresses, answer: nil, session: .connecting, at: 201), .stay) // Tailscale still coming up
        XCTAssertFalse(r.probeDue(addresses, session: .connecting, at: 203.9))
        XCTAssertTrue(r.probeDue(addresses, session: .waiting, at: 204))
        XCTAssertEqual(r.decide(addresses, answer: tailnet, session: .waiting, at: 204.1), .move(to: tailnet))
        r.moved(to: tailnet, at: 204.1)
        XCTAssertEqual(r.current, tailnet)
    }

    func testComingHomeMovesBackToTheLAN() {
        var r = roaming(at: tailnet)
        r.connected()
        let away = AddressRoaming.Session.connected(lanPicture: false)
        XCTAssertFalse(r.probeDue(addresses, session: away, at: 14))
        XCTAssertTrue(r.probeDue(addresses, session: away, at: 15))
        XCTAssertEqual(r.decide(addresses, answer: tailnet, session: away, at: 15), .stay) // still away
        // Home: the Wi-Fi changes and the tailnet session lives on.
        r.networkChanged(at: 20)
        XCTAssertTrue(r.probeDue(addresses, session: away, at: 20.5))
        XCTAssertEqual(r.decide(addresses, answer: nil, session: away, at: 22.5), .stay) // DHCP still running
        // Probing stays quick while the network settles ...
        XCTAssertTrue(r.probeDue(addresses, session: away, at: 25.5))
        XCTAssertEqual(r.decide(addresses, answer: lan, session: away, at: 25.6), .move(to: lan))
        // ... and slows down after it.
        XCTAssertFalse(r.probeDue(addresses, session: away, at: 33))
        XCTAssertTrue(r.probeDue(addresses, session: away, at: 40.6))
    }

    func testAPictureOnTheLANAlreadyStays() {
        // Connected through the tailnet name at home: the direct path found
        // the LAN, so moving would only interrupt the picture.
        var r = roaming(at: tailnet)
        r.connected()
        let home = AddressRoaming.Session.connected(lanPicture: true)
        XCTAssertFalse(r.probeDue(addresses, session: home, at: 100))
        XCTAssertEqual(r.decide(addresses, answer: lan, session: home, at: 100), .stay)
    }

    func testConnectedNeverMovesToALessPreferredAddress() {
        var r = roaming(at: tailnet)
        r.connected()
        let three = [lan, tailnet, "10.8.0.40"]
        XCTAssertEqual(r.decide(three, answer: "10.8.0.40", session: .connected(lanPicture: false), at: 15), .stay)
        XCTAssertEqual(r.decide(three, answer: tailnet, session: .connected(lanPicture: false), at: 30), .stay)
    }

    func testAnAddressAnsweringAgainIsRetriedAtOnceWhileWaiting() {
        var r = roaming(at: lan)
        r.connected()
        // The session dropped, the device restarts.
        XCTAssertEqual(r.decide(addresses, answer: nil, session: .waiting, at: 10), .stay)
        // It answers again while the engine waits out its backoff: retry now ...
        XCTAssertEqual(r.decide(addresses, answer: lan, session: .waiting, at: 13), .reconnect)
        // ... once: a retry that fails gets the engine's backoff again.
        XCTAssertEqual(r.decide(addresses, answer: lan, session: .waiting, at: 16), .stay)
        // A connect attempt that runs as it answers is left be.
        r.connected()
        XCTAssertEqual(r.decide(addresses, answer: lan, session: .connecting, at: 30), .stay)
        XCTAssertEqual(r.decide(addresses, answer: lan, session: .waiting, at: 33), .stay)
    }

    func testAnAddressThatAnswersWithoutASessionGoesLast() {
        // At home the LAN answers HTTP, but no session comes up through it.
        var r = roaming(at: tailnet)
        r.connected()
        XCTAssertEqual(r.decide(addresses, answer: lan, session: .connected(lanPicture: false), at: 15), .move(to: lan))
        r.moved(to: lan, at: 15)
        XCTAssertEqual(r.decide(addresses, answer: lan, session: .connecting, at: 18), .stay)
        XCTAssertEqual(r.decide(addresses, answer: lan, session: .waiting, at: 33), .stay) // the engine retries on its own
        XCTAssertEqual(r.order(addresses, at: 34), addresses)
        XCTAssertEqual(r.decide(addresses, answer: lan, session: .connecting, at: 35), .stay)
        XCTAssertEqual(r.order(addresses, at: 35), [tailnet, lan])
        // Probed again at once, the others first.
        XCTAssertTrue(r.probeDue(addresses, session: .connecting, at: 35))
        XCTAssertEqual(r.decide(addresses, answer: tailnet, session: .connecting, at: 35.1), .move(to: tailnet))
        r.moved(to: tailnet, at: 35.1)
        r.connected()
        // No bouncing back while it is skipped: the tailnet is now first.
        XCTAssertFalse(r.probeDue(addresses, session: .connected(lanPicture: false), at: 600))
        // Until the skip ends ...
        XCTAssertTrue(r.probeDue(addresses, session: .connected(lanPicture: false), at: 35 + 1800))
        // ... or the network changes.
        var changed = r
        changed.networkChanged(at: 700)
        XCTAssertEqual(changed.order(addresses, at: 700), addresses)
        XCTAssertTrue(changed.probeDue(addresses, session: .connected(lanPicture: false), at: 700.5))
    }

    func testOnlyAnUnbrokenAnswerCountsTowardSkipping() {
        // The device was off for a while: it answers again, and its session
        // gets the full time to come up.
        var r = roaming(at: lan)
        XCTAssertEqual(r.decide(addresses, answer: nil, session: .waiting, at: 25), .stay)
        XCTAssertEqual(r.decide(addresses, answer: lan, session: .waiting, at: 28), .reconnect)
        XCTAssertEqual(r.decide(addresses, answer: lan, session: .connecting, at: 40), .stay)
        XCTAssertEqual(r.order(addresses, at: 40), addresses)
        // A session that came up and dropped starts over too.
        r.connected()
        XCTAssertEqual(r.decide(addresses, answer: lan, session: .connecting, at: 60), .stay)
        XCTAssertEqual(r.order(addresses, at: 60), addresses)
    }

    func testASingleAddressIsNeverSkipped() {
        var r = roaming(at: lan)
        let one = [lan]
        XCTAssertFalse(r.probeDue(one, session: .connected(lanPicture: true), at: 100))
        XCTAssertEqual(r.decide(one, answer: lan, session: .waiting, at: 30), .stay)
        XCTAssertEqual(r.order(one, at: 30), one)
        XCTAssertEqual(r.decide(one, answer: nil, session: .waiting, at: 60), .stay)
        XCTAssertEqual(r.decide(one, answer: lan, session: .waiting, at: 63), .reconnect)
        XCTAssertEqual(r.order(one, at: 63), one)
    }

    func testHandsOffWhilePaused() {
        // Another session took over, the login failed, the device reboots:
        // reconnecting would kick the other user or count toward a lockout.
        var r = roaming(at: tailnet)
        XCTAssertFalse(r.probeDue(addresses, session: .paused, at: 100))
        r.networkChanged(at: 200)
        XCTAssertFalse(r.probeDue(addresses, session: .paused, at: 201))
        XCTAssertEqual(r.decide(addresses, answer: lan, session: .paused, at: 201), .stay)
    }

    func testAnAddressRemovedInSettingsIsTheLeastPreferred() {
        var r = roaming(at: "old.example.ts.net")
        r.connected()
        XCTAssertTrue(r.probeDue(addresses, session: .connected(lanPicture: false), at: 15))
        XCTAssertEqual(r.decide(addresses, answer: tailnet, session: .connected(lanPicture: false), at: 15), .move(to: tailnet))
    }

    func testNoAddressesNoProbes() {
        let r = roaming(at: lan, answered: false)
        XCTAssertFalse(r.probeDue([], session: .waiting, at: 100))
    }
}
