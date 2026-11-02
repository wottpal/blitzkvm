import ApprovalKit
import Foundation

/// Screen asks: raised from what the daemon reads itself (secure input and
/// the lock, by signature) and what the agent reports (prompt windows,
/// whose owners the daemon checks by signature), and acted on with steps.
extension Daemon {
    /// A process's signature, cached per pid and start time.
    func identity(_ pid: Int32) -> CodeIdentity? {
        guard let info = config.processes.info(pid) else { return nil }
        if let cached = identities[pid], cached.start == info.start { return cached.identity }
        if identities.count > 64 { identities.removeAll() }
        let id = config.processes.identity(pid)
        identities[pid] = (info.start, id)
        return id
    }

    func isOnePassword(_ pid: Int32) -> Bool {
        identity(pid)?.isDeveloper(team: OnePassword.team, identifier: OnePassword.bundle) == true
    }

    func evidence() -> ScreenEvidence {
        let console = config.console()
        return ScreenEvidence(console: console, holder: console.secureInputPID.flatMap(identity), facts: facts)
    }

    func poll() {
        let console = config.console()
        // Fast user switching: only the console user's agent tells the truth.
        if !config.userMode, let agent, let uid = console.uid, agent.peer.uid != uid {
            Log.info("agent of uid \(agent.peer.uid) dropped: uid \(uid) has the console")
            agent.conn.close()
        }
        withdrawVanished(console)
        guard roster != nil, link.isReady else { return }
        pollOnePassword(console)
        pollSecurityAgent(console)
    }

    // MARK: Raising

    func pollOnePassword(_ console: ConsoleState) {
        guard let facts, let display = facts.display else { return }
        let prompts = OnePassword.prompts(in: facts, isOnePassword: isOnePassword)
        seenPrompts.formIntersection(prompts.map(\.number))
        // A prompt behind the lock screen can't be clicked: wait for unlock.
        guard !console.locked else { return }
        for prompt in prompts where !seenPrompts.contains(prompt.number) {
            // Which process asked, 1Password doesn't tell: the newest op
            // run from a shell is a guess, and the ask says so (no
            // requester field, which would read as fact).
            // Which prompt it is (the CLI's, the SSH agent's, another app's)
            // the window doesn't say without screen recording.
            var detail = "A 1Password prompt is on the screen (for the CLI, the SSH agent or another app)."
            if let chain = requestingOp() {
                let args = chain.first?.process.args ?? []
                let command = args.isEmpty ? chain.first?.name ?? "op" : Display.command(args, maxBytes: 512)
                detail += "\nProbably requested by: \(command), as it says itself (\(Chain.summary(chain)))"
            }
            let previous = facts.frontmost?.bundle == OnePassword.bundle ? nil : facts.frontmost
            // The master password only for the locked prompt: an unlocked one
            // takes a click, and the password never leaves the approver.
            let locked = OnePassword.isLocked(prompt)
            guard let p = send(kind: Kind.onePassword, title: "1Password access requested", detail: detail, requester: nil,
                               evidence: Evidence(locked: false, window: prompt.rect, display: display),
                               secret: locked ? SecretKind.onePassword : SecretKind.none,
                               lifetime: Daemon.onePasswordLifetime) else { return }
            p.plan = ScreenPlan(kind: Kind.onePassword, window: prompt, display: display, previousApp: previous,
                                consoleUID: console.uid)
            seenPrompts.insert(prompt.number)
        }
    }

    /// The `op` process probably behind a 1Password prompt: the newest one
    /// run from a shell. A guess, for the approver's information only.
    func requestingOp() -> [ChainEntry]? {
        // 1Password's own op only: any process can call itself op.
        let ops = config.processes.all().filter { $0.comm == "op" && identity($0.pid)?.team == OnePassword.team }
            .sorted { $0.start > $1.start }
        for op in ops {
            let chain = Chain.build(from: op.pid, inspector: config.processes)
            if Chain.reachesShell(chain) { return chain }
        }
        return nil
    }

    func pollSecurityAgent(_ console: ConsoleState) {
        guard let pid = console.secureInputPID, !console.locked else {
            raisedHolder = nil
            return
        }
        guard raisedHolder != pid, let holder = identity(pid), holder.isApple(Holders.securityAgent),
              !pending.values.contains(where: { $0.ask.kind == Kind.securityAgent && $0.plan?.holderPID == pid }) else { return }
        // The dialog it is: with two dialogs of the same process, a
        // password approved for one could go into the other.
        let dialogs = facts.map { PasswordDialog.windows(in: $0, pid: pid) } ?? []
        guard dialogs.count <= 1 else {
            if raisedHolder != pid { Log.info("securityagent: \(dialogs.count) dialogs at once; asking for none") }
            raisedHolder = pid
            return
        }
        // Only what root verified: which app opened the dialog isn't known;
        // the app in front is a hint, and the ask says so.
        var detail = "A macOS password dialog (\(Display.safe(holder.identifier ?? "SecurityAgent", maxBytes: 128))) has the keyboard."
        if let front = facts?.frontmost?.name {
            detail += "\nIn front when it came up: \(Display.safe(front, maxBytes: 128)). Approve only if you started what asks."
        }
        guard let p = send(kind: Kind.securityAgent, title: "macOS asks for your password", detail: detail, requester: nil,
                           evidence: Evidence(locked: false, secureInput: SecureInput(pid: Int(pid), bundle: holder.identifier ?? "",
                                                                                      team: nil), display: facts?.display),
                           secret: SecretKind.mac) else { return }
        p.plan = ScreenPlan(kind: Kind.securityAgent, window: dialogs.first, holderPID: pid, consoleUID: console.uid)
        raisedHolder = pid
    }

    /// An approver asked to unlock. Only a request it signed (its transport
    /// key, checked against this daemon's own roster, fresh, once, and not
    /// more than every 30 s per approver) raises an ask: the relay and the
    /// JetKVM can't make a locked Mac ask for its password.
    func takeUnlock(_ env: Envelope?) {
        guard let env, let roster = roster?.roster else { return Log.info("unlock asked without a signed request") }
        let request: UnlockRequest
        do {
            request = try UnlockRequest.verify(env, roster: roster, target: signer.id, now: now())
        } catch {
            return Log.info("unlock request refused: \(error)")
        }
        let t = now()
        unlockNonces = unlockNonces.filter { $0.value > t }
        guard unlockNonces[request.nonce.data] == nil else { return Log.info("unlock request replayed") }
        unlockNonces[request.nonce.data] = t + 2 * Limits.clockSkew
        if let last = lastUnlock[request.approver], t - last < Self.unlockCooldown {
            return Log.info("unlock asked again within \(Self.unlockCooldown) s")
        }
        if raiseUnlock(by: request.approver) { lastUnlock[request.approver] = t }
    }

    static let unlockCooldown: Int64 = 30

    /// Raises the unlock ask: only on a locked screen whose keyboard (if
    /// anyone's) is the login window's.
    @discardableResult
    func raiseUnlock(by approver: String) -> Bool {
        let console = config.console()
        guard console.locked else { Log.info("unlock asked, but the screen isn't locked"); return false }
        var secureInput: SecureInput?
        if let pid = console.secureInputPID {
            guard identity(pid)?.isApple(Holders.loginWindow) == true else {
                Log.info("unlock asked, but another process (pid \(pid)) has the keyboard")
                return false
            }
            secureInput = SecureInput(pid: Int(pid), bundle: "com.apple.loginwindow", team: nil)
        }
        guard !pending.values.contains(where: { $0.ask.kind == Kind.unlock }) else { return false }
        let name = roster?.roster.approver(approver)?.name ?? approver
        guard let p = send(kind: Kind.unlock, title: "Unlock \(Display.safe(config.computerName, maxBytes: 256))",
                           detail: "Requested by \(Display.safe(name, maxBytes: 256))", requester: nil,
                           evidence: Evidence(locked: true, secureInput: secureInput, display: facts?.display),
                           secret: SecretKind.mac, requestedBy: approver) else {
            Log.info("unlock asked, but the ask can't go out")
            return false
        }
        p.plan = ScreenPlan(kind: Kind.unlock, consoleUID: console.uid)
        return true
    }

    /// Withdraws an undecided screen ask whose prompt has been gone for 2 s
    /// (dismissed by hand, or answered at the keyboard).
    func withdrawVanished(_ console: ConsoleState) {
        for p in pending.values where !p.decided && p.plan != nil {
            let gone: Bool
            switch p.ask.kind {
            case Kind.onePassword:
                gone = facts.map { f in !f.windows.contains { $0.number == p.plan?.window?.number } } ?? false
            case Kind.securityAgent:
                let dialogGone = p.plan?.window.map { w in facts.map { !$0.windows.contains { $0.number == w.number } } ?? false } ?? false
                gone = console.secureInputPID != p.plan?.holderPID || dialogGone
            case Kind.unlock: gone = !console.locked
            default: gone = false
            }
            p.missingPolls = gone ? p.missingPolls + 1 : 0
            if p.missingPolls >= 4 {
                link.send(LinkMessage(op: "cancel", id: p.ask.id))
                finish(p, .unavailable, "")
                Log.info("\(p.ask.kind) \(p.ask.id) withdrawn: it left the screen")
            }
        }
    }

    // MARK: Acting

    func drive(_ p: PendingAsk) {
        guard let plan = p.plan else { return }
        p.driving = true
        p.expiry?.cancel()
        let io = DaemonScreenIO(daemon: self, id: p.ask.id)
        let tuning = config.driverTuning
        // One driver at a time.
        drivers.async { [weak self] in
            let (ok, note) = ScreenDriver(io: io, plan: plan, tuning: tuning).run()
            self?.queue.async {
                guard let self else { return }
                Log.info("\(plan.kind) \(p.ask.id) \(ok ? "done" : "failed"): \(note)")
                self.link.send(LinkMessage(op: "done", id: p.ask.id, ok: ok, note: note))
                if self.pending[p.ask.id] === p { self.pending[p.ask.id] = nil }
            }
        }
    }
}

/// The driver's IO through the daemon: evidence from the console and the
/// agent, steps over the link (blocking the driver's thread, not the queue).
final class DaemonScreenIO: ScreenIO {
    private weak var daemon: Daemon?
    private let id: String
    private let lock = NSLock()
    private var outcomes: [Int: StepOutcome] = [:]
    private var signals: [Int: DispatchSemaphore] = [:]

    init(daemon: Daemon, id: String) { self.daemon = daemon; self.id = id }

    func liveConsole() -> ConsoleState { daemon?.config.console() ?? ConsoleState() }

    /// Straight onto the link, not through the daemon's queue: whatever
    /// waits there mustn't delay an abort while a password is typed.
    func abort() {
        guard let daemon else { return }
        _ = daemon.link.sendNow(LinkMessage(op: "abort", id: id))
    }

    func evidence() -> ScreenEvidence {
        guard let daemon else { return ScreenEvidence(console: ConsoleState()) }
        let fresh = DispatchSemaphore(value: 0)
        daemon.queue.async { daemon.refreshFacts { fresh.signal() } }
        let answered = fresh.wait(timeout: .now() + 0.5) == .success
        var ev = daemon.queue.sync { daemon.evidence() }
        ev.fresh = answered && daemon.queue.sync { daemon.agent != nil }
        return ev
    }

    func start(_ step: Step) -> Int {
        guard let daemon else { return -1 }
        let sem = DispatchSemaphore(value: 0)
        let seq: Int = daemon.queue.sync {
            daemon.stepSeq += 1
            let seq = daemon.stepSeq
            lock.lock(); signals[seq] = sem; lock.unlock()
            let done: (StepOutcome) -> Void = { [weak self] outcome in
                guard let self else { return }
                self.lock.lock(); self.outcomes[seq] = outcome; self.lock.unlock()
                sem.signal()
            }
            if daemon.link.send(LinkMessage(op: "step", id: id, seq: seq, step: step)) {
                daemon.stepWaiters["\(id)#\(seq)"] = done
            } else {
                done(.failed("the link is down"))
            }
            return seq
        }
        return seq
    }

    func wait(_ ticket: Int, timeout: TimeInterval) -> StepOutcome? {
        lock.lock()
        let sem = signals[ticket]
        let ready = outcomes[ticket]
        lock.unlock()
        if let ready { return ready }
        guard let sem, sem.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return outcomes[ticket]
    }

    func activate(_ app: AppRef) {
        guard let daemon else { return }
        daemon.queue.async { daemon.agent?.conn.send(LocalMessage(op: "activate", app: app)) }
    }

    func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }
}
