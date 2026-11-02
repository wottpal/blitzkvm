import Foundation

/// A WebSocket to a broker: directly to the JetKVM (`/approvals/v1/ws`) or
/// through the relay (`/v1/b/{broker}/approver/{id}`). It authenticates
/// with the transport key and counts as connected once the other end says
/// `ready`; then it carries boxes both ways, reconnecting with backoff until
/// stopped.
public final class BoxChannel: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public enum Route: Sendable { case direct, relay }

    public let url: URL
    public let route: Route
    public let brokerID: String
    private let approverID: String
    private let transport: EnvelopeSigner
    private let onBox: @Sendable (Data) -> Void
    private let onState: @Sendable (Bool) -> Void
    /// Decides on an https server's certificate (a JetKVM's own CA); nil
    /// leaves it to the system. Boxes are sealed and signed end to end, so
    /// TLS adds privacy of the handshake only.
    private let serverTrust: (@Sendable (SecTrust) -> Bool)?
    private let queue = DispatchQueue(label: "ApprovalKit.BoxChannel")
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var authenticated = false
    private var helloAnswered = false
    private var stopped = true
    private var backoff: TimeInterval = 1
    private var generation = 0
    private var pingTimer: DispatchSourceTimer?
    /// When the other end last said anything (a pong, a box): a socket
    /// silent for longer than `silence` is taken for dead.
    private var lastHeard = Date()
    private static let silence: TimeInterval = 45
    private static let readyDeadline: TimeInterval = 10

    public init(url: URL, route: Route, brokerID: String, approverID: String, transport: EnvelopeSigner,
                serverTrust: (@Sendable (SecTrust) -> Bool)? = nil,
                onBox: @escaping @Sendable (Data) -> Void, onState: @escaping @Sendable (Bool) -> Void) {
        self.url = url; self.route = route; self.brokerID = brokerID; self.approverID = approverID
        self.transport = transport; self.serverTrust = serverTrust; self.onBox = onBox; self.onState = onState
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust, let serverTrust else {
            return completionHandler(.performDefaultHandling, nil)
        }
        if serverTrust(trust) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// The relay's approver WebSocket URL for a relay base URL.
    public static func relayURL(base: String, broker: String, approver: String) -> URL? {
        guard var c = URLComponents(string: base.trimmingCharacters(in: .whitespaces)) else { return nil }
        c.scheme = c.scheme == "http" ? "ws" : "wss"
        c.path = c.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty ? "" : "/" + c.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        c.path += "/v1/b/\(broker)/approver/\(approver)"
        return c.url
    }

    /// The JetKVM's approver WebSocket for a device base URL (http or https).
    public static func directURL(deviceBase: URL) -> URL? {
        guard var c = URLComponents(url: deviceBase, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = c.scheme == "https" ? "wss" : "ws"
        c.path = "/approvals/v1/ws"
        c.query = nil
        return c.url
    }

    public func start() {
        queue.async {
            guard self.stopped else { return }
            self.stopped = false
            self.connect()
        }
    }

    public func stop() {
        queue.async {
            self.stopped = true
            self.teardown()
        }
    }

    public var isConnected: Bool { queue.sync { authenticated } }

    /// Sends a box; false while not connected.
    @discardableResult
    public func send(box: Data) -> Bool {
        queue.sync {
            guard authenticated, let task else { return false }
            let msg = (try? JSONSerialization.data(withJSONObject: ["op": "box", "box": B64.encode(box)])) ?? Data()
            task.send(.string(String(decoding: msg, as: UTF8.self))) { _ in }
            return true
        }
    }

    private func teardown() {
        helloAnswered = false
        pingTimer?.cancel()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        if authenticated {
            authenticated = false
            onState(false)
        }
    }

    private func connect() {
        generation += 1
        let gen = generation
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 64 << 10
        self.session = session
        self.task = task
        task.resume()
        receive(task, gen: gen)
        // A socket that opens but never gets to `ready` tries again.
        queue.asyncAfter(deadline: .now() + Self.readyDeadline) { [weak self] in
            guard let self, gen == self.generation, !self.authenticated, !self.stopped else { return }
            self.retry(gen: gen)
        }
    }

    /// Reconnects now (the network changed, the Mac woke): a socket that
    /// looked open may be half-open.
    public func restart() {
        queue.async {
            guard !self.stopped else { return }
            self.backoff = 1
            self.teardown()
            self.connect()
        }
    }

    private func retry(gen: Int) {
        guard gen == generation, !stopped else { return }
        teardown()
        let delay = backoff
        backoff = min(backoff * 2, 60)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped, self.task == nil else { return }
            self.connect()
        }
    }

    private func receive(_ task: URLSessionWebSocketTask, gen: Int) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard gen == self.generation else { return }
                switch result {
                case .failure:
                    self.retry(gen: gen)
                case .success(let message):
                    let data: Data
                    switch message {
                    case .string(let s): data = Data(s.utf8)
                    case .data(let d): data = d
                    @unknown default: data = Data()
                    }
                    self.handle(data, task: task, gen: gen)
                    self.receive(task, gen: gen)
                }
            }
        }
    }

    private func handle(_ data: Data, task: URLSessionWebSocketTask, gen: Int) {
        lastHeard = Date()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let op = obj["op"] as? String else { return }
        switch op {
        case "hello":
            guard !authenticated, !helloAnswered, let nonceS = obj["nonce"] as? String, let nonce = B64.decode(nonceS) else { return }
            if route == .direct, obj["broker"] as? String != brokerID {
                retry(gen: gen) // another device answers at this address
                return
            }
            let now = Int64(Date().timeIntervalSince1970)
            let env: Envelope?
            switch route {
            case .direct:
                env = try? Envelope.sign(HelloAuth(broker: brokerID, approver: approverID, nonce: nonce, issued: now),
                                         type: "hello", with: transport)
            case .relay:
                env = try? Envelope.sign(RelayAuth(role: "approver", broker: brokerID, approver: approverID, endpoint: "socket",
                                                   nonce: nonce, issued: now), type: "relay", with: transport)
            }
            guard let env, let envJSON = try? JSONSerialization.jsonObject(with: Wire.encoder.encode(env)),
                  let msg = try? JSONSerialization.data(withJSONObject: ["op": "auth", "auth": envJSON]) else { return }
            task.send(.string(String(decoding: msg, as: UTF8.self))) { _ in }
            helloAnswered = true
        case "ready":
            // The other end took the login: from now on boxes go through.
            guard helloAnswered, !authenticated else { return }
            authenticated = true
            backoff = 1
            onState(true)
            startPings(task)
        case "box":
            guard authenticated, let s = obj["box"] as? String, let box = B64.decode(s) else { return }
            onBox(box)
        default:
            break
        }
    }

    private func startPings(_ task: URLSessionWebSocketTask) {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 20, repeating: 20)
        let gen = generation
        lastHeard = Date()
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Pings get pongs: silence means the socket is gone (asleep, a
            // network change) though it looks open.
            if Date().timeIntervalSince(self.lastHeard) > Self.silence { return self.retry(gen: gen) }
            task.send(.string("{\"op\":\"ping\"}")) { _ in }
        }
        timer.resume()
        pingTimer = timer
    }
}

/// The relay's HTTP endpoints, for a phone (it has no open socket).
public struct RelayHTTP: Sendable {
    public let base: URL
    public let brokerID: String

    public init(base: URL, brokerID: String) { self.base = base; self.brokerID = brokerID }

    private func url(_ endpoint: String) -> URL {
        base.appendingPathComponent("v1/b/\(brokerID)/\(endpoint)")
    }

    private func post(_ endpoint: String, body: Data) async throws -> Data {
        var req = URLRequest(url: url(endpoint))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WireError.invalid("relay \(endpoint): \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }

    private func signed(_ endpoint: String, approver: String, transport: EnvelopeSigner, box: Data? = nil,
                        apns: APNsRegistration? = nil, ack: Int64? = nil) async throws -> Data {
        let auth = RelayAuth(role: "approver", broker: brokerID, approver: approver, endpoint: endpoint,
                             nonce: Wire.randomBytes(32), issued: Int64(Date().timeIntervalSince1970), box: box, apns: apns, ack: ack)
        return try await post(endpoint, body: Wire.encoder.encode(try Envelope.sign(auth, type: "relay", with: transport)))
    }

    /// Sends a box to the broker.
    public func send(box: Data, approver: String, transport: EnvelopeSigner) async throws {
        _ = try await signed("inbox", approver: approver, transport: transport, box: box)
    }

    /// Registers this phone's APNs token.
    public func register(token: String, env: String, approver: String, transport: EnvelopeSigner) async throws {
        _ = try await signed("devices", approver: approver, transport: transport, apns: APNsRegistration(token: token, env: env))
    }

    /// Takes this phone's tokens (or one) off the relay: it gets no more
    /// pushes from this broker.
    public func unregister(token: String? = nil, approver: String, transport: EnvelopeSigner) async throws {
        _ = try await signed("devices", approver: approver, transport: transport, apns: APNsRegistration(removing: token))
    }

    /// Fetches what the broker queued for this approver after `ack` (the
    /// last box taken before; 0 for none): the relay keeps boxes until a
    /// later fetch acknowledges them, so a lost answer loses nothing.
    public func outbox(approver: String, transport: EnvelopeSigner, ack: Int64) async throws -> (boxes: [Data], last: Int64) {
        let data = try await signed("outbox", approver: approver, transport: transport, ack: ack)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let boxes = (obj?["boxes"] as? [String] ?? []).compactMap(B64.decode)
        return (boxes, (obj?["last"] as? NSNumber)?.int64Value ?? ack)
    }

    /// Sends a not-yet-approver's enrollment for the pairing (the hash of
    /// the QR code's token) the broker announced to the relay.
    public func enroll(box: Data, pairing: Data) async throws {
        _ = try await post("enroll", body: JSONSerialization.data(withJSONObject: ["box": B64.encode(box), "pairing": B64.encode(pairing)]))
    }
}
