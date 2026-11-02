import ApprovalKit
import XCTest
@testable import RemoteCore

/// A JetKVM display and a 1Password prompt centered on it, as measured on
/// the target.
let display = ApprovalKit.Size(w: 1504, h: 948)
let prompt = WindowFact(number: 81, pid: 7000, owner: "1Password", bundle: OnePassword.bundle, layer: 101,
                        x: 552, y: 301, w: 400, h: 346)
/// The prompt while 1Password is locked: with its password field, taller.
let lockedPrompt = WindowFact(number: 86, pid: 7000, owner: "1Password", bundle: OnePassword.bundle, layer: 101,
                              x: 552, y: 273, w: 400, h: 402)

final class OnePasswordTests: XCTestCase {
    func testDetection() {
        let facts = AgentFacts(windows: [
            prompt,
            WindowFact(number: 82, pid: 7000, layer: 0, x: 0, y: 0, w: 400, h: 346), // a normal window
            WindowFact(number: 83, pid: 7000, layer: 101, x: 0, y: 0, w: 680, h: 420), // another shape
            WindowFact(number: 84, pid: 6000, owner: "1Password", bundle: OnePassword.bundle, layer: 101,
                       x: 552, y: 301, w: 400, h: 346), // claims to be 1Password, isn't
            WindowFact(number: 85, pid: 7000, layer: 101, x: 552, y: 290, w: 420, h: 370), // localized: a bit larger
            lockedPrompt,
        ], display: display)
        let found = OnePassword.prompts(in: facts) { $0 == 7000 }
        XCTAssertEqual(found.map(\.number), [81, 85, 86])
        XCTAssertEqual(found.map(OnePassword.isLocked), [false, false, true])
    }

    /// The locked prompt's spots, measured on the target: the title, then
    /// the password field (293–333 pt from the top with a two-line requester,
    /// 21 pt higher with one).
    func testFocusSpots() throws {
        let spots = OnePassword.focusSpots(lockedPrompt.rect)
        XCTAssertEqual(spots.count, 2)
        XCTAssertEqual(spots[0].y, 44)
        XCTAssertTrue((272...333).contains(spots[1].y), "inside the field with a one- or two-line requester")
        let p = try XCTUnwrap(OnePassword.point(window: lockedPrompt.rect, display: display, at: spots[0]))
        XCTAssertEqual(p.x, (552 + 200) / 1504, accuracy: 1e-9)
        XCTAssertEqual(p.y, (273 + 44) / 948, accuracy: 1e-9)
        XCTAssertNil(OnePassword.point(window: lockedPrompt.rect, display: display, at: (500, 44)), "outside the window")
    }

    func testButtonPoint() throws {
        let p = try XCTUnwrap(OnePassword.buttonPoint(window: prompt.rect, display: display))
        XCTAssertEqual(p.x, (552 + 400 - 77) / 1504, accuracy: 1e-9)
        XCTAssertEqual(p.y, (301 + 346 - 61) / 948, accuracy: 1e-9)
        // Partly or wholly off the main display: no click.
        XCTAssertNil(OnePassword.buttonPoint(window: .init(x: 1300, y: 301, w: 400, h: 346), display: display))
        XCTAssertNil(OnePassword.buttonPoint(window: .init(x: -1600, y: 100, w: 400, h: 346), display: display))
        XCTAssertNil(OnePassword.buttonPoint(window: .init(x: 552, y: 700, w: 400, h: 346), display: display))
    }
}

/// A scripted screen: the driver's evidence and the broker's answers.
final class FakeScreen: ScreenIO {
    var console = ConsoleState(uid: 501)
    var identities: [Int32: CodeIdentity] = [7000: .onePassword, 6100: .securityAgent, 90: .loginWindow, 4000: .other]
    var facts: AgentFacts? = AgentFacts(frontmost: AppRef(pid: 3000, bundle: "com.example.terminal", name: "Terminal"),
                                        windows: [prompt], display: display, keyMap: ["a": [[4, 0]]])
    private(set) var steps: [Step] = []
    /// The world's answer to a step (it may change the screen).
    var onStep: (Step) -> StepOutcome = { _ in .ok }
    /// How many waits a secret step takes, what happens on each, and how
    /// many characters the broker says it typed (all of them, or until the
    /// abort).
    var secretWaits = 3
    var duringSecret: (Int) -> Void = { _ in }
    var secretTyped = 8
    var abortTyped = 3
    var onAbort: () -> Void = {}
    private(set) var aborts = 0
    private(set) var activated: [AppRef] = []
    private var outcomes: [Int: StepOutcome] = [:]
    private var waits: [Int: Int] = [:]

    var stale = false
    func evidence() -> ScreenEvidence {
        ScreenEvidence(console: console, holder: console.secureInputPID.flatMap { identities[$0] }, facts: facts, fresh: !stale)
    }

    func liveConsole() -> ConsoleState { console }

    func start(_ step: Step) -> Int {
        steps.append(step)
        var outcome = onStep(step)
        if step.secret != nil, outcome.typed == nil { outcome.typed = outcome.ok ? secretTyped : 0 }
        outcomes[steps.count] = outcome
        return steps.count
    }

    func abort() {
        aborts += 1
        if let i = steps.lastIndex(where: { $0.secret != nil }) {
            outcomes[i + 1] = .failed("aborted", typed: abortTyped)
            waits[i + 1] = secretWaits // the running step answers now
        }
        onAbort()
    }

    func wait(_ ticket: Int, timeout: TimeInterval) -> StepOutcome? {
        if steps[ticket - 1].secret != nil {
            let n = waits[ticket, default: 0]
            waits[ticket] = n + 1
            duringSecret(n)
            if n < secretWaits { return nil }
        }
        return outcomes[ticket]
    }

    func activate(_ app: AppRef) { activated.append(app) }
    func pause(_ seconds: TimeInterval) {}

    var kinds: [String] {
        steps.map { s in
            if let c = s.click { return String(format: "click %.3f,%.3f", c.x, c.y) }
            if let k = s.keys { return "keys \(k)" }
            if s.secret != nil { return "secret" }
            if let e = s.erase { return "erase \(e)" }
            return "?"
        }
    }
}

final class ScreenDriverTests: XCTestCase {
    let terminal = AppRef(pid: 3000, bundle: "com.example.terminal", name: "Terminal")

    func run(_ screen: FakeScreen, _ plan: ScreenPlan) -> (ok: Bool, note: String) {
        ScreenDriver(io: screen, plan: plan).run()
    }

    func onePasswordPlan(secret: Bool = false) -> ScreenPlan {
        ScreenPlan(kind: Kind.onePassword, window: prompt, display: display, hasSecret: secret, previousApp: terminal)
    }

    func testOnePasswordClickAuthorizes() {
        let s = FakeScreen()
        s.onStep = { step in
            if step.click != nil { s.facts?.windows = [] } // the prompt goes
            return .ok
        }
        let r = run(s, onePasswordPlan())
        XCTAssertTrue(r.ok, r.note)
        XCTAssertEqual(s.kinds, [String(format: "click %.3f,%.3f", (552 + 400 - 77) / 1504.0, (301 + 346 - 61) / 948.0)])
        XCTAssertEqual(s.activated, [terminal], "the app that had the front gets it back")
    }

    /// A two-line requester puts the button lower in the same window: the
    /// first click lands on the panel, the second on the button.
    func testOnePasswordTriesTheLowerButton() {
        let s = FakeScreen()
        var clicks = 0
        s.onStep = { step in
            if step.click != nil {
                clicks += 1
                if clicks == 2 { s.facts?.windows = [] }
            }
            return .ok
        }
        let r = run(s, onePasswordPlan())
        XCTAssertTrue(r.ok, r.note)
        XCTAssertEqual(s.kinds, [String(format: "click %.3f,%.3f", (552 + 400 - 77) / 1504.0, (301 + 346 - 61) / 948.0),
                                 String(format: "click %.3f,%.3f", (552 + 400 - 77) / 1504.0, (301 + 346 - 40) / 948.0)])
        XCTAssertEqual(s.activated, [terminal])
    }

    func testOnePasswordGivesUpAfterBothPlaces() {
        let s = FakeScreen()
        s.onStep = { _ in .ok } // the prompt stays
        let r = run(s, onePasswordPlan())
        XCTAssertFalse(r.ok)
        XCTAssertEqual(s.kinds.count, 2, "two clicks, then it stops")
        XCTAssertEqual(s.activated, [terminal])
    }

    /// Stale window facts (the agent didn't answer the refresh) never lead
    /// to a click: the prompt may be gone and something else beneath.
    func testOnePasswordNeverClicksOnStaleFacts() {
        let s = FakeScreen()
        s.stale = true
        let r = run(s, onePasswordPlan())
        XCTAssertFalse(r.ok)
        XCTAssertTrue(s.steps.isEmpty, r.note)
    }

    func testOnePasswordAbortsWhenThePromptChanged() {
        for change in [
            { (s: FakeScreen) in s.facts?.windows[0].x += 40 }, // moved
            { (s: FakeScreen) in s.facts?.windows = [] }, // gone
            { (s: FakeScreen) in s.facts?.windows[0].pid = 4000 }, // another owner
            { (s: FakeScreen) in s.facts?.display = .init(w: 1280, h: 720) }, // the display changed
            { (s: FakeScreen) in s.console.locked = true },
        ] {
            let s = FakeScreen()
            change(s)
            let r = run(s, onePasswordPlan())
            XCTAssertFalse(r.ok)
            XCTAssertTrue(s.steps.isEmpty, "no step on changed evidence: \(r.note)")
            XCTAssertTrue(s.activated.isEmpty, "nothing was clicked, nothing to give back")
        }
    }

    func testOnePasswordLockedTypesThePassword() {
        let s = FakeScreen()
        s.onStep = { step in
            if step.click != nil { s.console.secureInputPID = 7000 } // 1Password's password field
            if step.keys == [[0x28, 0]] { s.console.secureInputPID = nil; s.facts?.windows = [] }
            return .ok
        }
        let r = run(s, onePasswordPlan(secret: true))
        XCTAssertTrue(r.ok, r.note)
        XCTAssertEqual(Array(s.kinds.dropFirst()), ["secret", "keys [[40, 0]]"])
        XCTAssertEqual(s.steps[1].secret?.map, ["a": [[4, 0]]], "typed with the agent's key map")
        XCTAssertEqual(s.activated, [terminal])
    }

    func testOnePasswordLockedWithoutASecret() {
        let s = FakeScreen()
        s.onStep = { step in
            if step.click != nil { s.console.secureInputPID = 7000 }
            return .ok
        }
        let r = run(s, onePasswordPlan())
        XCTAssertFalse(r.ok)
        XCTAssertEqual(s.kinds.count, 1, "the click only")
        XCTAssertEqual(s.activated, [terminal])
    }

    func lockedPlan(secret: Bool = true) -> ScreenPlan {
        ScreenPlan(kind: Kind.onePassword, window: lockedPrompt, display: display, hasSecret: secret, previousApp: terminal)
    }

    func lockedScreen() -> FakeScreen {
        let s = FakeScreen()
        s.facts?.windows = [lockedPrompt]
        return s
    }

    /// 1Password is locked: a click on the title gives the password field
    /// the keyboard; the password and Return unlock and authorize at once.
    func testLockedPromptTypesThePasswordAfterAClick() {
        let s = lockedScreen()
        s.onStep = { step in
            if step.click != nil { s.console.secureInputPID = 7000 }
            if step.keys == [[0x28, 0]] { s.console.secureInputPID = nil; s.facts?.windows = [] }
            return .ok
        }
        let r = run(s, lockedPlan())
        XCTAssertTrue(r.ok, r.note)
        XCTAssertEqual(s.kinds, [String(format: "click %.3f,%.3f", (552 + 200) / 1504.0, (273 + 44) / 948.0), "secret", "keys [[40, 0]]"])
        XCTAssertEqual(s.activated, [terminal])
    }

    /// The title click leaves the keyboard where it was: the field itself
    /// is clicked next.
    func testLockedPromptClicksTheFieldNext() {
        let s = lockedScreen()
        var clicks = 0
        s.onStep = { step in
            if step.click != nil {
                clicks += 1
                if clicks == 2 { s.console.secureInputPID = 7000 }
            }
            if step.keys == [[0x28, 0]] { s.console.secureInputPID = nil; s.facts?.windows = [] }
            return .ok
        }
        let r = run(s, lockedPlan())
        XCTAssertTrue(r.ok, r.note)
        XCTAssertEqual(Array(s.kinds.dropFirst(2)), ["secret", "keys [[40, 0]]"])
        XCTAssertEqual(s.kinds[1], String(format: "click %.3f,%.3f", (552 + 200) / 1504.0, (273 + 402 - 100) / 948.0))
    }

    /// The front app keeps secure input (or nobody has it): nothing is typed,
    /// the password would go to that app.
    func testLockedPromptNeverTypesWithoutTheKeyboard() {
        for holder: Int32? in [nil, 4000] {
            let s = lockedScreen()
            s.console.secureInputPID = holder
            let r = run(s, lockedPlan())
            XCTAssertFalse(r.ok)
            XCTAssertEqual(s.kinds.count, 2, "two clicks, no keys: \(s.kinds)")
            XCTAssertTrue(s.kinds.allSatisfy { $0.hasPrefix("click") })
            XCTAssertEqual(s.activated, [terminal])
        }
    }

    /// 1Password held secure input before the click (stuck): that says
    /// nothing about the prompt, so nothing is typed.
    func testLockedPromptNeverTypesIntoAKeyboardHeldBeforeTheClick() {
        let s = lockedScreen()
        s.console.secureInputPID = 7000
        let r = run(s, lockedPlan())
        XCTAssertFalse(r.ok)
        XCTAssertTrue(s.steps.isEmpty, r.note)
    }

    func testLockedPromptWithoutASecretIsntTouched() {
        let s = lockedScreen()
        let r = run(s, lockedPlan(secret: false))
        XCTAssertFalse(r.ok)
        XCTAssertTrue(s.steps.isEmpty, r.note)
    }

    /// Secure input moves to another app while the broker types: the step
    /// is aborted at once, and nothing is erased, since Backspaces would go
    /// to the app that has the keyboard now.
    func testAbortWhenTheFieldLosesTheKeyboard() {
        let s = FakeScreen()
        s.onStep = { step in
            if step.click != nil { s.console.secureInputPID = 7000 }
            return .ok
        }
        s.duringSecret = { n in if n == 1 { s.console.secureInputPID = 4000 } }
        let r = run(s, onePasswordPlan(secret: true))
        XCTAssertFalse(r.ok)
        XCTAssertEqual(s.aborts, 1)
        XCTAssertEqual(Array(s.kinds.dropFirst()), ["secret"], "no erase into another app")
        XCTAssertTrue(r.note.contains("some characters were typed and not erased"), r.note)
        XCTAssertEqual(s.activated, [terminal])
    }

    /// The lock state changes while typing: abort. Once the field has the
    /// keyboard again, the characters the broker typed are erased, exactly
    /// as many as it reports.
    func testAbortThenEraseWhatWasTyped() {
        let s = FakeScreen()
        s.console.secureInputPID = 6100
        s.duringSecret = { n in if n == 2 { s.console.secureInputPID = nil } }
        s.onAbort = { s.console.secureInputPID = 6100 }
        s.abortTyped = 5
        let r = run(s, ScreenPlan(kind: Kind.securityAgent, holderPID: 6100, hasSecret: true))
        XCTAssertFalse(r.ok)
        XCTAssertEqual(s.aborts, 1)
        XCTAssertEqual(s.kinds, ["secret", "erase 5"])
        XCTAssertTrue(r.note.contains("erased the 5 characters typed"), r.note)
    }

    /// A device error part-way: the field still has the keyboard, so what
    /// was typed goes.
    func testFailedSecretErasesWhatWasTyped() {
        let s = FakeScreen()
        s.console.secureInputPID = 6100
        s.onStep = { $0.secret != nil ? .failed("the keyboard went away", typed: 4) : .ok }
        let r = run(s, ScreenPlan(kind: Kind.securityAgent, holderPID: 6100, hasSecret: true))
        XCTAssertFalse(r.ok)
        XCTAssertEqual(s.aborts, 0)
        XCTAssertEqual(s.kinds, ["secret", "erase 4"])
    }

    func testRefusedSecretErasesNothing() {
        let s = FakeScreen()
        s.console.secureInputPID = 6100
        s.onStep = { $0.secret != nil ? .failed("a character the map lacks", typed: 0) : .ok }
        let r = run(s, ScreenPlan(kind: Kind.securityAgent, holderPID: 6100, hasSecret: true))
        XCTAssertFalse(r.ok)
        XCTAssertEqual(s.kinds, ["secret"])
    }

    func testSecurityAgent() {
        let s = FakeScreen()
        s.console.secureInputPID = 6100
        s.onStep = { step in
            if step.keys == [[0x28, 0]] { s.console.secureInputPID = nil }
            return .ok
        }
        let r = run(s, ScreenPlan(kind: Kind.securityAgent, holderPID: 6100, hasSecret: true))
        XCTAssertTrue(r.ok, r.note)
        XCTAssertEqual(s.kinds, ["secret", "keys [[40, 0]]"])
    }

    /// A second dialog of the same SecurityAgent (or the approved one gone
    /// and another in its place), or another user's console: nothing typed.
    func testSecurityAgentTypesOnlyIntoTheApprovedDialog() {
        let dialog = WindowFact(number: 900, pid: 6100, owner: "SecurityAgent", layer: 1000, x: 500, y: 300, w: 420, h: 260)
        for change in [
            { (s: FakeScreen) in s.facts?.windows = [dialog, WindowFact(number: 901, pid: 6100, owner: "SecurityAgent", layer: 1000,
                                                                       x: 0, y: 0, w: 420, h: 260)] },
            { (s: FakeScreen) in s.facts?.windows = [WindowFact(number: 901, pid: 6100, owner: "SecurityAgent", layer: 1000,
                                                                x: 500, y: 300, w: 420, h: 260)] },
            { (s: FakeScreen) in s.console.uid = 502 },
        ] {
            let s = FakeScreen()
            s.console.secureInputPID = 6100
            s.facts?.windows = [dialog]
            change(s)
            let r = run(s, ScreenPlan(kind: Kind.securityAgent, window: dialog, holderPID: 6100, hasSecret: true, consoleUID: 501))
            XCTAssertFalse(r.ok)
            XCTAssertTrue(s.steps.isEmpty, r.note)
        }
    }

    func testSecurityAgentRefusesAnImpostor() {
        let s = FakeScreen()
        s.console.secureInputPID = 6100
        s.identities[6100] = .other // the pid now belongs to another app
        let r = run(s, ScreenPlan(kind: Kind.securityAgent, holderPID: 6100, hasSecret: true))
        XCTAssertFalse(r.ok)
        XCTAssertTrue(s.steps.isEmpty)
    }

    func testCapsLockIsTurnedOffFirst() {
        let s = FakeScreen()
        s.console.secureInputPID = 6100
        s.facts?.capsLock = true
        s.onStep = { step in
            if step.keys == [[0x39, 0]] { s.facts?.capsLock = false }
            if step.keys == [[0x28, 0]] { s.console.secureInputPID = nil }
            return .ok
        }
        let r = run(s, ScreenPlan(kind: Kind.securityAgent, holderPID: 6100, hasSecret: true))
        XCTAssertTrue(r.ok, r.note)
        XCTAssertEqual(s.kinds, ["keys [[57, 0]]", "secret", "keys [[40, 0]]"])
    }

    func testUnlock() {
        let s = FakeScreen()
        s.console = ConsoleState(uid: 501, locked: true)
        s.onStep = { step in
            if step.keys == [[0, 2]] { s.console.secureInputPID = 90 } // awake: the password field
            if step.keys == [[0x28, 0]] { s.console = ConsoleState(uid: 501) }
            return .ok
        }
        let r = run(s, ScreenPlan(kind: Kind.unlock, hasSecret: true))
        XCTAssertTrue(r.ok, r.note)
        XCTAssertEqual(s.kinds, ["keys [[0, 2]]", "secret", "keys [[40, 0]]"])
    }

    func testUnlockRefusesAnotherHolder() {
        let s = FakeScreen()
        s.console = ConsoleState(uid: 501, locked: true, secureInputPID: 4000)
        let r = run(s, ScreenPlan(kind: Kind.unlock, hasSecret: true))
        XCTAssertFalse(r.ok)
        XCTAssertTrue(s.steps.isEmpty)
    }

    func testUnlockNeedsTheLoginWindowsField() {
        let s = FakeScreen()
        s.console = ConsoleState(uid: 501, locked: true)
        s.onStep = { step in
            if step.keys == [[0, 2]] { s.console.secureInputPID = 4000 } // someone else grabbed it
            return .ok
        }
        let r = run(s, ScreenPlan(kind: Kind.unlock, hasSecret: true))
        XCTAssertFalse(r.ok)
        XCTAssertEqual(s.kinds, ["keys [[0, 2]]"], "no secret into a field that isn't the login window's")
    }

    func testAStepTheBrokerRefusesEndsIt() {
        let s = FakeScreen()
        s.onStep = { _ in .failed("the approval is too old for screen steps") }
        let r = run(s, onePasswordPlan())
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.note.contains("too old"), r.note)
    }
}
