import CryptoKit
import Foundation

public enum Kind {
    public static let sudo = "sudo", confirm = "confirm", onePassword = "onepassword"
    public static let securityAgent = "securityagent", unlock = "unlock"

    /// Kinds the broker answers by acting on the screen.
    public static func isTyping(_ kind: String) -> Bool { [onePassword, securityAgent, unlock].contains(kind) }
}

public enum SecretKind {
    public static let none = "none", mac = "mac", onePassword = "onepassword"
}

public enum Limits {
    public static let maxAskLifetime: Int64 = 120
    public static let maxText = 2048 // bytes of an ask's title or detail
    public static let maxChain = 8
    public static let clockSkew: Int64 = 60
    public static let grantMinutes = 10
}

// MARK: Roster

public struct Roster: Codable, Hashable, Sendable {
    public var v = 1
    public var seq: UInt64
    public var issued: Int64
    public var broker: BrokerInfo
    public var relay: String?
    public var owners: [String]
    public var approvers: [Approver]
    public var targets: [Target]

    public init(seq: UInt64, issued: Int64, broker: BrokerInfo, relay: String? = nil, owners: [String],
                approvers: [Approver], targets: [Target]) {
        self.seq = seq; self.issued = issued; self.broker = broker; self.relay = relay
        self.owners = owners; self.approvers = approvers; self.targets = targets
    }

    public func approver(_ id: String) -> Approver? { approvers.first { $0.id == id } }
    public func target(_ id: String) -> Target? { targets.first { $0.id == id } }
    public func isOwner(_ id: String) -> Bool { owners.contains(id) }

    public func check() throws {
        guard v == 1, seq > 0 else { throw WireError.roster("version or seq") }
        guard broker.id == Wire.kid(broker.key.data) else { throw WireError.roster("broker id") }
        guard !owners.isEmpty else { throw WireError.roster("no owners") }
        var seen = Set<String>()
        for a in approvers {
            guard a.id == Wire.kid(a.presence.data), seen.insert(a.id).inserted,
                  a.platform == "ios" || a.platform == "macos" else { throw WireError.roster("approver \(a.name)") }
        }
        guard owners.allSatisfy(seen.contains) else { throw WireError.roster("owner isn't an approver") }
        var targetIDs = Set<String>()
        for t in targets {
            guard t.id == Wire.kid(t.key.data), targetIDs.insert(t.id).inserted else { throw WireError.roster("target \(t.name)") }
        }
    }

    /// Checks a roster envelope against the current roster (nil for a
    /// genesis roster, which must be signed by one of its own owners).
    public static func accept(_ env: Envelope, current: Roster?) throws -> Roster {
        guard env.t == "roster" else { throw WireError.type }
        let next = try env.peek(Roster.self)
        let trust = current ?? next
        guard let signer = trust.approver(env.k), trust.isOwner(signer.id) else { throw WireError.roster("not signed by an owner") }
        try env.verify(type: "roster", key: signer.presence.data)
        try next.check()
        if let current {
            guard next.seq > current.seq else { throw WireError.roster("stale") }
            guard next.broker.id == current.broker.id else { throw WireError.roster("another broker") }
        }
        return next
    }
}

public struct BrokerInfo: Codable, Hashable, Sendable {
    public var id: String
    public var key: B64Data
    public var seal: B64Data
    public init(id: String, key: B64Data, seal: B64Data) { self.id = id; self.key = key; self.seal = seal }
}

public struct Approver: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var platform: String
    public var presence: B64Data
    public var transport: B64Data
    public var seal: B64Data
    public init(name: String, platform: String, presence: Data, transport: Data, seal: Data) {
        id = Wire.kid(presence); self.name = name; self.platform = platform
        self.presence = B64Data(presence); self.transport = B64Data(transport); self.seal = B64Data(seal)
    }
}

public struct Target: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var key: B64Data
    public init(name: String, key: Data) { id = Wire.kid(key); self.name = name; self.key = B64Data(key) }
}

// MARK: Ask, request, decision

public struct Ask: Codable, Hashable, Sendable {
    public var v = 1
    public var id: String
    public var target: String
    public var kind: String
    public var title: String
    public var detail: String?
    public var requester: Requester?
    public var evidence: Evidence?
    public var secret: String
    public var grantable: Bool?
    /// The approver whose signed unlock request raised this (unlock only).
    public var requestedBy: String?
    public var nonce: B64Data
    public var issued: Int64
    public var expires: Int64

    public init(id: String = Wire.randomID(), target: String, kind: String, title: String, detail: String? = nil,
                requester: Requester? = nil, evidence: Evidence? = nil, secret: String = SecretKind.none,
                grantable: Bool = false, requestedBy: String? = nil, issued: Int64, lifetime: Int64 = 60) {
        self.id = id; self.target = target; self.kind = kind; self.title = title; self.detail = detail
        self.requester = requester; self.evidence = evidence; self.secret = secret
        self.grantable = grantable ? true : nil; self.requestedBy = requestedBy; nonce = B64Data(Wire.randomBytes(32))
        self.issued = issued; expires = issued + lifetime
    }

    public var isGrantable: Bool { grantable ?? false }

    public func check(now: Int64?) throws {
        guard v == 1, id.count == 32, Data(hex: id) != nil else { throw WireError.invalid("ask id") }
        guard [Kind.sudo, Kind.confirm].contains(kind) || Kind.isTyping(kind) else { throw WireError.invalid("kind") }
        guard [SecretKind.none, SecretKind.mac, SecretKind.onePassword].contains(secret) else { throw WireError.invalid("secret") }
        guard secret == SecretKind.none || Kind.isTyping(kind) else { throw WireError.invalid("secret for a non-typing ask") }
        guard !(isGrantable && Kind.isTyping(kind)) else { throw WireError.invalid("grantable typing ask") }
        guard nonce.data.count == 32, !title.isEmpty, expires > issued, expires - issued <= Limits.maxAskLifetime else {
            throw WireError.invalid("ask fields")
        }
        guard (kind == Kind.unlock) == (requestedBy != nil) else { throw WireError.invalid("unlock asks name who requested them") }
        guard title.utf8.count <= Limits.maxText, (detail?.utf8.count ?? 0) <= Limits.maxText,
              (requester?.chain.count ?? 0) <= Limits.maxChain else { throw WireError.invalid("ask too long") }
        if let now, now >= expires { throw WireError.expired }
    }
}

public struct Requester: Codable, Hashable, Sendable {
    public var uid: Int
    public var user: String
    public var tty: String?
    public var chain: [Process]
    public init(uid: Int, user: String, tty: String? = nil, chain: [Process]) {
        self.uid = uid; self.user = user; self.tty = tty; self.chain = chain
    }
}

public struct Process: Codable, Hashable, Sendable {
    public var pid: Int
    public var name: String
    public var path: String?
    public var args: [String]?
    public var signer: String?
    public init(pid: Int, name: String, path: String? = nil, args: [String]? = nil, signer: String? = nil) {
        self.pid = pid; self.name = name; self.path = path; self.args = args; self.signer = signer
    }
}

public struct Evidence: Codable, Hashable, Sendable {
    public var locked: Bool
    public var secureInput: SecureInput?
    public var window: Rect?
    public var display: Size?
    public init(locked: Bool, secureInput: SecureInput? = nil, window: Rect? = nil, display: Size? = nil) {
        self.locked = locked; self.secureInput = secureInput; self.window = window; self.display = display
    }
}

public struct SecureInput: Codable, Hashable, Sendable {
    public var pid: Int
    public var bundle: String
    public var team: String?
    public init(pid: Int, bundle: String, team: String?) { self.pid = pid; self.bundle = bundle; self.team = team }
}

public struct Rect: Codable, Hashable, Sendable {
    public var x, y, w, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
}

public struct Size: Codable, Hashable, Sendable {
    public var w, h: Double
    public init(w: Double, h: Double) { self.w = w; self.h = h }
}

public struct Request: Codable, Hashable, Sendable {
    public var v = 1
    public var ask: Envelope
    public var seal: B64Data
    public var issued: Int64
    public var expires: Int64
    public init(ask: Envelope, seal: B64Data, issued: Int64, expires: Int64) {
        self.ask = ask; self.seal = seal; self.issued = issued; self.expires = expires
    }
}

public enum DecisionValue {
    public static let approve = "approve", deny = "deny"
}

public struct Decision: Codable, Hashable, Sendable {
    public var v = 1
    public var request: String
    public var ask: String
    public var decision: String
    public var grant: Int?
    public var approver: String
    public var issued: Int64
    public var secret: B64Data?
    public init(request: String, ask: String, decision: String, grant: Int? = nil, approver: String, issued: Int64,
                secret: Data? = nil) {
        self.request = request; self.ask = ask; self.decision = decision; self.grant = grant
        self.approver = approver; self.issued = issued; self.secret = secret.map(B64Data.init)
    }
}

/// A request whose broker and target signatures checked out.
public struct VerifiedRequest: Hashable, Sendable {
    public let envelope: Envelope
    public let request: Request
    public let ask: Ask
    public let requestDigest: Data
    public let askDigest: Data
    public var id: String { ask.id }
    public var code: String { Wire.code(askDigest: askDigest) }

    /// Checks a request against the roster.
    public init(_ env: Envelope, roster: Roster, now: Int64?) throws {
        let request = try env.open(Request.self, type: "request", key: roster.broker.key.data)
        let peek = try request.ask.peek(Ask.self)
        guard let target = roster.target(peek.target) else { throw WireError.unknownTarget }
        let ask = try request.ask.open(Ask.self, type: "ask", key: target.key.data)
        try ask.check(now: now)
        envelope = env; self.request = request; self.ask = ask
        requestDigest = env.digest; askDigest = request.ask.digest
    }

    /// Makes this approver's decision. `signer` is the presence key for an
    /// approval, the presence or transport key for a denial.
    public func decide(_ decision: String, grant: Bool = false, secret: String? = nil, approver: String,
                       signer: EnvelopeSigner, now: Int64) throws -> Envelope {
        var sealed: Data?
        if let secret, decision == DecisionValue.approve, ask.secret != SecretKind.none {
            sealed = try Box.sealSecret(SecretPadding.pad(Data(secret.utf8)), to: request.seal.data, requestDigest: requestDigest)
        }
        let d = Decision(request: Wire.hex(requestDigest), ask: Wire.hex(askDigest), decision: decision,
                         grant: grant && ask.isGrantable && decision == DecisionValue.approve ? Limits.grantMinutes : nil,
                         approver: approver, issued: now, secret: sealed)
        return try Envelope.sign(d, type: "decision", with: signer)
    }

    /// Checks an approver's decision for this request (the target daemon and
    /// the tests use this; `now` is the checker's clock).
    public func verify(decision env: Envelope, roster: Roster, now: Int64) throws -> Decision {
        guard env.t == "decision" else { throw WireError.type }
        let peek = try env.peek(Decision.self)
        guard let approver = roster.approver(peek.approver) else { throw WireError.unknownApprover }
        let viaTransport = env.k == Wire.kid(approver.transport.data)
        let d = try env.open(Decision.self, type: "decision", key: viaTransport ? approver.transport.data : approver.presence.data)
        guard d.v == 1, d.approver == approver.id else { throw WireError.payload }
        guard d.request == Wire.hex(requestDigest), d.ask == Wire.hex(askDigest) else { throw WireError.mismatch }
        switch d.decision {
        case DecisionValue.approve:
            guard !viaTransport else { throw WireError.signer }
        case DecisionValue.deny:
            guard d.grant == nil, d.secret == nil else { throw WireError.payload }
        default:
            throw WireError.payload
        }
        if let g = d.grant, g != Limits.grantMinutes || !ask.isGrantable { throw WireError.payload }
        if d.secret != nil, ask.secret == SecretKind.none { throw WireError.payload }
        guard abs(now - d.issued) <= Limits.clockSkew else { throw WireError.stale }
        guard now < ask.expires else { throw WireError.expired }
        return d
    }
}

// MARK: Handshakes and management

public struct LinkAuth: Codable, Sendable {
    public var v = 1
    public var broker: String, target: String
    public var nonce: B64Data
    public var issued: Int64
    public init(broker: String, target: String, nonce: Data, issued: Int64) {
        self.broker = broker; self.target = target; self.nonce = B64Data(nonce); self.issued = issued
    }
}

public struct HelloAuth: Codable, Sendable {
    public var v = 1
    public var broker: String, approver: String
    public var nonce: B64Data
    public var issued: Int64
    public init(broker: String, approver: String, nonce: Data, issued: Int64) {
        self.broker = broker; self.approver = approver; self.nonce = B64Data(nonce); self.issued = issued
    }
}

/// Authenticates to the relay; `endpoint` binds it to one use: "socket",
/// "inbox", "devices" or "outbox".
public struct RelayAuth: Codable, Sendable {
    public var v = 1
    public var role: String
    public var broker: String
    public var key: B64Data?
    public var approver: String?
    public var endpoint: String
    public var nonce: B64Data
    public var issued: Int64
    public var box: B64Data?
    public var apns: APNsRegistration?
    public init(role: String, broker: String, approver: String?, endpoint: String, nonce: Data, issued: Int64,
                box: Data? = nil, apns: APNsRegistration? = nil) {
        self.role = role; self.broker = broker; self.approver = approver; self.endpoint = endpoint
        self.nonce = B64Data(nonce); self.issued = issued; self.box = box.map(B64Data.init); self.apns = apns
    }
}

public struct APNsRegistration: Codable, Sendable {
    public var token: String
    public var env: String
    public init(token: String, env: String) { self.token = token; self.env = env }
}

/// Asks the target to raise an unlock ask; signed with an approver's
/// transport key (the approval itself then needs its presence key), so the
/// relay and the JetKVM can't make a locked Mac ask for its password.
public struct UnlockRequest: Codable, Sendable {
    public var v = 1
    public var broker: String
    public var target: String
    public var approver: String
    public var nonce: B64Data
    public var issued: Int64
    public init(broker: String, target: String, approver: String, issued: Int64) {
        self.broker = broker; self.target = target; self.approver = approver
        nonce = B64Data(Wire.randomBytes(32)); self.issued = issued
    }

    /// Checks an unlock request for `target` against the roster and clock.
    public static func verify(_ env: Envelope, roster: Roster, target: String, now: Int64) throws -> UnlockRequest {
        let peek = try env.peek(UnlockRequest.self)
        guard let a = roster.approver(peek.approver) else { throw WireError.unknownApprover }
        let u = try env.open(UnlockRequest.self, type: "unlock", key: a.transport.data)
        guard u.v == 1, u.approver == a.id, u.broker == roster.broker.id, u.target == target, u.nonce.data.count == 32 else {
            throw WireError.mismatch
        }
        guard abs(now - u.issued) <= Limits.clockSkew else { throw WireError.stale }
        return u
    }
}

/// A pairing announced to the broker by the token's hash only: the token
/// travels in the QR code, so the broker can't enroll a device of its own.
public struct Pairing: Codable, Sendable {
    public var v = 1
    public var hash: B64Data
    public var expires: Int64
    public init(token: Data, expires: Int64) { hash = B64Data(Pairing.hash(token)); self.expires = expires }

    public static func hash(_ token: Data) -> Data { Data(SHA256.hash(data: token)) }
}

/// A new device's enrollment: the pairing's hash for the broker, and a MAC
/// with the token that only the inviting owner can check.
public struct Enroll: Codable, Sendable {
    public var v = 1
    public var pairing: B64Data
    public var approver: Approver
    public var mac: B64Data
    public init(token: Data, approver: Approver) {
        pairing = B64Data(Pairing.hash(token)); self.approver = approver; mac = B64Data(Enroll.mac(token: token, approver: approver))
    }

    /// HMAC-SHA256 keyed with the token over "BKA1 enroll\n" and the
    /// presence, transport and seal keys, the name and the platform, each
    /// preceded by its 4-byte big-endian length.
    public static func mac(token: Data, approver a: Approver) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: macMessage(a), using: SymmetricKey(data: token)))
    }

    /// Whether the enrollment came from the device that scanned `token`.
    public func matches(token: Data) -> Bool {
        pairing.data == Pairing.hash(token) && HMAC<SHA256>.isValidAuthenticationCode(mac.data, authenticating: Self.macMessage(approver),
                                                                                         using: SymmetricKey(data: token))
    }

    static func macMessage(_ a: Approver) -> Data {
        var msg = Data("BKA1 enroll\n".utf8)
        for part in [a.presence.data, a.transport.data, a.seal.data, Data(a.name.utf8), Data(a.platform.utf8)] {
            let n = UInt32(part.count).bigEndian
            withUnsafeBytes(of: n) { msg.append(contentsOf: $0) }
            msg.append(part)
        }
        return msg
    }
}

/// Secrets are padded with zeros to a multiple of 64 bytes (at least one
/// block), so a box doesn't tell a password's length.
public enum SecretPadding {
    public static let block = 64
    public static func pad(_ secret: Data) -> Data {
        var out = secret
        out.append(Data(count: (secret.count / block + 1) * block - secret.count))
        return out
    }
    public static func unpad(_ padded: Data) -> Data {
        var end = padded.endIndex
        while end > padded.startIndex, padded[padded.index(before: end)] == 0 { end = padded.index(before: end) }
        return padded[padded.startIndex..<end]
    }
}

// MARK: Screen steps

public typealias Stroke = [UInt8] // [HID usage, modifier byte]

public struct KeyMap: Codable, Equatable, Sendable {
    public var map: [String: [Stroke]]
    public init(map: [String: [Stroke]]) { self.map = map }
}

public struct Point: Codable, Equatable, Sendable {
    public var x, y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct Step: Codable, Equatable, Sendable {
    public var click: Point?
    public var keys: [Stroke]?
    public var secret: KeyMap?
    public var erase: Int?
    public init(click: Point? = nil, keys: [Stroke]? = nil, secret: KeyMap? = nil, erase: Int? = nil) {
        self.click = click; self.keys = keys; self.secret = secret; self.erase = erase
    }
}

extension Data {
    /// Decodes lowercase or uppercase hex; nil for anything else.
    public init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        self = out
    }
}
