import ApprovalKit
import Foundation

/// What the daemon sees right now: root-read console state (secure input,
/// lock) with the signature of the secure-input holder, and the agent's
/// latest facts.
public struct ScreenEvidence {
    public var console: ConsoleState
    public var holder: CodeIdentity?
    public var facts: AgentFacts?
    /// The agent answered the refresh: its facts are from just now, not
    /// up to half a second old. A click needs this: on a prompt that went
    /// away meanwhile it would land on whatever lies beneath.
    public var fresh: Bool

    public init(console: ConsoleState, holder: CodeIdentity? = nil, facts: AgentFacts? = nil, fresh: Bool = true) {
        self.console = console; self.holder = holder; self.facts = facts; self.fresh = fresh
    }
}

/// The broker's `stepped`: for a secret step, `typed` counts the
/// characters fully typed, also when it failed or was aborted.
public struct StepOutcome: Equatable {
    public var ok: Bool
    public var error: String?
    public var typed: Int?

    public init(ok: Bool, error: String? = nil, typed: Int? = nil) { self.ok = ok; self.error = error; self.typed = typed }

    public static let ok = StepOutcome(ok: true)
    public static func failed(_ error: String, typed: Int? = nil) -> StepOutcome { StepOutcome(ok: false, error: error, typed: typed) }
}

/// The driver's hands and eyes: the daemon in production, a script in tests.
public protocol ScreenIO: AnyObject {
    /// Fresh evidence (the daemon asks the agent for its facts first).
    func evidence() -> ScreenEvidence
    /// The console as root reads it now, straight from the IORegistry:
    /// cheap enough to watch while a secret is typed.
    func liveConsole() -> ConsoleState
    /// Sends a step to the broker; the ticket waits for its `stepped`.
    func start(_ step: Step) -> Int
    /// The step's outcome, waiting at most `timeout`; nil while none came.
    func wait(_ ticket: Int, timeout: TimeInterval) -> StepOutcome?
    /// Has the broker stop this request's running step at once (`abort`).
    func abort()
    /// Brings an app back to the front (through the agent).
    func activate(_ app: AppRef)
    func pause(_ seconds: TimeInterval)
}

/// What an approved screen ask is about, from the evidence it was raised on.
public struct ScreenPlan {
    public var kind: String
    /// onepassword: the prompt and the display it was on.
    public var window: WindowFact?
    public var display: ApprovalKit.Size?
    /// securityagent: the dialog's process.
    public var holderPID: Int32?
    /// The approval carries a secret (its length isn't known: it is padded).
    public var hasSecret: Bool
    /// The app to bring back once 1Password took the front.
    public var previousApp: AppRef?

    public init(kind: String, window: WindowFact? = nil, display: ApprovalKit.Size? = nil, holderPID: Int32? = nil,
                hasSecret: Bool = false, previousApp: AppRef? = nil) {
        self.kind = kind; self.window = window; self.display = display; self.holderPID = holderPID
        self.hasSecret = hasSecret; self.previousApp = previousApp
    }
}

/// Acts on an approved screen ask, step by step. Before every step it
/// checks fresh evidence and gives up (`done` with ok false) if the screen
/// isn't what was approved; a secret goes only into a password field whose
/// holder it checked by signature. While the broker types, the driver
/// watches secure input itself every 20 ms and aborts the step the moment
/// the holder or the lock changes.
public final class ScreenDriver {
    public struct Tuning {
        public var poll: TimeInterval = 0.2
        public var watch: TimeInterval = 0.02
        public var promptGone: TimeInterval = 2
        public var accepted: TimeInterval = 5
        public var wake: TimeInterval = 3
        public var unlocked: TimeInterval = 10
        public var stepTimeout: TimeInterval = 25
        public init() {}
    }

    public struct Failure: Error, Equatable {
        public var note: String
        init(_ note: String) { self.note = note }
    }

    static let returnKey: Stroke = [0x28, 0], capsLock: Stroke = [0x39, 0], shiftTap: Stroke = [0, KeyLayout.shift]

    let io: ScreenIO
    let plan: ScreenPlan
    let tuning: Tuning

    public init(io: ScreenIO, plan: ScreenPlan, tuning: Tuning = Tuning()) {
        self.io = io; self.plan = plan; self.tuning = tuning
    }

    /// Runs the plan: (ok, note) for the broker's `done`.
    public func run() -> (ok: Bool, note: String) {
        do {
            switch plan.kind {
            case Kind.onePassword: return (true, try onePassword())
            case Kind.securityAgent: return (true, try securityAgent())
            case Kind.unlock: return (true, try unlock())
            default: return (false, "nothing to do on the screen for \(plan.kind)")
            }
        } catch let f as Failure {
            return (false, f.note)
        } catch {
            return (false, "\(error)")
        }
    }

    // MARK: Plans

    func onePassword() throws -> String {
        guard let window = plan.window, let display = plan.display else { throw Failure("no prompt to act on") }
        func prompt(_ ev: ScreenEvidence) -> WindowFact? { ev.facts?.windows.first { $0.number == window.number } }
        func holdsKeyboard(_ ev: ScreenEvidence) -> Bool {
            ev.console.secureInputPID == window.pid && ev.holder?.isDeveloper(team: OnePassword.team, identifier: OnePassword.bundle) == true
        }
        var clicked = false
        func click(_ inset: (x: Double, y: Double)) throws {
            let ev = io.evidence()
            guard !ev.console.locked else { throw Failure("the screen locked") }
            guard ev.fresh else { throw Failure("the agent didn't answer in time; nothing was clicked") }
            guard let now = prompt(ev), now.pid == window.pid, Self.same(now.rect, window.rect), ev.facts?.display == display else {
                throw Failure("the 1Password prompt changed or went away")
            }
            guard let point = OnePassword.buttonPoint(window: window.rect, display: display, inset: inset) else {
                throw Failure("the 1Password prompt isn't on the main display")
            }
            try step(Step(click: point))
            clicked = true
        }
        /// Tries the button's places in turn until the prompt goes or asks
        /// for the password; each click first checks the prompt is still
        /// there, unchanged.
        func clickButton() throws -> ScreenEvidence {
            var ev = io.evidence()
            for inset in OnePassword.buttonInsets {
                try click(inset)
                ev = waitUntil(tuning.promptGone) { prompt($0) == nil || holdsKeyboard($0) }
                if prompt(ev) == nil || holdsKeyboard(ev) { break }
            }
            return ev
        }

        // 1Password gets the front with the first click: whatever happens
        // after one, give it back.
        defer { if clicked, let app = plan.previousApp, app.bundle != OnePassword.bundle { io.activate(app) } }
        var ev = try clickButton()
        if prompt(ev) == nil { return "authorized" }
        guard holdsKeyboard(ev) else { throw Failure("the 1Password prompt is still there") }

        // 1Password is locked: its password field has the keyboard.
        guard plan.hasSecret else {
            throw Failure("1Password is locked; approve again with its password attached")
        }
        try typeSecret { holdsKeyboard($0) && !$0.console.locked }
        try press(Self.returnKey) { holdsKeyboard($0) }
        ev = waitUntil(tuning.accepted) { prompt($0) == nil || !holdsKeyboard($0) }
        if prompt(ev) == nil { return "unlocked 1Password and authorized" }
        guard !holdsKeyboard(ev) else { throw Failure("1Password didn't take the password") }
        // Unlocked, and the prompt still asks: authorize it.
        ev = try clickButton()
        guard prompt(ev) == nil else { throw Failure("the 1Password prompt is still there after unlocking") }
        return "unlocked 1Password and authorized"
    }

    func securityAgent() throws -> String {
        guard let pid = plan.holderPID else { throw Failure("no dialog to act on") }
        func holdsKeyboard(_ ev: ScreenEvidence) -> Bool {
            !ev.console.locked && ev.console.secureInputPID == pid && ev.holder?.isApple(Holders.securityAgent) == true
        }
        guard holdsKeyboard(io.evidence()) else { throw Failure("the password dialog went away") }
        guard plan.hasSecret else { throw Failure("no password came with the approval") }
        try typeSecret(holdsKeyboard)
        try press(Self.returnKey, holdsKeyboard)
        let ev = waitUntil(tuning.accepted) { $0.console.secureInputPID != pid }
        guard ev.console.secureInputPID != pid else { throw Failure("the dialog is still there; was the password right?") }
        return "the dialog took the password"
    }

    func unlock() throws -> String {
        func loginWindowHolds(_ ev: ScreenEvidence) -> Bool {
            ev.console.locked && ev.console.secureInputPID != nil && ev.holder?.isApple(Holders.loginWindow) == true
        }
        let ev = io.evidence()
        guard ev.console.locked else { return "the screen was already unlocked" }
        guard ev.console.secureInputPID == nil || loginWindowHolds(ev) else {
            throw Failure("another process has the keyboard on the lock screen")
        }
        guard plan.hasSecret else { throw Failure("no password came with the approval") }
        try press(ScreenDriver.shiftTap) { $0.console.locked } // wakes the display
        guard loginWindowHolds(waitUntil(tuning.wake, loginWindowHolds)) else {
            throw Failure("the lock screen's password field didn't come up")
        }
        try typeSecret(loginWindowHolds)
        try press(Self.returnKey, loginWindowHolds)
        guard !waitUntil(tuning.unlocked, { !$0.console.locked }).console.locked else {
            throw Failure("still locked; was the password right?")
        }
        return "unlocked"
    }

    // MARK: Steps

    func step(_ s: Step) throws {
        let ticket = io.start(s)
        guard let outcome = io.wait(ticket, timeout: tuning.stepTimeout) else { throw Failure("the JetKVM didn't confirm a step") }
        guard outcome.ok else { throw Failure("the JetKVM refused a step: \(outcome.error ?? "no reason")") }
    }

    /// Presses keys once fresh evidence still passes `expect`.
    func press(_ stroke: Stroke, _ expect: (ScreenEvidence) -> Bool) throws {
        guard expect(io.evidence()) else { throw Failure("the screen changed before a key press") }
        try step(Step(keys: [stroke]))
    }

    /// Has the broker type the approval's secret, character by character,
    /// while watching secure input and the lock straight from the console:
    /// on any change the step is aborted at once. When typing didn't finish
    /// cleanly, the characters typed (the broker's count) are erased, but
    /// only while the field they went into still has the keyboard.
    func typeSecret(_ expect: (ScreenEvidence) -> Bool) throws {
        var ev = io.evidence()
        guard expect(ev) else { throw Failure("the password field lost the keyboard before typing") }
        if ev.facts?.capsLock == true {
            try step(Step(keys: [Self.capsLock]))
            io.pause(tuning.poll)
            ev = io.evidence()
            guard ev.facts?.capsLock == false, expect(ev) else { throw Failure("Caps Lock is on") }
        }
        guard let map = ev.facts?.keyMap, !map.isEmpty else { throw Failure("no key map from the agent") }
        let before = io.liveConsole()
        func changed() -> Bool {
            let now = io.liveConsole()
            return now.secureInputPID != before.secureInputPID || now.locked != before.locked
        }
        let ticket = io.start(Step(secret: KeyMap(map: map)))
        var outcome: StepOutcome?
        var moved = false
        var waited: TimeInterval = 0
        while outcome == nil, waited < tuning.stepTimeout {
            outcome = io.wait(ticket, timeout: tuning.watch)
            waited += tuning.watch
            if outcome == nil, changed() {
                moved = true
                io.abort()
                outcome = io.wait(ticket, timeout: tuning.stepTimeout)
            }
        }
        if !moved { moved = changed() }
        if outcome?.ok == true, !moved { return }

        var note = moved ? "the password field lost the keyboard while the password was typed"
            : outcome.map { "the JetKVM couldn't type the password: \($0.error ?? "no reason")" }
            ?? "the JetKVM didn't confirm typing the password"
        if let typed = outcome?.typed, typed > 0 {
            if expect(io.evidence()) {
                let n = min(typed, 256)
                _ = io.wait(io.start(Step(erase: n)), timeout: tuning.stepTimeout)
                note += "; erased the \(n) characters typed"
            } else {
                note += "; \(typed) characters were typed and not erased (the field doesn't have the keyboard)"
            }
        }
        throw Failure(note)
    }

    /// Polls fresh evidence until `done` passes or `timeout` has passed;
    /// returns the last evidence.
    func waitUntil(_ timeout: TimeInterval, _ done: (ScreenEvidence) -> Bool) -> ScreenEvidence {
        var waited: TimeInterval = 0
        var ev = io.evidence()
        while !done(ev), waited < timeout {
            io.pause(tuning.poll)
            waited += tuning.poll
            ev = io.evidence()
        }
        return ev
    }

    static func same(_ a: ApprovalKit.Rect, _ b: ApprovalKit.Rect) -> Bool {
        abs(a.x - b.x) <= 2 && abs(a.y - b.y) <= 2 && abs(a.w - b.w) <= 2 && abs(a.h - b.h) <= 2
    }
}
