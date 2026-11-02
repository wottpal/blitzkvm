import ApprovalKit
import Foundation

/// One connection on the local socket and who the kernel says it is.
final class Client {
    let conn: LineConn
    let peer: PeerCredentials
    var isAgent = false
    var askID: String?
    var said = false

    init(conn: LineConn, peer: PeerCredentials) { self.conn = conn; self.peer = peer }

    func info(_ text: String) { conn.send(LocalMessage(op: "info", text: Display.safe(text, maxBytes: 1024))) }

    func reply(text: String, outcome: Outcome) {
        conn.send(LocalMessage(op: "result", text: Display.safe(text, maxBytes: 1024), result: outcome.rawValue))
        conn.close()
    }
}

extension Daemon {
    func accepted(_ fd: Int32) {
        guard let peer = PeerCredentials.of(fd) else {
            Darwin.close(fd)
            return
        }
        // Each client is a thread: users get a bounded number (root, the
        // PAM module's client, always gets through).
        guard peer.uid == 0 || clients.values.filter({ $0.peer.uid != 0 }).count < config.maxClients else {
            Darwin.close(fd)
            if !refusedClients { Log.info("refusing local clients: \(config.maxClients) already connected") }
            refusedClients = true
            return
        }
        refusedClients = false
        let c = Client(conn: LineConn(fd: fd, queue: queue), peer: peer)
        let key = ObjectIdentifier(c)
        clients[key] = c
        queue.asyncAfter(deadline: .now() + config.requestTimeout) { [weak c] in
            if let c, !c.said { c.conn.close() }
        }
        c.conn.start(onLine: { [weak self, weak c] data in
            guard let self, let c else { return }
            guard let m = try? JSONDecoder().decode(LocalMessage.self, from: data) else { return c.conn.close() }
            self.handleLocal(c, m)
        }, onClose: { [weak self] in
            guard let self, let c = self.clients.removeValue(forKey: key) else { return }
            self.clientGone(c)
        })
    }

    func clientGone(_ c: Client) {
        if agent === c {
            agent = nil
            facts = nil
            let waiters = refreshWaiters.values
            refreshWaiters.removeAll()
            waiters.forEach { $0() }
            Log.info("agent gone")
        }
        if let id = c.askID, let p = pending[id], p.client === c {
            // The requester went away (Ctrl-C on sudo): withdraw the ask.
            p.client = nil
            p.expiry?.cancel()
            pending[id] = nil
            link.send(LinkMessage(op: "cancel", id: id))
            Log.info("\(p.ask.kind) \(id) cancelled: the requester went away")
        }
    }

    func handleLocal(_ c: Client, _ m: LocalMessage) {
        if c.isAgent {
            switch m.op {
            case "facts":
                var f = m.facts
                if let map = f?.keyMap, !KeyLayout.isValid(map) {
                    // The broker would refuse it; never send it.
                    Log.info("the agent's key map has strokes that type no character: ignoring it")
                    f?.keyMap = nil
                }
                facts = f
                if let seq = m.seq, let waiter = refreshWaiters.removeValue(forKey: seq) { waiter() }
            default: break
            }
            return
        }
        // A requester says one thing; a second line ends it (lines would
        // otherwise queue up work ahead of the screen drivers' aborts).
        guard !c.said else { return c.conn.close() }
        c.said = true
        switch m.op {
        case "confirm": confirm(c, m)
        case "pam": pam(c, m)
        case "agent": attachAgent(c)
        default: c.conn.close()
        }
    }

    // MARK: Requesters

    func confirm(_ c: Client, _ m: LocalMessage) {
        guard let title = m.title, !title.isEmpty else {
            return c.reply(text: "BlitzKVM: confirm needs a question", outcome: .refused)
        }
        // Cheap checks first: the chain and its signatures cost the queue.
        guard mayAsk(uid: c.peer.uid) else {
            return c.reply(text: "BlitzKVM: too many requests", outcome: .unavailable)
        }
        let chain = Chain.build(from: c.peer.pid, inspector: config.processes)
        let tty = chain.first?.tty
        let requester = Requester(uid: Int(c.peer.uid), user: Processes.userName(c.peer.uid), tty: tty,
                                  chain: chain.map(\.process))
        let lifetime = Int64(min(max(m.timeout ?? Int(Daemon.askLifetime), 10), Int(Limits.maxAskLifetime)))
        ask(for: c, kind: Kind.confirm, title: Display.safe(title, maxBytes: Limits.maxText),
            detail: m.detail.map { Display.safe($0, maxBytes: Limits.maxText) }, requester: requester, chain: chain,
            uid: c.peer.uid, tty: tty, grantable: m.grant == true, lifetime: lifetime)
    }

    /// sudo, through the PAM module: only root's word counts for the pid.
    func pam(_ c: Client, _ m: LocalMessage) {
        guard c.peer.uid == 0 else {
            Log.info("refused a sudo request from uid \(c.peer.uid): only root's PAM module may ask")
            return c.reply(text: "BlitzKVM: only the PAM module may ask for sudo", outcome: .refused)
        }
        guard let pid = m.pid, pid > 1, let sudo = config.processes.info(pid) else {
            return c.reply(text: "BlitzKVM: no such process", outcome: .refused)
        }
        // sudo's real uid may be root's while PAM runs: the user is PAM's.
        let uid = m.user.flatMap { getpwnam($0)?.pointee.pw_uid } ?? sudo.uid
        guard mayAsk(uid: uid) else {
            return c.reply(text: "BlitzKVM: too many requests", outcome: .unavailable)
        }
        let chain = Chain.build(from: pid, inspector: config.processes)
        let args = config.processes.args(pid) ?? []
        let command = Display.command(["sudo"] + args.dropFirst(), maxBytes: Limits.maxText)
        var detail = "Run by \(Chain.summary(chain))"
        if let cwd = config.processes.cwd(chain.dropFirst().first?.pid ?? pid) { detail += "\nin \(Display.safe(cwd, maxBytes: 1024))" }
        let user = Display.safe(m.user ?? Processes.userName(uid), maxBytes: 256)
        let given = m.tty?.replacingOccurrences(of: "/dev/", with: "")
        let tty = (given?.isEmpty == false ? given : nil).map { Display.safe($0, maxBytes: 64) } ?? sudo.tty
        let requester = Requester(uid: Int(uid), user: user, tty: tty, chain: chain.map(\.process))
        ask(for: c, kind: Kind.sudo, title: command, detail: detail, requester: requester, chain: chain, uid: uid,
            tty: tty, grantable: true, lifetime: Daemon.askLifetime)
    }

    /// A user may ask fewer than asksPerMinute times a minute (open asks
    /// are capped in ask()).
    func mayAsk(uid: uid_t) -> Bool {
        let t = now()
        let recent = (askTimes[uid] ?? []).filter { t - $0 < 60 }
        askTimes[uid] = recent
        if askTimes.count > 64 { askTimes = askTimes.filter { !$0.value.isEmpty } }
        guard recent.count < Daemon.asksPerMinute else { return false }
        askTimes[uid, default: []].append(t)
        return true
    }

    /// `title` and `detail` are display-safe already.
    func ask(for c: Client, kind: String, title: String, detail: String?, requester: Requester, chain: [ChainEntry],
             uid: uid_t, tty: String?, grantable: Bool, lifetime: Int64) {
        // The requester's audit session: the PAM client's is sudo's.
        let key = Chain.anchor(chain).map { Grants.Key(kind: kind, uid: uid, anchor: $0, tty: tty, session: c.peer.session) }
        if let key, grants.covers(key, now: Double(now())) {
            Log.info("\(kind) for uid \(uid) under \(key.anchor.name) approved by an earlier grant: \(title)")
            return c.reply(text: "BlitzKVM: approved by an earlier grant", outcome: .approved)
        }
        guard roster != nil else {
            return c.reply(text: "BlitzKVM: approvals aren't set up on this Mac", outcome: .unavailable)
        }
        // The broker holds 8 open requests: one user's flood mustn't crowd
        // out everyone else's sudo.
        guard pending.values.filter({ $0.requesterUID == uid }).count < Daemon.openPerUser else {
            return c.reply(text: "BlitzKVM: too many open requests", outcome: .unavailable)
        }
        guard let p = send(kind: kind, title: title, detail: detail, requester: requester,
                           grantable: grantable && key != nil, lifetime: lifetime) else {
            return c.reply(text: "BlitzKVM: the JetKVM isn't connected", outcome: .unavailable)
        }
        p.client = c
        p.requesterUID = uid
        p.grantKey = key
        c.askID = p.ask.id
        c.info("BlitzKVM: approve on your iPhone or Mac (code \(p.code))…")
    }

    // MARK: Agent

    /// The agent's word drives clicks: only a signed one counts.
    func attachAgent(_ c: Client) {
        if config.insecureAgent {
            Log.info("WARNING: --insecure-agent: took an agent (pid \(c.peer.pid)) without checking its signature")
        } else if let requirement = config.agentRequirement {
            guard let token = c.peer.auditToken, CodeSigning.satisfies(auditToken: token, requirement: requirement) else {
                Log.info("refused an agent (pid \(c.peer.pid)): its signature isn't the remote's")
                return c.conn.close()
            }
        } else {
            Log.info("refused an agent (pid \(c.peer.pid)): this daemon has no Developer ID to check it against, so screen asks are unavailable")
            return c.conn.close()
        }
        // The console user's agent only; at the login window, nobody's.
        if !config.userMode, config.console().uid != c.peer.uid {
            let t = now()
            if t - lastAgentRefusal >= 60 {
                lastAgentRefusal = t
                Log.info("refused an agent of uid \(c.peer.uid): \(config.console().uid.map { "uid \($0)" } ?? "nobody") has the console")
            }
            return c.conn.close()
        }
        if let old = agent, old !== c { old.conn.close() }
        c.isAgent = true
        agent = c
        Log.info("agent connected (uid \(c.peer.uid), pid \(c.peer.pid))")
    }

    /// Asks the agent for its facts now; `done` runs on `queue` once they
    /// came or there is no agent.
    func refreshFacts(_ done: @escaping () -> Void) {
        guard let agent else { return done() }
        refreshSeq += 1
        let seq = refreshSeq
        refreshWaiters[seq] = done
        if !agent.conn.send(LocalMessage(op: "refresh", seq: seq)) { refreshWaiters[seq] = nil; done() }
    }
}
