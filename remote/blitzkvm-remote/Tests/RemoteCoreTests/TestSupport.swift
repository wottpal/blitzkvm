import ApprovalKit
import Darwin
import Foundation
import XCTest
@testable import RemoteCore

/// A short directory for state and a socket (Unix socket paths are short).
func makeTempDir() -> URL {
    let url = URL(fileURLWithPath: "/tmp").appendingPathComponent("bkr-\(UUID().uuidString.prefix(8))")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Keys and rosters: an owner (A), a second approver (B) and a broker.
struct World {
    struct ApproverKeys {
        let presence = SoftwareSigner(), transport = SoftwareSigner(), seal = SealKey()
        let name: String
        var approver: Approver {
            Approver(name: name, platform: "ios", presence: presence.publicKey, transport: transport.publicKey, seal: seal.publicKey)
        }
        var id: String { approver.id }
    }

    let a = ApproverKeys(name: "Owner's iPhone")
    let b = ApproverKeys(name: "Second Mac")
    let broker = SoftwareSigner()
    let brokerSeal = SealKey()
    let target: Data

    init(target: Data) { self.target = target }

    var brokerInfo: BrokerInfo { BrokerInfo(id: broker.id, key: B64Data(broker.publicKey), seal: B64Data(brokerSeal.publicKey)) }

    func roster(seq: UInt64, approvers: [ApproverKeys]? = nil, signer: SoftwareSigner? = nil) -> Envelope {
        let list = approvers ?? [a, b]
        let r = Roster(seq: seq, issued: Int64(Date().timeIntervalSince1970), broker: brokerInfo, owners: [a.id],
                       approvers: list.map(\.approver), targets: [Target(name: "Mac mini", key: target)])
        return try! Envelope.sign(r, type: "roster", with: signer ?? a.presence)
    }
}

/// The request the broker makes of an ask (ApprovalKit has no public
/// initializer for Request: only the Go broker makes them).
struct TestRequest: Encodable {
    var v = 1
    var ask: Envelope
    var seal: B64Data
    var issued: Int64
    var expires: Int64
}

/// The broker's side of the link, enough to drive the daemon: hello and
/// auth, requests for asks, and whatever the test sends.
final class FakeBroker {
    let world: World
    var rosterEnv: Envelope
    let queue = DispatchQueue(label: "fake broker")
    let port: UInt16
    private let listener: Int32
    private var conn: LineConn?
    private var nonce = Wire.randomBytes(32)
    private let cond = NSCondition()
    private(set) var received: [LinkMessage] = []
    private(set) var requests: [String: VerifiedRequest] = [:]
    private(set) var authed = false
    private(set) var asks: [String: Envelope] = [:]
    /// Offer every ask as a request at once (off: the test calls offer).
    var autoRequest = true
    /// How the broker answers a step (true: ok).
    var stepOK = true
    var onStep: ((Step) -> Void)?
    /// A secret step: how many characters it reports typed; with
    /// `holdSecret` it runs until an `abort`, which answers with `abortTyped`.
    var secretTyped = 7
    var holdSecret = false
    var abortTyped = 4
    var onAbort: (() -> Void)?
    private var heldSecret: LinkMessage?
    /// Close this many connections right after their hello (a slot that
    /// went to someone else).
    var closeBeforeAuth = 0
    private(set) var connections = 0

    init(world: World, roster: Envelope) throws {
        self.world = world
        rosterEnv = roster
        (listener, port) = try Sockets.listenLoopback()
        let fd = listener
        Thread { [weak self] in
            while let c = Sockets.accept(fd) { self?.queue.async { self?.attach(c) } }
        }.start()
    }

    func close() {
        shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        queue.sync { conn?.close() }
    }

    func dropConnection() { queue.sync { conn?.close() } }

    private func attach(_ fd: Int32) {
        conn?.close()
        let c = LineConn(fd: fd, queue: queue)
        conn = c
        nonce = Wire.randomBytes(32)
        mark { connections += 1 }
        c.start(onLine: { [weak self] in self?.handle($0) }, onClose: {})
        c.send(LinkMessage(op: "hello", broker: world.broker.id, nonce: B64Data(nonce)))
        if closeBeforeAuth > 0 {
            closeBeforeAuth -= 1
            c.close()
        }
    }

    func send(_ m: LinkMessage) { queue.sync { _ = conn?.send(m) } }

    private func handle(_ data: Data) {
        guard let m = try? JSONDecoder().decode(LinkMessage.self, from: data) else { return }
        mark { received.append(m) }
        switch m.op {
        case "auth":
            guard let env = m.auth, let auth = try? env.open(LinkAuth.self, type: "link", key: world.target),
                  auth.broker == world.broker.id, auth.nonce.data == nonce else {
                conn?.send(LinkMessage(op: "rejected", reason: "bad auth"))
                return
            }
            mark { authed = true }
            conn?.send(LinkMessage(op: "ready", roster: rosterEnv))
        case "ask":
            guard let env = m.ask, let ask = try? env.open(Ask.self, type: "ask", key: world.target) else { return }
            mark { asks[ask.id] = env }
            if autoRequest { offerLocked(env) }
        case "step":
            if let step = m.step { onStep?(step) }
            let secret = m.step?.secret != nil
            if secret, holdSecret {
                heldSecret = m
                return
            }
            conn?.send(LinkMessage(op: "stepped", id: m.id, seq: m.seq, ok: stepOK, error: stepOK ? nil : "refused",
                                   typed: secret ? (stepOK ? secretTyped : 0) : nil))
        case "abort":
            onAbort?()
            if let held = heldSecret, held.id == m.id {
                heldSecret = nil
                conn?.send(LinkMessage(op: "stepped", id: held.id, seq: held.seq, ok: false, error: "aborted", typed: abortTyped))
            }
        case "ping":
            conn?.send(LinkMessage(op: "pong"))
        default:
            break
        }
    }

    /// Signs a request for an ask envelope and sends it.
    @discardableResult
    func offer(_ askEnv: Envelope) -> VerifiedRequest { queue.sync { offerLocked(askEnv) } }

    @discardableResult
    private func offerLocked(_ env: Envelope) -> VerifiedRequest {
        let ask = try! env.peek(Ask.self)
        let now = Int64(Date().timeIntervalSince1970)
        let req = try! Envelope.sign(TestRequest(ask: env, seal: B64Data(world.brokerSeal.publicKey), issued: now,
                                                 expires: ask.expires), type: "request", with: world.broker)
        let verified = try! VerifiedRequest(req, roster: try! rosterEnv.peek(Roster.self), now: now)
        mark { requests[ask.id] = verified }
        conn?.send(LinkMessage(op: "request", request: req))
        return verified
    }

    private func mark(_ change: () -> Void) {
        cond.lock()
        change()
        cond.broadcast()
        cond.unlock()
    }

    /// Waits until `check` holds (on the broker's records).
    @discardableResult
    func wait<T>(timeout: TimeInterval = 10, _ check: (FakeBroker) -> T?) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        cond.lock()
        defer { cond.unlock() }
        while true {
            if let v = check(self) { return v }
            guard cond.wait(until: deadline) else { return check(self) }
        }
    }

    func waitReady() -> Bool { wait { $0.authed ? true : nil } ?? false }

    /// The next request for an ask of `kind`, by ask id.
    func waitRequest(kind: String, excluding: Set<String> = []) -> VerifiedRequest? {
        wait { b in b.requests.values.first { $0.ask.kind == kind && !excluding.contains($0.id) } }
    }

    func messages(_ op: String) -> [LinkMessage] {
        cond.lock()
        defer { cond.unlock() }
        return received.filter { $0.op == op }
    }

    func waitMessage(_ op: String, timeout: TimeInterval = 10, where match: (LinkMessage) -> Bool = { _ in true }) -> LinkMessage? {
        wait(timeout: timeout) { b in b.received.first { $0.op == op && match($0) } }
    }
}

/// Processes made up for a test, on top of the real ones.
final class FakeProcesses: ProcessInspector {
    var procs: [Int32: (info: ProcInfo, path: String?, args: [String]?, identity: CodeIdentity?)] = [:]
    let system = SystemProcesses()

    func add(_ info: ProcInfo, path: String? = nil, args: [String]? = nil, identity: CodeIdentity? = nil) {
        procs[info.pid] = (info, path, args, identity)
    }

    func info(_ pid: Int32) -> ProcInfo? { procs[pid]?.info ?? system.info(pid) }
    func path(_ pid: Int32) -> String? { procs[pid] != nil ? procs[pid]!.path : system.path(pid) }
    func args(_ pid: Int32) -> [String]? { procs[pid] != nil ? procs[pid]!.args : system.args(pid) }
    func cwd(_ pid: Int32) -> String? { procs[pid] != nil ? nil : system.cwd(pid) }
    func identity(_ pid: Int32) -> CodeIdentity? { procs[pid] != nil ? procs[pid]!.identity : system.identity(pid) }
    func all() -> [ProcInfo] { system.all() + procs.values.map(\.info) }
}

extension CodeIdentity {
    static let onePassword = CodeIdentity(identifier: OnePassword.bundle, team: OnePassword.team)
    static let securityAgent = CodeIdentity(identifier: "com.apple.SecurityAgent", apple: true)
    static let loginWindow = CodeIdentity(identifier: "com.apple.loginwindow", apple: true)
    static let other = CodeIdentity(identifier: "com.example.other", team: "ABCDE12345")
}

/// Runs a requester on a background thread.
final class PendingResult {
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _infos: [String] = []
    private(set) var result: (outcome: Outcome, text: String?)?

    init(socket: String, _ message: LocalMessage, timeout: TimeInterval = 30) {
        DispatchQueue.global().async { [self] in
            let r = RequesterClient.request(socket: socket, message, timeout: timeout) { text in
                self.lock.lock(); self._infos.append(text); self.lock.unlock()
            }
            result = r
            done.signal()
        }
    }

    var infos: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _infos
    }

    func wait(_ timeout: TimeInterval = 15) -> (outcome: Outcome, text: String?)? {
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return result
    }
}

func now() -> Int64 { Int64(Date().timeIntervalSince1970) }

/// Waits on a condition that something else makes true.
func eventually(_ timeout: TimeInterval = 10, _ check: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if check() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return check()
}

extension LinkMessage {
    static func decision(_ id: String, _ env: Envelope) -> LinkMessage { LinkMessage(op: "decision", decision: env, id: id) }
}
