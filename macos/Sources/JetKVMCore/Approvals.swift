import ApprovalKit
import CoreImage
import Foundation

// Remote approvals (approval/PROTOCOL.md, BlitzKVM firmware D20): what the
// app decides without a window server. ApprovalKit holds the protocol; the
// app (ApprovalService.swift) owns the channels, the panel and Touch ID.

// MARK: Routes

/// Which channel carries a box to a broker.
public enum ApprovalRoute: String, Equatable, Sendable {
    /// The WebSocket to the JetKVM itself.
    case direct
    /// The relay's WebSocket.
    case relay
}

/// Boxes for a broker whose channels are both down: sent when one connects,
/// dropped after 30 s (a request expires anyway, and the broker refuses a
/// decision whose clock is off by a minute).
public struct ApprovalOutbox {
    public static let maxAge: TimeInterval = 30
    private var queued: [String: [(box: Data, at: TimeInterval)]] = [:]

    public init() {}

    /// The direct channel when it is connected, else the relay's, else
    /// none (hold the box).
    public static func route(directConnected: Bool, relayConnected: Bool) -> ApprovalRoute? {
        directConnected ? .direct : relayConnected ? .relay : nil
    }

    public mutating func hold(_ box: Data, for broker: String, at now: TimeInterval) {
        prune(at: now)
        queued[broker, default: []].append((box, now))
    }

    /// The boxes still fresh for `broker`, oldest first; they leave the queue.
    public mutating func take(for broker: String, at now: TimeInterval) -> [Data] {
        prune(at: now)
        return queued.removeValue(forKey: broker)?.map(\.box) ?? []
    }

    public mutating func prune(at now: TimeInterval) {
        for (broker, boxes) in queued {
            let fresh = boxes.filter { now - $0.at < Self.maxAge }
            queued[broker] = fresh.isEmpty ? nil : fresh
        }
    }

    public func count(for broker: String) -> Int { queued[broker]?.count ?? 0 }
}

public enum ApprovalAddress {
    /// The JetKVM's base URL for a device address, as a broker's `direct`
    /// keeps it: "192.168.1.40" → "http://192.168.1.40",
    /// "https://kvm.example:8443/" → "https://kvm.example:8443".
    public static func base(_ address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard var c = URLComponents(string: withScheme), let host = c.host, !host.isEmpty,
              c.scheme == "http" || c.scheme == "https" else { return nil }
        c.path = ""
        c.query = nil
        c.fragment = nil
        return c.string
    }

    /// A relay URL the user typed: http(s) with a host, without a trailing
    /// slash; nil for anything else.
    public static func relay(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: trimmed), c.scheme == "https" || c.scheme == "http",
              let host = c.host, !host.isEmpty, c.query == nil else { return nil }
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }
}

// MARK: Requests

/// What the app shows for a request: plain values, so the rules (a grant
/// only when grantable, a password only when the ask takes one) are
/// testable without views.
public struct ApprovalSummary: Equatable {
    public struct ProcessLine: Equatable, Identifiable {
        public let id: Int
        public let name: String
        public let pid: Int
        public let path: String?
        /// The arguments, joined and shortened.
        public let arguments: String?
        public let signer: String?
        /// Signed by Apple or a Developer ID; ad hoc and unsigned code is flagged.
        public let trusted: Bool
    }

    public struct Fact: Equatable, Identifiable {
        public var id: String { label }
        public let label: String
        public let value: String
    }

    /// The password the JetKVM types for this ask, and whether one is stored.
    public struct Password: Equatable {
        public let kind: String
        public let name: String
        public let stored: Bool
    }

    public let title: String
    public let detail: String?
    public let kind: String
    public let kindName: String
    public let symbol: String
    public let targetName: String
    public let brokerName: String
    public let code: String
    /// What to compare the code with, or what approving does.
    public let codeHint: String
    /// "alex (uid 501) · ttys003"
    public let requester: String?
    public let chain: [ProcessLine]
    public let evidence: [Fact]
    public let canGrant: Bool
    public let password: Password?
    public let expires: Int64

    public init(ask: Ask, code: String, roster: Roster?, brokerName: String, passwordStored: Bool) {
        title = ask.title
        detail = ask.detail.flatMap { $0.isEmpty ? nil : $0 }
        kind = ask.kind
        kindName = Self.kindName(ask.kind)
        symbol = Self.symbol(ask.kind)
        targetName = roster?.target(ask.target)?.name ?? "Unknown computer"
        self.brokerName = brokerName
        self.code = code
        codeHint = Kind.isTyping(ask.kind)
            ? "Approving lets the JetKVM answer the prompt on \(targetName)."
            : "Check that the remote computer shows code \(code)."
        canGrant = ask.isGrantable
        password = ask.secret == SecretKind.none ? nil
            : Password(kind: ask.secret, name: Self.passwordName(ask.secret), stored: passwordStored)
        expires = ask.expires

        if let r = ask.requester {
            var who = "\(r.user) (uid \(r.uid))"
            if let tty = r.tty, !tty.isEmpty { who += " · \(tty)" }
            requester = who
            chain = r.chain.prefix(8).enumerated().map { i, p in
                let signer = p.signer.map(Self.signer)
                return ProcessLine(id: i, name: p.name, pid: p.pid, path: p.path, arguments: p.args.flatMap(Self.abbreviate),
                                   signer: signer?.label, trusted: signer?.trusted ?? false)
            }
        } else {
            requester = nil
            chain = []
        }

        var facts: [Fact] = []
        if let e = ask.evidence {
            facts.append(Fact(label: "Screen", value: e.locked ? "Locked" : "Unlocked"))
            if let s = e.secureInput {
                facts.append(Fact(label: "Secure input", value: s.team.map { "\(s.bundle) (\($0))" } ?? s.bundle))
            }
            if let w = e.window {
                var place = "\(Int(w.w)) × \(Int(w.h)) at \(Int(w.x)), \(Int(w.y))"
                if let d = e.display { place += " of \(Int(d.w)) × \(Int(d.h))" }
                facts.append(Fact(label: "Dialog", value: place))
            }
        }
        evidence = facts
    }

    public init(_ request: OpenRequest, broker: PairedBroker?, passwordStored: Bool) {
        self.init(ask: request.ask, code: request.verified.code, roster: broker?.decodedRoster,
                  brokerName: broker?.name ?? "JetKVM", passwordStored: passwordStored)
    }

    /// The notification: "Mac mini: sudo shutdown -r now", "Code 47".
    public var notificationTitle: String { "\(targetName): \(title)" }
    public var notificationBody: String { "Code \(code)" }

    /// The reason in the Touch ID dialog ("BlitzKVM is trying to …").
    public var authenticationReason: String {
        let short = title.count > 60 ? title.prefix(59) + "…" : Substring(title)
        return "approve “\(short)” on \(targetName)"
    }

    /// Arguments on one line, at most `limit` characters.
    public static func abbreviate(_ args: [String]) -> String? {
        let limit = 160
        let line = args.map { arg in
            let flat = arg.replacingOccurrences(of: "\n", with: " ")
            return flat.contains(" ") || flat.isEmpty ? "\"\(flat)\"" : flat
        }.joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    /// "0:42"
    public static func timeLeft(_ seconds: Int64) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    public static func kindName(_ kind: String) -> String {
        switch kind {
        case Kind.sudo: "sudo"
        case Kind.confirm: "Confirmation"
        case Kind.onePassword: "1Password"
        case Kind.securityAgent: "Password dialog"
        case Kind.unlock: "Unlock screen"
        default: kind
        }
    }

    public static func symbol(_ kind: String) -> String {
        switch kind {
        case Kind.sudo: "apple.terminal"
        case Kind.confirm: "checkmark.shield"
        case Kind.onePassword: "key.horizontal"
        case Kind.securityAgent: "lock.shield"
        case Kind.unlock: "lock.open"
        default: "questionmark.circle"
        }
    }

    /// "Mac password", "1Password password".
    public static func passwordName(_ secret: String) -> String {
        switch secret {
        case SecretKind.mac: "Mac password"
        case SecretKind.onePassword: "1Password password"
        default: secret
        }
    }

    /// The passwords a target can have stored, in display order.
    public static let passwordKinds = [SecretKind.mac, SecretKind.onePassword]

    static func signer(_ raw: String) -> (label: String, trusted: Bool) {
        switch raw {
        case "apple": return ("Apple", true)
        case "adhoc": return ("Ad hoc signed", false)
        case "unsigned": return ("Unsigned", false)
        default:
            if raw.hasPrefix("developer:") { return ("Developer ID \(raw.dropFirst("developer:".count))", true) }
            return (raw, false)
        }
    }
}

/// How a request ended, as the panel says it.
public struct ApprovalOutcome: Equatable {
    public let title: String
    public let detail: String?

    /// `byName` is the deciding approver's name, `byMe` whether that is this Mac.
    public init(state: String, byName: String?, byMe: Bool, note: String?) {
        let word: String
        switch state {
        case "approved": word = "Approved"
        case "denied": word = "Denied"
        case "done": word = "Done"
        case "failed": word = "Failed"
        case "expired": word = "Expired"
        case "cancelled": word = "Cancelled on the remote computer"
        default: word = state.capitalized
        }
        let note = note.flatMap { $0.isEmpty ? nil : $0 }
        if let byName, !byMe, state == "approved" || state == "denied" || state == "done" || state == "failed" {
            title = "Handled on \(byName)"
            detail = [word, note].compactMap { $0 }.joined(separator: ": ")
        } else {
            title = word
            detail = note
        }
    }
}

// MARK: JetKVM Setup

/// getApprovalsState's answer (approval/broker State).
public struct DeviceApprovals: Decodable, Equatable {
    public struct ApproverState: Decodable, Equatable {
        public var id: String
        public var name: String
        public var platform: String
        public var owner: Bool
        public var direct: Bool?

        public init(id: String, name: String, platform: String, owner: Bool, direct: Bool? = nil) {
            self.id = id; self.name = name; self.platform = platform; self.owner = owner; self.direct = direct
        }
    }

    public var enabled: Bool
    public var broker: BrokerInfo
    public var seq: UInt64?
    public var relay: String?
    public var relayConnected: Bool?
    /// The connected daemon's target id.
    public var target: String?
    public var approvers: [ApproverState]?
    public var pending: Int?

    public init(enabled: Bool, broker: BrokerInfo, seq: UInt64? = nil, relay: String? = nil, relayConnected: Bool? = nil,
                target: String? = nil, approvers: [ApproverState]? = nil, pending: Int? = nil) {
        self.enabled = enabled; self.broker = broker; self.seq = seq; self.relay = relay
        self.relayConnected = relayConnected; self.target = target; self.approvers = approvers; self.pending = pending
    }
}

/// One approver as the setup sheet and Settings list it.
public struct ApproverLine: Equatable, Identifiable {
    public let id: String
    public let name: String
    public let platform: String
    public let owner: Bool
    public let isMe: Bool

    public init(id: String, name: String, platform: String, owner: Bool, isMe: Bool) {
        self.id = id; self.name = name; self.platform = platform; self.owner = owner; self.isMe = isMe
    }

    public var symbol: String { platform == "ios" ? "iphone" : "laptopcomputer" }

    public static func lines(_ roster: Roster, me: String) -> [ApproverLine] {
        roster.approvers.map {
            ApproverLine(id: $0.id, name: $0.name, platform: $0.platform, owner: roster.isOwner($0.id), isMe: $0.id == me)
        }
    }

    /// "This Mac, Alex's iPhone"
    public static func names(_ lines: [ApproverLine]) -> String {
        lines.map { $0.isMe ? "This Mac" : $0.name }.joined(separator: ", ")
    }
}

/// The Approvals row of JetKVM Setup.
public enum ApprovalsSetupState: Equatable {
    /// Off, and clipboard sync isn't set up: approvals use its USB link and
    /// its login on the remote Mac.
    case needsClipboardSync
    /// Off: this Mac can turn it on and become its owner.
    case off
    /// On under a roster this Mac doesn't own (another owner set it up, or
    /// this Mac forgot it): it can turn it off.
    case managedElsewhere(approvers: [ApproverLine], paired: Bool)
    /// On, with this Mac an owner.
    case on(On)

    public struct On: Equatable {
        public var brokerID: String
        public var approvers: [ApproverLine]
        /// The remote side, once installed: the roster's target.
        public var target: Target?
        /// Its daemon is connected to the JetKVM.
        public var connected: Bool
        /// Installing needs clipboard sync's login.
        public var canInstall: Bool
    }

    /// From what the JetKVM says and what this Mac holds: `roster` is this
    /// Mac's copy for the device's broker, nil when it isn't paired.
    public static func evaluate(device: DeviceApprovals, hasClipboardSync: Bool, roster: Roster?, me: String) -> ApprovalsSetupState {
        guard device.enabled else { return hasClipboardSync ? .off : .needsClipboardSync }
        guard let roster, roster.broker.id == device.broker.id, roster.isOwner(me) else {
            let approvers = roster.map { ApproverLine.lines($0, me: me) }
                ?? (device.approvers ?? []).map { ApproverLine(id: $0.id, name: $0.name, platform: $0.platform, owner: $0.owner, isMe: $0.id == me) }
            return .managedElsewhere(approvers: approvers, paired: roster != nil)
        }
        let target = roster.targets.first
        return .on(On(brokerID: roster.broker.id, approvers: ApproverLine.lines(roster, me: me), target: target,
                      connected: target != nil && device.target == target?.id, canInstall: hasClipboardSync))
    }
}

// MARK: Pairing

/// QR codes for pairing invites.
public enum QRCode {
    /// The code as an image, one pixel per module (scale it without
    /// interpolation), or `scale` pixels per module.
    public static func image(_ string: String, scale: Int = 1) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard var image = filter.outputImage else { return nil }
        if scale > 1 {
            image = image.samplingNearest().transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        }
        return CIContext(options: [.useSoftwareRenderer: true]).createCGImage(image, from: image.extent.integral)
    }

    /// Reads a QR code back (tests).
    public static func read(_ image: CGImage) -> String? {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return (detector?.features(in: CIImage(cgImage: image)).first as? CIQRCodeFeature)?.messageString
    }
}

public extension JSONValue {
    /// Any Encodable as a JSON value (an envelope as an RPC parameter).
    init(encoding value: some Encodable) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: Wire.encoder.encode(value))
    }
}
