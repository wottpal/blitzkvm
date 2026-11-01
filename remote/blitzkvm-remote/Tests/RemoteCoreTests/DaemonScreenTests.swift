import ApprovalKit
import Darwin
import XCTest
@testable import RemoteCore

/// Screen asks through the daemon: an agent reports a 1Password prompt, the
/// daemon checks its owner, asks, and after the approval clicks through the
/// broker; secure input raises a password-dialog ask.
final class DaemonScreenTests: XCTestCase {
    var dir: URL!
    var paths: Paths!
    var world: World!
    var broker: FakeBroker!
    var daemon: Daemon!
    var processes: FakeProcesses!
    var console = ConsoleState(uid: getuid())
    let consoleLock = NSLock()

    override func setUpWithError() throws {
        Log.toStderr = false
        dir = makeTempDir()
        paths = Paths(state: dir, socket: dir.appendingPathComponent("s").path)
        let store = TargetStore(paths: paths)
        let target = try store.loadOrCreateKey()
        world = World(target: target.publicKey)
        try store.installGenesis(world.roster(seq: 1), targetID: target.id)
        broker = try FakeBroker(world: world, roster: world.roster(seq: 1))
        processes = FakeProcesses()
        processes.add(ProcInfo(pid: 7000, ppid: 1, uid: getuid(), comm: "1Password", start: 10), identity: .onePassword)
        processes.add(ProcInfo(pid: 6100, ppid: 1, uid: 0, comm: "SecurityAgent", start: 10), identity: .securityAgent)
        // An op run from a shell run by an agent.
        processes.add(ProcInfo(pid: 5002, ppid: 5001, uid: getuid(), comm: "op", start: 30, tty: "ttys004"),
                      path: "/opt/homebrew/bin/op", args: ["op", "item", "get", "Example"], identity: .other)
        processes.add(ProcInfo(pid: 5001, ppid: 5000, uid: getuid(), comm: "zsh", start: 20), path: "/bin/zsh", args: ["zsh"],
                      identity: CodeIdentity(identifier: "com.apple.zsh", apple: true))
        processes.add(ProcInfo(pid: 5000, ppid: 1, uid: getuid(), comm: "node", start: 15), path: "/usr/local/bin/node",
                      args: ["node", "agent"], identity: nil)

        var config = Daemon.Config(paths: paths)
        config.userMode = true
        config.endpoint = .fixed(host: "127.0.0.1", port: broker.port)
        config.processes = processes
        config.console = { [unowned self] in consoleLock.lock(); defer { consoleLock.unlock() }; return console }
        config.pollInterval = 0.05
        config.driverTuning.poll = 0.02
        config.driverTuning.watch = 0.01
        config.computerName = "Mac mini"
        // The test agent isn't signed: these tests take it at its word.
        config.insecureAgent = true
        self.config = config
        try startDaemon()
    }

    var config: Daemon.Config!

    func startDaemon() throws {
        daemon = try Daemon(config: config)
        try daemon.start()
        XCTAssertTrue(broker.waitReady())
        XCTAssertTrue(eventually { daemon.queue.sync { daemon.link.isReady } })
    }

    func restartDaemon(_ change: (inout Daemon.Config) -> Void) throws {
        daemon.stop()
        change(&config)
        try startDaemon()
    }

    override func tearDown() {
        daemon?.stop()
        broker?.close()
        try? FileManager.default.removeItem(at: dir)
    }

    func setConsole(_ c: ConsoleState) {
        consoleLock.lock()
        console = c
        consoleLock.unlock()
    }

    func testOnePasswordPromptEndToEnd() throws {
        let agent = try TestAgent(socket: paths.socket)
        defer { agent.close() }
        let terminal = AppRef(pid: 3000, bundle: "com.example.terminal", name: "Terminal")
        agent.facts = AgentFacts(frontmost: terminal, windows: [prompt], display: display, keyMap: ["a": [[4, 0]]])
        broker.onStep = { [agent] step in if step.click != nil { agent.facts.windows = [] } }

        let req = try XCTUnwrap(broker.waitRequest(kind: Kind.onePassword))
        XCTAssertEqual(req.ask.title, "1Password access requested")
        XCTAssertEqual(req.ask.secret, SecretKind.onePassword)
        XCTAssertEqual(req.ask.evidence?.window, prompt.rect)
        XCTAssertEqual(req.ask.evidence?.display, display)
        XCTAssertEqual(req.ask.evidence?.locked, false)
        // Which process asked is a guess: in the detail, said as one, and
        // not in the requester field.
        XCTAssertNil(req.ask.requester)
        XCTAssertTrue(req.ask.detail?.contains("\nProbably requested by: op item get Example (op ← zsh ← node") == true,
                      req.ask.detail ?? "")
        // One ask per appearance.
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(broker.messages("ask").count, 1)

        let env = try req.decide(DecisionValue.approve, approver: world.a.id, signer: world.a.presence, now: now())
        broker.send(LinkMessage.decision(req.id, env))
        let done = try XCTUnwrap(broker.waitMessage("done") { $0.id == req.id })
        XCTAssertEqual(done.ok, true, done.note ?? "")
        let click = try XCTUnwrap(broker.messages("step").first?.step?.click)
        XCTAssertEqual(click.x, (552 + 400 - 77) / 1504, accuracy: 1e-9)
        XCTAssertEqual(click.y, (301 + 346 - 61) / 948, accuracy: 1e-9)
        XCTAssertTrue(eventually { agent.activated == [terminal] }, "the previous app comes back")
    }

    func testPromptFromAnImpostorIsIgnored() throws {
        let agent = try TestAgent(socket: paths.socket)
        defer { agent.close() }
        var fake = prompt
        fake.pid = 5000 // claims 1Password's window, but its signature isn't
        agent.facts = AgentFacts(windows: [fake], display: display)
        XCTAssertNil(broker.waitMessage("ask", timeout: 0.5))
    }

    func testPromptWithdrawnWhenItGoes() throws {
        let agent = try TestAgent(socket: paths.socket)
        defer { agent.close() }
        agent.facts = AgentFacts(windows: [prompt], display: display)
        let req = try XCTUnwrap(broker.waitRequest(kind: Kind.onePassword))
        agent.facts = AgentFacts(windows: [], display: display)
        XCTAssertNotNil(broker.waitMessage("cancel") { $0.id == req.id })
    }

    func testPasswordDialogRaisesAnAsk() throws {
        setConsole(ConsoleState(uid: getuid(), secureInputPID: 6100))
        let req = try XCTUnwrap(broker.waitRequest(kind: Kind.securityAgent))
        XCTAssertEqual(req.ask.secret, SecretKind.mac)
        XCTAssertEqual(req.ask.evidence?.secureInput?.pid, 6100)
        XCTAssertEqual(req.ask.evidence?.secureInput?.bundle, "com.apple.SecurityAgent")
        XCTAssertEqual(req.ask.detail, "A macOS password dialog (com.apple.SecurityAgent) has the keyboard.",
                       "only what root verified")
        // Secure input held by anyone else raises nothing.
        setConsole(ConsoleState(uid: getuid(), secureInputPID: 5002))
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(broker.messages("ask").count, 1)
    }

    /// An approver's signed request to unlock (its transport key).
    func unlockRequest(_ keys: World.ApproverKeys? = nil, signer: SoftwareSigner? = nil, target: String? = nil,
                       issued: Int64? = nil) throws -> Envelope {
        let k = keys ?? world.a
        let u = UnlockRequest(broker: world.brokerInfo.id, target: target ?? Wire.kid(world.target), approver: k.id,
                              issued: issued ?? Int64(Date().timeIntervalSince1970))
        return try Envelope.sign(u, type: "unlock", with: signer ?? k.transport)
    }

    func testUnlockOnlyWhenLocked() throws {
        broker.send(LinkMessage(op: "unlock", unlock: try unlockRequest()))
        XCTAssertNil(broker.waitMessage("ask", timeout: 0.3), "not locked")
        setConsole(ConsoleState(uid: getuid(), locked: true, secureInputPID: 6100))
        broker.send(LinkMessage(op: "unlock", unlock: try unlockRequest(world.b)))
        XCTAssertNil(broker.waitMessage("ask", timeout: 0.3), "locked, but the keyboard isn't the login window's")
        setConsole(ConsoleState(uid: getuid(), locked: true))
        broker.send(LinkMessage(op: "unlock", unlock: try unlockRequest()))
        let req = try XCTUnwrap(broker.waitRequest(kind: Kind.unlock))
        try deny(req)
        broker.send(LinkMessage(op: "unlock", unlock: try unlockRequest()))
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(broker.messages("ask").count, 1, "the same approver again within 30 s")
        XCTAssertEqual(req.ask.title, "Unlock Mac mini")
        XCTAssertEqual(req.ask.evidence?.locked, true)
        XCTAssertEqual(req.ask.requestedBy, world.a.id)
        XCTAssertEqual(req.ask.detail, "Requested by Owner's iPhone")
    }

    /// The relay or the JetKVM can't make a locked Mac ask for its password.
    func testUnlockNeedsAnApproversSignature() throws {
        setConsole(ConsoleState(uid: getuid(), locked: true))
        let stranger = SoftwareSigner()
        let cases: [(String, Envelope?)] = [
            ("unsigned", nil),
            ("signed by the presence key", try unlockRequest(signer: world.a.presence)),
            ("signed by a stranger", try unlockRequest(signer: stranger)),
            ("for another target", try unlockRequest(target: "0123456789abcdef01234567")),
            ("stale", try unlockRequest(issued: Int64(Date().timeIntervalSince1970) - 120)),
        ]
        for (name, env) in cases {
            broker.send(LinkMessage(op: "unlock", unlock: env))
            XCTAssertNil(broker.waitMessage("ask", timeout: 0.3), name)
        }
        let good = try unlockRequest()
        broker.send(LinkMessage(op: "unlock", unlock: good))
        let req = try XCTUnwrap(broker.waitRequest(kind: Kind.unlock))
        try deny(req)
        daemon.queue.sync { daemon.lastUnlock = [:] } // past the cooldown: only the replay check is left
        // A replay of the same request raises nothing more.
        broker.send(LinkMessage(op: "unlock", unlock: good))
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(broker.messages("ask").count, 1)
        // A fresh request from the other approver does.
        broker.send(LinkMessage(op: "unlock", unlock: try unlockRequest(world.b)))
        let second = broker.waitRequest(kind: Kind.unlock, excluding: [req.id])
        XCTAssertEqual(second?.ask.requestedBy, world.b.id)
    }

    /// Denies a request and waits until the daemon has let it go.
    func deny(_ req: VerifiedRequest) throws {
        let env = try req.decide(DecisionValue.deny, approver: world.a.id, signer: world.a.transport, now: now())
        broker.send(LinkMessage.decision(req.id, env))
        XCTAssertTrue(eventually { self.daemon.queue.sync { self.daemon.pending[req.id] == nil } })
    }

    // MARK: Agent trust

    /// Without a Developer ID to check the agent against (and without
    /// --insecure-agent), no agent counts: screen asks are unavailable.
    func testUnsignedAgentIsRefused() throws {
        try restartDaemon { $0.insecureAgent = false; $0.agentRequirement = nil }
        let agent = try TestAgent(socket: paths.socket)
        defer { agent.close() }
        XCTAssertTrue(eventually { agent.closed }, "the daemon hangs up")
        agent.facts = AgentFacts(windows: [prompt], display: display)
        XCTAssertNil(broker.waitMessage("ask", timeout: 0.5))
        XCTAssertNil(daemon.queue.sync { daemon.agent })
    }

    func testAgentWithAnotherSignatureIsRefused() throws {
        try restartDaemon { $0.insecureAgent = false; $0.agentRequirement = CodeSigning.agentRequirement(team: "ABCDE12345") }
        let agent = try TestAgent(socket: paths.socket)
        defer { agent.close() }
        XCTAssertTrue(eventually { agent.closed }, "this test runner isn't signed by that team")
        XCTAssertNil(daemon.queue.sync { daemon.agent })
    }

    /// A key map with a stroke that types no character (Return, ⌘) is
    /// dropped whole: the broker would refuse it, and it could send the rest
    /// of a password elsewhere.
    func testInvalidKeyMapIsDropped() throws {
        let agent = try TestAgent(socket: paths.socket)
        defer { agent.close() }
        agent.facts = AgentFacts(display: display, keyMap: ["a": [[4, 0]], "b": [[5, 0x02]]])
        XCTAssertTrue(eventually { daemon.queue.sync { daemon.facts?.keyMap?.count == 2 } })
        for bad: [String: [Stroke]] in [["a": [[4, 0]], "\n": [[0x28, 0]]], // Return
                                        ["a": [[0x2B, 0]]], // Tab
                                        ["a": [[4, 0x08]]], // Command
                                        ["a": [[4, 0], [4, 0], [4, 0]]], // three strokes
                                        ["a": []],
                                        ["ab": [[4, 0]]]] {
            agent.facts = AgentFacts(display: display, keyMap: bad)
            XCTAssertTrue(eventually { daemon.queue.sync { daemon.facts?.keyMap == nil && daemon.facts?.display == display } }, "\(bad)")
            agent.facts = AgentFacts(display: display, keyMap: ["a": [[4, 0]]])
            XCTAssertTrue(eventually { daemon.queue.sync { daemon.facts?.keyMap != nil } })
        }
    }

    // MARK: Typing

    /// Approves the password dialog's ask with a password, while the agent
    /// has a key map; returns the request.
    func approvePasswordDialog(agent: TestAgent) throws -> VerifiedRequest {
        agent.facts = AgentFacts(display: display, keyMap: ["a": [[4, 0]], "b": [[5, 0]]])
        setConsole(ConsoleState(uid: getuid(), secureInputPID: 6100))
        let req = try XCTUnwrap(broker.waitRequest(kind: Kind.securityAgent))
        let env = try req.decide(DecisionValue.approve, secret: "ab", approver: world.a.id, signer: world.a.presence, now: now())
        broker.send(LinkMessage.decision(req.id, env))
        return req
    }

    /// The password field loses the keyboard while the broker types: the
    /// daemon sees it on its own console read, aborts at once, and erases
    /// nothing into the app that has the keyboard now.
    func testAbortWhenTheKeyboardMovesWhileTyping() throws {
        let agent = try TestAgent(socket: paths.socket)
        defer { agent.close() }
        broker.holdSecret = true
        broker.onStep = { [unowned self] step in
            if step.secret != nil { setConsole(ConsoleState(uid: getuid(), secureInputPID: 5002)) }
        }
        let req = try approvePasswordDialog(agent: agent)
        XCTAssertNotNil(broker.waitMessage("abort") { $0.id == req.id })
        let done = try XCTUnwrap(broker.waitMessage("done") { $0.id == req.id })
        XCTAssertEqual(done.ok, false)
        XCTAssertTrue(done.note?.contains("4 characters were typed and not erased") == true, done.note ?? "")
        XCTAssertFalse(broker.messages("step").contains { $0.step?.erase != nil })
    }

    /// The field is back by the time the broker stopped: the characters it
    /// typed (its count, not the secret's padded length) are erased.
    func testAbortThenEraseWhatTheBrokerTyped() throws {
        let agent = try TestAgent(socket: paths.socket)
        defer { agent.close() }
        broker.holdSecret = true
        broker.abortTyped = 1
        broker.onStep = { [unowned self] step in
            if step.secret != nil { setConsole(ConsoleState(uid: getuid(), locked: true, secureInputPID: 6100)) }
        }
        broker.onAbort = { [unowned self] in setConsole(ConsoleState(uid: getuid(), secureInputPID: 6100)) }
        let req = try approvePasswordDialog(agent: agent)
        let done = try XCTUnwrap(broker.waitMessage("done") { $0.id == req.id })
        XCTAssertEqual(done.ok, false)
        XCTAssertEqual(broker.messages("step").compactMap { $0.step?.erase }, [1])
    }
}

/// The agent's side of the socket: answers refreshes with `facts`, records
/// activations.
final class TestAgent {
    private let conn: LineConn
    private let lock = NSLock()
    private var _facts = AgentFacts()
    private var _activated: [AppRef] = []
    private var _closed = false

    init(socket: String) throws {
        conn = LineConn(fd: try Sockets.connectUnix(path: socket), queue: DispatchQueue(label: "test agent"))
        conn.start(onLine: { [weak self] in self?.handle($0) }, onClose: { [weak self] in
            guard let self else { return }
            lock.lock(); _closed = true; lock.unlock()
        })
        conn.send(LocalMessage(op: "agent"))
    }

    /// The daemon hung up on it.
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return _closed }

    func close() { conn.close() }

    var facts: AgentFacts {
        get { lock.lock(); defer { lock.unlock() }; return _facts }
        set {
            lock.lock(); _facts = newValue; lock.unlock()
            conn.send(LocalMessage(op: "facts", facts: newValue))
        }
    }

    var activated: [AppRef] { lock.lock(); defer { lock.unlock() }; return _activated }

    private func handle(_ data: Data) {
        guard let m = try? JSONDecoder().decode(LocalMessage.self, from: data) else { return }
        switch m.op {
        case "refresh": conn.send(LocalMessage(op: "facts", facts: facts, seq: m.seq))
        case "activate": if let app = m.app { lock.lock(); _activated.append(app); lock.unlock() }
        default: break
        }
    }
}
