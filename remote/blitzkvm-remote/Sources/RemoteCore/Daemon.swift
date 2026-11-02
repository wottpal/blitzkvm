import ApprovalKit
import Darwin
import Foundation
import SystemConfiguration

/// The target daemon (root): holds the target key and the roster, keeps the
/// link to the broker, serves requesters and the agent on the local socket,
/// signs asks, checks every decision itself, and drives the screen for
/// approved screen asks. All state lives on `queue`.
public final class Daemon {
    /// How long an ask waits for an approver: the protocol's most, so a
    /// phone that rings a while later can still answer. A 1Password prompt
    /// closes by itself after about a minute; its ask lives as long.
    public static let askLifetime = Limits.maxAskLifetime
    public static let onePasswordLifetime: Int64 = 60

    public struct Config {
        public var paths: Paths
        /// nil: the JetKVM's link-local address from link.json.
        public var endpoint: HostLink.Endpoint?
        public var userMode = false
        public var linkTuning = LinkClient.Tuning()
        public var pollInterval: TimeInterval = 0.5
        public var clock: () -> Int64 = { Int64(Date().timeIntervalSince1970) }
        public var processes: ProcessInspector = SystemProcesses()
        public var console: () -> ConsoleState = Console.read
        /// What an agent's signature must satisfy (the daemon's own Team ID
        /// and the remote's identifier); without one no agent is trusted
        /// and screen asks are unavailable ...
        public var agentRequirement: String?
        /// ... unless this is set (--insecure-agent, for tests): then any
        /// agent is taken at its word.
        public var insecureAgent = false
        /// Local clients at once (root's don't count), and how long one may
        /// stay without saying what it wants.
        public var maxClients = 32
        public var requestTimeout: TimeInterval = 5
        // SCDynamicStore, not Host: Host's name can wait seconds on reverse DNS.
        public var computerName = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "this Mac"
        public var driverTuning = ScreenDriver.Tuning()

        public init(paths: Paths) { self.paths = paths }
    }

    /// Open requester asks per user, and asks per user a minute: each costs
    /// approvers a notification (and the relay's push budget).
    static let openPerUser = 3
    static let asksPerMinute = 8

    public let queue = DispatchQueue(label: "xyz.scio.blitzkvm.remote.daemon")
    let config: Config
    let store: TargetStore
    let signer: SoftwareSigner
    var roster: (roster: Roster, envelope: Envelope)?
    /// Unlock requests seen (nonce -> until) and each approver's last one.
    var unlockNonces: [Data: Int64] = [:]
    var lastUnlock: [String: Int64] = [:]
    var link: LinkClient!
    var listener: Int32 = -1
    var clients: [ObjectIdentifier: Client] = [:]
    var agent: Client?
    var facts: AgentFacts?
    var refreshSeq = 0
    var refreshWaiters: [Int: () -> Void] = [:]
    var pending: [String: PendingAsk] = [:]
    var grants = Grants()
    var seenPrompts: Set<Int> = []
    var raisedHolder: Int32?
    var stepSeq = 0
    var stepWaiters: [String: (StepOutcome) -> Void] = [:]
    var identities: [Int32: (start: Double, identity: CodeIdentity?)] = [:]
    var pollTimer: DispatchSourceTimer?
    var refusedClients = false
    /// Recent asks per user (Unix seconds), for asksPerMinute.
    var askTimes: [uid_t: [Int64]] = [:]
    var lastAgentRefusal: Int64 = 0
    /// Screen drivers run one at a time: two approvals never drive the
    /// keyboard at once.
    let drivers = DispatchQueue(label: "xyz.scio.blitzkvm.remote.drivers")

    public init(config: Config) throws {
        self.config = config
        store = TargetStore(paths: config.paths)
        signer = try store.loadOrCreateKey()
        roster = store.loadRoster()
    }

    public var targetID: String { signer.id }

    public func start() throws {
        try store.makeStateDir()
        listener = try Sockets.listenUnix(path: config.paths.socket)
        let endpoint = config.endpoint ?? .link(store.loadLink() ?? HostLink.Config(address: ""))
        if config.endpoint == nil, store.loadLink() == nil { Log.info("no link.json: the installer writes it") }
        link = LinkClient(endpoint: endpoint, signer: signer, queue: queue, tuning: config.linkTuning, clock: config.clock) {
            [weak self] in self?.roster?.roster.broker.id
        }
        link.onReady = { [weak self] in self?.linkReady(roster: $0) }
        link.onMessage = { [weak self] in self?.handleLink($0) }
        link.onDown = { [weak self] in self?.linkDown() }
        link.start()
        let fd = listener
        let t = Thread { [weak self] in
            while let c = Sockets.accept(fd) { self?.queue.async { self?.accepted(c) } }
        }
        t.name = "local socket"
        t.start()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + config.pollInterval, repeating: config.pollInterval)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        pollTimer = timer
        if !config.userMode { Log.boundStderr() }
        Log.info("daemon: target \(signer.id), socket \(config.paths.socket)" + (roster == nil ? ", no roster yet" : ""))
    }

    public func stop() {
        queue.sync {
            pollTimer?.cancel()
            link?.stop()
            for c in clients.values { c.conn.close() }
        }
        shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        unlink(config.paths.socket)
    }

    func now() -> Int64 { config.clock() }

    // MARK: Roster

    func linkReady(roster env: Envelope?) {
        guard let env else { return }
        guard let mine = roster else { return }
        let theirs = try? env.peek(Roster.self)
        if let theirs, theirs.seq < mine.roster.seq {
            // The broker lost a newer roster: hand it ours.
            link.send(LinkMessage(op: "roster", roster: mine.envelope))
        } else if let theirs, theirs.seq > mine.roster.seq {
            accept(roster: env)
        }
    }

    func accept(roster env: Envelope?) {
        guard let env else { return }
        do {
            let next = try Roster.accept(env, current: roster?.roster)
            try store.saveRoster(env)
            roster = (next, env)
            // A revoked approver's grants end with it.
            grants.keep(approvers: Set(next.approvers.map(\.id)))
            Log.info("roster \(next.seq): \(next.approvers.count) approvers")
            if next.target(signer.id) == nil { Log.info("the new roster doesn't name this target") }
        } catch WireError.roster("stale") {
        } catch {
            Log.info("roster refused: \(error)")
        }
    }

    // MARK: Link

    func handleLink(_ m: LinkMessage) {
        switch m.op {
        case "request": takeRequest(m.request)
        case "rejected":
            if let id = m.id, let p = pending[id] {
                finish(p, .unavailable, "BlitzKVM: the JetKVM refused the request (\(Display.safe(m.reason ?? "no reason", maxBytes: 200)))")
            }
        case "decision": takeDecision(id: m.id, env: m.decision)
        case "roster": accept(roster: m.roster)
        case "unlock": takeUnlock(m.unlock)
        case "stepped":
            guard let id = m.id, let seq = m.seq, let waiter = stepWaiters.removeValue(forKey: "\(id)#\(seq)") else { return }
            waiter(StepOutcome(ok: m.ok == true, error: m.error.map { Display.safe($0, maxBytes: 200) }, typed: m.typed))
        default: break
        }
    }

    func linkDown() {
        for (_, waiter) in stepWaiters { waiter(.failed("the link went down")) }
        stepWaiters.removeAll()
        // The broker cancels a gone target's requests.
        for p in pending.values where p.client != nil {
            finish(p, .unavailable, "BlitzKVM: the JetKVM's link went down")
        }
        pending = pending.filter { $0.value.driving }
        // The broker cancelled the screen asks too: raise them again once
        // the link is back, if their prompts are still there.
        seenPrompts.removeAll()
        raisedHolder = nil
    }

    func takeRequest(_ env: Envelope?) {
        guard let env, let roster = roster?.roster else { return }
        guard let peek = try? env.peek(Request.self), let askID = try? peek.ask.peek(Ask.self).id,
              let p = pending[askID], p.request == nil else { return }
        do {
            let req = try VerifiedRequest(env, roster: roster, now: now())
            // The broker must offer exactly the ask this daemon signed.
            guard req.request.ask == p.envelope else { throw WireError.mismatch }
            p.request = req
        } catch {
            Log.info("request \(askID) refused: \(error)")
        }
    }

    func takeDecision(id: String?, env: Envelope?) {
        guard let id, let env, let p = pending[id], let req = p.request, !p.decided, let roster = roster?.roster else { return }
        let d: Decision
        do {
            d = try req.verify(decision: env, roster: roster, now: now())
        } catch {
            Log.info("decision for \(id) refused: \(error)")
            return
        }
        p.decided = true
        let by = Display.safe(roster.approver(d.approver)?.name ?? d.approver, maxBytes: 100)
        guard d.decision == DecisionValue.approve else {
            Log.info("\(p.ask.kind) \(id) denied by \(by)")
            return finish(p, .denied, "BlitzKVM: denied on \(by)")
        }
        Log.info("\(p.ask.kind) \(id) approved by \(by)")
        if Kind.isTyping(p.ask.kind) {
            p.plan?.hasSecret = d.secret != nil
            return drive(p)
        }
        var note = "BlitzKVM: approved on \(by)"
        if d.grant == Limits.grantMinutes, let key = p.grantKey {
            grants.add(key, minutes: Limits.grantMinutes, now: Double(now()), by: d.approver)
            note += " (and for \(Limits.grantMinutes) minutes from \(key.anchor.name))"
        }
        finish(p, .approved, note)
    }

    // MARK: Asks

    /// Signs an ask and offers it; nil when it can't go out.
    func send(kind: String, title: String, detail: String?, requester: Requester?, evidence: Evidence? = nil,
              secret: String = SecretKind.none, grantable: Bool = false, requestedBy: String? = nil,
              lifetime: Int64 = Daemon.askLifetime) -> PendingAsk? {
        guard roster != nil, link.isReady else { return nil }
        let ask = Ask(target: signer.id, kind: kind, title: title.clipped(bytes: Limits.maxText),
                      detail: detail?.clipped(bytes: Limits.maxText),
                      requester: requester, evidence: evidence, secret: secret, grantable: grantable,
                      requestedBy: requestedBy, issued: now(), lifetime: lifetime)
        guard let env = try? Envelope.sign(ask, type: "ask", with: signer), link.send(LinkMessage(op: "ask", ask: env)) else {
            return nil
        }
        let p = PendingAsk(ask: ask, envelope: env)
        pending[ask.id] = p
        // Nobody answered: the broker expires it at the same time.
        let expiry = DispatchWorkItem { [weak self, weak p] in
            guard let self, let p, self.pending[p.ask.id] === p, !p.driving else { return }
            self.link.send(LinkMessage(op: "cancel", id: p.ask.id))
            self.finish(p, .timeout, "BlitzKVM: nobody answered in time")
        }
        p.expiry = expiry
        queue.asyncAfter(deadline: .now() + .seconds(Int(lifetime) + 2), execute: expiry)
        // The title stays out of the log: a command line may carry a secret.
        Log.info("asked \(kind) \(ask.id)")
        return p
    }

    func finish(_ p: PendingAsk, _ outcome: Outcome, _ text: String) {
        p.expiry?.cancel()
        if pending[p.ask.id] === p { pending[p.ask.id] = nil }
        guard let c = p.client else { return }
        p.client = nil
        c.reply(text: text, outcome: outcome)
    }
}

/// One ask the daemon signed, until it ends.
final class PendingAsk {
    let ask: Ask
    let envelope: Envelope
    let code: String
    var client: Client?
    var requesterUID: uid_t?
    var request: VerifiedRequest?
    var grantKey: Grants.Key?
    var decided = false
    var driving = false
    var plan: ScreenPlan?
    var missingPolls = 0
    var expiry: DispatchWorkItem?

    init(ask: Ask, envelope: Envelope) {
        self.ask = ask
        self.envelope = envelope
        code = Wire.code(askDigest: envelope.digest)
    }
}
