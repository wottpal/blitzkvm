import ApprovalKit
import Foundation

/// What the agent sees in the user's session, without any permission:
/// the frontmost app, windows at the prompt layer (owners and bounds; no
/// names, which would need Screen Recording), the main display, and the
/// keyboard. The daemon checks what it acts on (window owners by signature).
public struct AgentFacts: Codable, Equatable {
    public var frontmost: AppRef?
    /// Windows at OnePassword.layer, in global top-left points.
    public var windows: [WindowFact]
    /// The main display in points: the JetKVM's absolute pointer spans it.
    public var display: ApprovalKit.Size?
    public var inputSource: String?
    /// Strokes per printable ASCII character for the active input source.
    public var keyMap: [String: [Stroke]]?
    public var capsLock: Bool

    public init(frontmost: AppRef? = nil, windows: [WindowFact] = [], display: ApprovalKit.Size? = nil,
                inputSource: String? = nil, keyMap: [String: [Stroke]]? = nil, capsLock: Bool = false) {
        self.frontmost = frontmost; self.windows = windows; self.display = display
        self.inputSource = inputSource; self.keyMap = keyMap; self.capsLock = capsLock
    }
}

public struct AppRef: Codable, Equatable {
    public var pid: Int32
    public var bundle: String?
    public var name: String?
    public init(pid: Int32, bundle: String?, name: String?) { self.pid = pid; self.bundle = bundle; self.name = name }
}

public struct WindowFact: Codable, Equatable {
    public var number: Int
    public var pid: Int32
    public var owner: String?
    public var bundle: String?
    public var layer: Int
    public var x, y, w, h: Double

    public init(number: Int, pid: Int32, owner: String? = nil, bundle: String? = nil, layer: Int, x: Double, y: Double,
                w: Double, h: Double) {
        self.number = number; self.pid = pid; self.owner = owner; self.bundle = bundle; self.layer = layer
        self.x = x; self.y = y; self.w = w; self.h = h
    }

    public var rect: ApprovalKit.Rect { .init(x: x, y: y, w: w, h: h) }
}

/// 1Password's CLI access prompt ("1Password Access Requested"): a window of
/// the 1Password app at layer 101, about 400×346 points (with a
/// transparent margin), that doesn't take the keyboard.
public enum OnePassword {
    public static let bundle = "com.1password.1password"
    public static let team = "2BUA8C4S2C"
    public static let layer = 101
    public static let size = (w: 400.0, h: 346.0)
    /// Localizations change the size a little.
    public static let sizeTolerance = 0.15
    /// The default button ("Authorize") from the window's bottom right. The
    /// window keeps its size while the panel inside grows with its text:
    /// the button sits 61 pt up with a one-line requester, 40 pt with two
    /// (measured on macOS 27). A miss lands on the panel's own body.
    public static let buttonInsets: [(x: Double, y: Double)] = [(77, 61), (77, 40)]
    public static var buttonInset: (x: Double, y: Double) { buttonInsets[0] }

    public static func isPromptShaped(_ w: WindowFact) -> Bool {
        w.layer == layer && abs(w.w - size.w) <= size.w * sizeTolerance && abs(w.h - size.h) <= size.h * sizeTolerance
    }

    /// The prompts in `facts` whose owner's signature `isOnePassword`
    /// confirms (by pid, on the daemon's side).
    public static func prompts(in facts: AgentFacts, isOnePassword: (Int32) -> Bool) -> [WindowFact] {
        facts.windows.filter { isPromptShaped($0) && isOnePassword($0.pid) }
    }

    /// The button's center as fractions of the main display, which the
    /// JetKVM's absolute pointer spans; nil unless the whole window is on it.
    public static func buttonPoint(window r: ApprovalKit.Rect, display d: ApprovalKit.Size,
                                   inset: (x: Double, y: Double) = buttonInsets[0]) -> ApprovalKit.Point? {
        guard d.w > 0, d.h > 0, r.x >= 0, r.y >= 0, r.x + r.w <= d.w, r.y + r.h <= d.h,
              r.w > inset.x, r.h > inset.y else { return nil }
        return ApprovalKit.Point(x: (r.x + r.w - inset.x) / d.w, y: (r.y + r.h - inset.y) / d.h)
    }
}

/// The processes whose password fields the daemon types into, by signature.
public enum Holders {
    public static let securityAgent: Set<String> = ["com.apple.SecurityAgent", "com.apple.SecurityAgentHelper",
                                                    "com.apple.authorizationhost"]
    public static let loginWindow: Set<String> = ["com.apple.loginwindow"]
}
