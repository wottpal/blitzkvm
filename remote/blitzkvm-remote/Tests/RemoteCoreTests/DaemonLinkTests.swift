import ApprovalKit
import XCTest
@testable import RemoteCore

/// The daemon against a fake broker on localhost: the link handshake, asks
/// and requests, and the daemon's own check of every decision.
final class DaemonLinkTests: XCTestCase {
    var dir: URL!
    var paths: Paths!
    var target: SoftwareSigner!
    var world: World!
    var broker: FakeBroker!
    var daemon: Daemon!

    override func setUpWithError() throws {
        Log.toStderr = false
        dir = makeTempDir()
        paths = Paths(state: dir, socket: dir.appendingPathComponent("s").path)
        let store = TargetStore(paths: paths)
        target = try store.loadOrCreateKey()
        world = World(target: target.publicKey)
        try store.installGenesis(world.roster(seq: 1), targetID: target.id)
        broker = try FakeBroker(world: world, roster: world.roster(seq: 1))
    }

    override func tearDown() {
        daemon?.stop()
        broker?.close()
        try? FileManager.default.removeItem(at: dir)
    }

    func startDaemon(endpoint: HostLink.Endpoint? = nil, processes: ProcessInspector = SystemProcesses(),
                     _ change: (inout Daemon.Config) -> Void = { _ in }) throws {
        var config = Daemon.Config(paths: paths)
        config.userMode = true
        config.endpoint = endpoint ?? .fixed(host: "127.0.0.1", port: broker.port)
        config.processes = processes
        config.console = { ConsoleState(uid: getuid()) }
        change(&config)
        daemon = try Daemon(config: config)
        try daemon.start()
    }

    /// The broker took the auth and the daemon has the `ready`.
    func waitLinked(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(broker.waitReady(), file: file, line: line)
        XCTAssertTrue(eventually { daemon.queue.sync { daemon.link.isReady } }, file: file, line: line)
    }

    func confirm(_ question: String, grant: Bool = false) -> PendingResult {
        PendingResult(socket: paths.socket, LocalMessage(op: "confirm", title: question, grant: grant, timeout: 60))
    }

    func testHandshakeAndApproval() throws {
        try startDaemon()
        waitLinked()
        let pending = confirm("Deploy to staging?")
        let req = try XCTUnwrap(broker.waitRequest(kind: Kind.confirm))
        XCTAssertEqual(req.ask.title, "Deploy to staging?")
        XCTAssertEqual(req.ask.target, target.id)
        XCTAssertEqual(req.ask.requester?.chain.first?.pid, Int(getpid()), "the chain starts at the requester")
        XCTAssertTrue(eventually { pending.infos.contains("BlitzKVM: approve on your iPhone or Mac (code \(req.code))…") },
                      "the requester sees the matching code: \(pending.infos)")
        let env = try req.decide(DecisionValue.approve, approver: world.a.id, signer: world.a.presence, now: now())
        broker.send(LinkMessage.decision(req.id, env))
        let result = try XCTUnwrap(pending.wait())
        XCTAssertEqual(result.outcome, .approved)
        XCTAssertEqual(result.text, "BlitzKVM: approved on Owner's iPhone")
    }

    /// Bad approvals first, then a valid denial: had any of them counted,
    /// the requester would have been approved.
    func testDaemonChecksEveryDecision() throws {
        try startDaemon()
        waitLinked()
        let pending = confirm("Rotate the keys?")
        let req = try XCTUnwrap(broker.waitRequest(kind: Kind.confirm))
        func approve(_ r: VerifiedRequest, by approver: String, with signer: SoftwareSigner, at t: Int64 = now()) throws -> Envelope {
            try r.decide(DecisionValue.approve, approver: approver, signer: signer, now: t)
        }

        // Signed by a key that isn't the approver's.
        broker.send(LinkMessage.decision(req.id, try approve(req, by: world.a.id, with: SoftwareSigner())))
        // An approval signed with the transport key (presence only).
        broker.send(LinkMessage.decision(req.id, try approve(req, by: world.a.id, with: world.a.transport)))
        // A decision for another request, sent under this one's id.
        let otherAsk = Ask(target: target.id, kind: Kind.confirm, title: "Something else", issued: now())
        let otherAskEnv = try Envelope.sign(otherAsk, type: "ask", with: target)
        let otherReq = try Envelope.sign(TestRequest(ask: otherAskEnv, seal: B64Data(world.brokerSeal.publicKey), issued: now(),
                                                     expires: otherAsk.expires), type: "request", with: world.broker)
        let other = try VerifiedRequest(otherReq, roster: try world.roster(seq: 1).peek(Roster.self), now: now())
        broker.send(LinkMessage.decision(req.id, try approve(other, by: world.a.id, with: world.a.presence)))
        // A stale one.
        broker.send(LinkMessage.decision(req.id, try approve(req, by: world.a.id, with: world.a.presence, at: now() - 200)))
        // An approver a newer roster removed.
        broker.send(LinkMessage(op: "roster", roster: world.roster(seq: 2, approvers: [world.a])))
        broker.send(LinkMessage.decision(req.id, try approve(req, by: world.b.id, with: world.b.presence)))
        // A roster not signed by an owner changes nothing.
        broker.send(LinkMessage(op: "roster", roster: world.roster(seq: 3, signer: world.b.presence)))

        let deny = try req.decide(DecisionValue.deny, approver: world.a.id, signer: world.a.transport, now: now())
        broker.send(LinkMessage.decision(req.id, deny))
        let result = try XCTUnwrap(pending.wait())
        XCTAssertEqual(result.outcome, .denied)
        XCTAssertEqual(daemon.queue.sync { daemon.roster?.roster.seq }, 2)
        XCTAssertEqual(TargetStore(paths: paths).loadRoster()?.roster.seq, 2, "the newer roster was saved")
    }

    func testGrantCoversTheSameAnchorOnly() throws {
        try startDaemon()
        waitLinked()
        let first = confirm("Run the migration?", grant: true)
        let req = try XCTUnwrap(broker.waitRequest(kind: Kind.confirm))
        XCTAssertTrue(req.ask.isGrantable, "the test runner has an anchor, so the ask may be granted")
        let env = try req.decide(DecisionValue.approve, grant: true, approver: world.a.id, signer: world.a.presence, now: now())
        broker.send(LinkMessage.decision(req.id, env))
        XCTAssertEqual(first.wait()?.outcome, .approved)

        let second = confirm("Run it again?")
        let r = try XCTUnwrap(second.wait())
        XCTAssertEqual(r.outcome, .approved)
        XCTAssertEqual(r.text, "BlitzKVM: approved by an earlier grant")
        XCTAssertEqual(broker.messages("ask").count, 1, "the grant answered without asking")
        // sudo isn't covered by a confirm grant (and needs root anyway).
        XCTAssertEqual(daemon.queue.sync { daemon.grants.count }, 1)
    }

    func testPamFromANonRootPeerIsRefused() throws {
        try startDaemon()
        waitLinked()
        let r = RequesterClient.request(socket: paths.socket,
                                        LocalMessage(op: "pam", user: "user", service: "sudo", tty: "ttys001", pid: getpid()),
                                        timeout: 5, requireRoot: false) { _ in }
        XCTAssertEqual(r.outcome, .refused)
        XCTAssertTrue(broker.messages("ask").isEmpty)
    }

    func testRejectedAndUnavailable() throws {
        try startDaemon()
        waitLinked()
        let pending = confirm("Ship it?")
        let req = try XCTUnwrap(broker.waitRequest(kind: Kind.confirm))
        // The broker's reason reaches a terminal: made safe first.
        broker.send(LinkMessage(op: "rejected", id: req.id, reason: "too many\u{1b}[2J requests\n"))
        let r = try XCTUnwrap(pending.wait())
        XCTAssertEqual(r.outcome, .unavailable)
        XCTAssertEqual(r.text, "BlitzKVM: the JetKVM refused the request (too many\\x1b[2J requests\\n)")

        // The link drops: requests in flight end, new ones are unavailable.
        let inFlight = confirm("Still there?")
        XCTAssertNotNil(broker.waitRequest(kind: Kind.confirm, excluding: [req.id]))
        broker.close()
        XCTAssertEqual(inFlight.wait()?.outcome, .unavailable)
        XCTAssertEqual(confirm("Anyone?").wait()?.outcome, .unavailable)
    }

    func testOpenRequestsPerUserAreCapped() throws {
        try startDaemon()
        waitLinked()
        let open = (0..<Daemon.openPerUser).map { confirm("Question \($0)?") }
        XCTAssertNotNil(broker.wait { $0.requests.count == Daemon.openPerUser ? true : nil })
        let r = try XCTUnwrap(confirm("One more?").wait())
        XCTAssertEqual(r.outcome, .unavailable)
        XCTAssertEqual(r.text, "BlitzKVM: too many open requests")
        XCTAssertEqual(broker.messages("ask").count, Daemon.openPerUser)
        _ = open
    }

    /// What a requester says reaches approvers made safe: no control
    /// characters, no bidi overrides.
    func testAskTextIsDisplaySafe() throws {
        try startDaemon()
        waitLinked()
        _ = PendingResult(socket: paths.socket, LocalMessage(op: "confirm", title: "Deploy\n\u{1b}[2Jnow \u{202E}exe.txt",
                                                                       detail: "line\tone", timeout: 60))
        let req = try XCTUnwrap(broker.waitRequest(kind: Kind.confirm))
        XCTAssertEqual(req.ask.title, "Deploy\\n\\x1b[2Jnow \\u{202E}exe.txt")
        XCTAssertEqual(req.ask.detail, "line\\tone")
        XCTAssertTrue(req.ask.requester!.chain.allSatisfy { !$0.name.unicodeScalars.contains { $0.value < 0x20 } })
    }

    /// Local users get a bounded number of connections (each is a thread in
    /// the root daemon), and one that says nothing is closed.
    func testLocalClientsAreCapped() throws {
        try startDaemon { $0.maxClients = 3; $0.requestTimeout = 0.5 }
        waitLinked()
        let silent = try (0..<3).map { _ in try Sockets.connectUnix(path: paths.socket) }
        defer { silent.forEach { close($0) } }
        XCTAssertTrue(eventually { daemon.queue.sync { daemon.clients.count } == 3 })
        let extra = try Sockets.connectUnix(path: paths.socket)
        defer { close(extra) }
        XCTAssertTrue(hangsUp(extra, within: 1), "the fourth is refused")
        XCTAssertTrue(silent.allSatisfy { hangsUp($0, within: 2) }, "the silent ones are closed")
        XCTAssertEqual(confirmNow("Room again?"), true, "then there is room again")
    }

    /// Reads until the other end hangs up (true) or `within` passes.
    func hangsUp(_ fd: Int32, within: TimeInterval) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, Int32(within * 1000)) > 0 else { return false }
        var b = [UInt8](repeating: 0, count: 64)
        return read(fd, &b, b.count) <= 0
    }

    /// A confirm that reaches the broker.
    func confirmNow(_ q: String) -> Bool {
        let before = broker.messages("ask").count
        _ = confirm(q)
        return broker.wait { $0.received.filter { $0.op == "ask" }.count > before ? true : nil } ?? false
    }

    /// A broker that closes the link before auth (its slot went elsewhere)
    /// gets the daemon back at once, not after a growing backoff.
    func testReconnectsPromptlyWhenTheBrokerClosesBeforeAuth() throws {
        broker.closeBeforeAuth = 4
        let start = Date()
        try startDaemon { $0.linkTuning.minBackoff = 0.2 } // 0.2+0.4+0.8+1.6 s with backoff
        waitLinked()
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.5)
        XCTAssertEqual(broker.connections, 5)
    }

    func testRequesterLeavingCancels() throws {
        try startDaemon()
        waitLinked()
        let fd = try Sockets.connectUnix(path: paths.socket)
        var line = try JSONEncoder.wire.encode(LocalMessage(op: "confirm", title: "Leave?"))
        line.append(0x0A)
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        let req = try XCTUnwrap(broker.waitRequest(kind: Kind.confirm))
        close(fd)
        XCTAssertNotNil(broker.waitMessage("cancel") { $0.id == req.id })
    }

    func testRefusesAnotherBroker() throws {
        let stranger = try FakeBroker(world: World(target: target.publicKey), roster: world.roster(seq: 1))
        defer { stranger.close() }
        try startDaemon(endpoint: .fixed(host: "127.0.0.1", port: stranger.port))
        XCTAssertNil(stranger.waitMessage("auth", timeout: 1), "no auth for a broker the roster doesn't name")
    }

    /// A request around another ask under the same id (validly signed:
    /// a broker that lies) is refused, so its approval counts for nothing.
    func testRequestMustCarryTheDaemonsOwnAsk() throws {
        broker.autoRequest = false
        try startDaemon()
        waitLinked()
        let pending = confirm("Harmless?")
        let original = try XCTUnwrap(broker.wait { $0.asks.values.first })
        var forged = try original.peek(Ask.self)
        forged.title = "Something else entirely"
        let forgedReq = broker.offer(try Envelope.sign(forged, type: "ask", with: target))
        XCTAssertEqual(forgedReq.id, try original.peek(Ask.self).id)
        let approve = try forgedReq.decide(DecisionValue.approve, approver: world.a.id, signer: world.a.presence, now: now())
        broker.send(LinkMessage.decision(forgedReq.id, approve))

        let genuine = broker.offer(original)
        let deny = try genuine.decide(DecisionValue.deny, approver: world.a.id, signer: world.a.presence, now: now())
        broker.send(LinkMessage.decision(genuine.id, deny))
        XCTAssertEqual(pending.wait()?.outcome, .denied)
    }
}
