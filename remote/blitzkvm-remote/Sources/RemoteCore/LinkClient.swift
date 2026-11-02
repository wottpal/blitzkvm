import ApprovalKit
import Foundation

/// The daemon's end of the host link: dial the broker, answer its hello
/// with the target key, then pass everything but ping/pong to the daemon.
/// Reconnects with backoff (1 s doubling to 30 s) whenever the link drops,
/// at once when the broker closed it before auth without refusing it (the
/// slot went to another connection), and drops a link that has said
/// nothing for 45 s.
///
/// Everything but the blocking dial runs on `queue`, the daemon's.
public final class LinkClient {
    public enum State { case idle, connecting, hello, auth, ready }

    public struct Tuning {
        public var pingInterval: TimeInterval = 15
        public var idleTimeout: TimeInterval = 45
        public var minBackoff: TimeInterval = 1
        public var maxBackoff: TimeInterval = 30
        public var slotRetry: TimeInterval = 0.25
        public init() {}
    }

    private let queue: DispatchQueue
    private let endpoint: HostLink.Endpoint
    private let signer: EnvelopeSigner
    private let expectedBroker: () -> String?
    private let tuning: Tuning
    private let clock: () -> Int64

    private var conn: LineConn?
    public private(set) var state: State = .idle
    /// The ready connection, for sendNow from any thread.
    private let readyLock = NSLock()
    private var readyConn: LineConn?
    private var backoff: TimeInterval
    private var lastHeard = Date()
    private var pingTimer: DispatchSourceTimer?
    private var stopped = false
    private var refused = false
    private var lastProblem = ""

    /// The broker's roster from `ready`.
    public var onReady: ((Envelope?) -> Void)?
    public var onMessage: ((LinkMessage) -> Void)?
    /// A ready link went down.
    public var onDown: (() -> Void)?

    public init(endpoint: HostLink.Endpoint, signer: EnvelopeSigner, queue: DispatchQueue, tuning: Tuning = Tuning(),
                clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) },
                expectedBroker: @escaping () -> String?) {
        self.endpoint = endpoint; self.signer = signer; self.queue = queue; self.tuning = tuning
        self.clock = clock; self.expectedBroker = expectedBroker
        backoff = tuning.minBackoff
    }

    public func start() { queue.async { self.connect() } }

    public func stop() {
        queue.async {
            self.stopped = true
            self.conn?.close()
        }
    }

    /// On `queue`.
    public var isReady: Bool { state == .ready }

    /// Sends on a ready link (on `queue`); false otherwise.
    @discardableResult
    public func send(_ m: LinkMessage) -> Bool {
        guard state == .ready, let conn else { return false }
        return conn.send(m)
    }

    /// Sends from any thread without waiting for `queue` (an abort mustn't
    /// queue up behind other work); false without a ready link.
    @discardableResult
    public func sendNow(_ m: LinkMessage) -> Bool {
        readyLock.lock()
        let c = readyConn
        readyLock.unlock()
        return c?.send(m) ?? false
    }

    private func setReady(_ c: LineConn?) {
        readyLock.lock()
        readyConn = c
        readyLock.unlock()
    }

    private func problem(_ s: String) {
        if s != lastProblem { Log.info("link: \(s)") }
        lastProblem = s
    }

    private func connect() {
        guard !stopped, state == .idle else { return }
        guard expectedBroker() != nil else {
            problem("no roster yet (the installer writes it)")
            return retry()
        }
        guard let (host, port) = endpoint.resolve() else {
            problem("the JetKVM's USB link isn't up")
            return retry()
        }
        state = .connecting
        DispatchQueue.global().async { [self] in
            do {
                let fd = try Sockets.connectTCP(host: host, port: port)
                queue.async { self.attach(fd) }
            } catch {
                queue.async {
                    self.problem("can't reach the broker at \(host) port \(port): \(error)")
                    self.state = .idle
                    self.retry()
                }
            }
        }
    }

    private func retry(after soon: TimeInterval? = nil) {
        guard !stopped else { return }
        let delay = soon ?? backoff
        if soon == nil { backoff = min(backoff * 2, tuning.maxBackoff) }
        queue.asyncAfter(deadline: .now() + delay) { self.connect() }
    }

    private func attach(_ fd: Int32) {
        guard !stopped else { close(fd); state = .idle; return }
        let c = LineConn(fd: fd, queue: queue)
        conn = c
        state = .hello
        refused = false
        lastHeard = Date()
        c.start(onLine: { [weak self] in self?.handle($0) }, onClose: { [weak self] in self?.closed() })
        startPing()
    }

    private func closed() {
        let wasReady = state == .ready
        let closedBeforeAuth = (state == .hello || state == .auth) && !refused
        conn = nil
        setReady(nil)
        state = .idle
        pingTimer?.cancel()
        pingTimer = nil
        if wasReady {
            problem("the link went down")
            onDown?()
        }
        if closedBeforeAuth {
            problem("the broker closed the link before auth")
            return retry(after: tuning.slotRetry)
        }
        retry()
    }

    private func handle(_ data: Data) {
        lastHeard = Date()
        guard let m = try? JSONDecoder().decode(LinkMessage.self, from: data) else {
            Log.info("link: unreadable message")
            return
        }
        switch (state, m.op) {
        case (.hello, "hello"):
            guard let broker = m.broker, let nonce = m.nonce, broker == expectedBroker() else {
                problem("a broker that isn't this target's (\(m.broker ?? "?")) answered")
                refused = true
                backoff = tuning.maxBackoff
                conn?.close()
                return
            }
            do {
                let auth = try Envelope.sign(LinkAuth(broker: broker, target: signer.id, nonce: nonce.data, issued: clock()),
                                             type: "link", with: signer)
                conn?.send(LinkMessage(op: "auth", auth: auth))
                state = .auth
            } catch {
                Log.info("link: can't sign the link auth: \(error)")
                conn?.close()
            }
        case (.auth, "ready"):
            state = .ready
            setReady(conn)
            backoff = tuning.minBackoff
            problem("connected")
            onReady?(m.roster)
        case (.auth, "rejected"):
            problem("the broker refused this target: \(Display.safe(m.reason ?? "no reason", maxBytes: 200))")
            refused = true
            backoff = tuning.maxBackoff
            conn?.close()
        case (.ready, "ping"):
            conn?.send(LinkMessage(op: "pong"))
        case (.ready, "pong"):
            break
        case (.ready, _):
            onMessage?(m)
        default:
            Log.info("link: unexpected \(Display.safe(m.op, maxBytes: 32)) during the handshake")
            refused = true
            conn?.close()
        }
    }

    private func startPing() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + tuning.pingInterval, repeating: tuning.pingInterval)
        t.setEventHandler { [weak self] in
            guard let self, let conn = self.conn else { return }
            if Date().timeIntervalSince(self.lastHeard) > self.tuning.idleTimeout {
                self.problem("the broker went quiet")
                conn.close()
            } else if self.state == .ready {
                conn.send(LinkMessage(op: "ping"))
            }
        }
        pingTimer?.cancel()
        pingTimer = t
        t.resume()
    }
}
