import Darwin
import Foundation
import Security

/// Who signed a running process, as far as its signature proves it. Only
/// what a requirement check confirmed counts: an identifier or Team ID read
/// from an unverified signature is no identity.
public struct CodeIdentity: Equatable {
    /// The signing identifier (an app's bundle identifier).
    public var identifier: String?
    /// Signed by Apple as part of macOS (`anchor apple`).
    public var apple: Bool
    /// The Developer ID team, when the signature chains to Apple's CA and
    /// the leaf certificate names this team.
    public var team: String?
    public var adhoc: Bool
    public var signed: Bool

    public init(identifier: String?, apple: Bool = false, team: String? = nil, adhoc: Bool = false, signed: Bool = true) {
        self.identifier = identifier; self.apple = apple; self.team = team; self.adhoc = adhoc; self.signed = signed
    }

    /// The protocol's `signer`: apple, developer:<team>, adhoc or unsigned.
    /// A signature from a certificate Apple didn't issue proves nothing
    /// either, so it counts as adhoc.
    public var signer: String {
        if apple { return "apple" }
        if let team { return "developer:\(team)" }
        return signed ? "adhoc" : "unsigned"
    }

    public func isApple(_ identifiers: Set<String>) -> Bool { apple && identifier.map(identifiers.contains) == true }

    public func isDeveloper(team: String, identifier id: String) -> Bool { self.team == team && identifier == id }
}

public enum CodeSigning {
    /// The identity of a running process by pid (root sees any process).
    public static func identity(pid: Int32) -> CodeIdentity? {
        identity(of: guest([kSecGuestAttributePid: NSNumber(value: pid)]))
    }

    /// By audit token: a socket peer's, immune to pid reuse.
    public static func identity(auditToken: audit_token_t) -> CodeIdentity? {
        identity(of: guest(auditToken: auditToken))
    }

    public static func satisfies(auditToken: audit_token_t, requirement: String) -> Bool {
        guard let code = guest(auditToken: auditToken) else { return false }
        return check(code, requirement)
    }

    /// This process's own signature.
    public static func ownIdentity() -> CodeIdentity? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess else { return nil }
        return identity(of: code)
    }

    /// What an agent's signature must satisfy: the daemon's own team and the
    /// remote's identifier.
    public static func agentRequirement(team: String) -> String {
        "anchor apple generic and identifier \"xyz.scio.blitzkvm.remote\" and certificate leaf[subject.OU] = \"\(team)\""
    }

    static func guest(auditToken: audit_token_t) -> SecCode? {
        var token = auditToken
        let data = withUnsafeBytes(of: &token) { Data($0) }
        return guest([kSecGuestAttributeAudit: data as NSData])
    }

    static func guest(_ attributes: [CFString: Any]) -> SecCode? {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code) == errSecSuccess else { return nil }
        return code
    }

    static func check(_ code: SecCode, _ requirement: String?) -> Bool {
        var req: SecRequirement?
        if let requirement {
            guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess else { return false }
        }
        return SecCodeCheckValidity(code, [], req) == errSecSuccess
    }

    static func identity(of code: SecCode?) -> CodeIdentity? {
        guard let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var infoRef: CFDictionary?
        let status = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef)
        let info = (infoRef as? [String: Any]) ?? [:]
        let identifier = info[kSecCodeInfoIdentifier as String] as? String
        guard status == errSecSuccess, identifier != nil, check(code, nil) else {
            return CodeIdentity(identifier: nil, signed: false)
        }
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        var id = CodeIdentity(identifier: identifier, adhoc: flags & SecCodeSignatureFlags.adhoc.rawValue != 0)
        if check(code, "anchor apple") {
            id.apple = true
        } else if let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
                  team.allSatisfy({ $0.isLetter || $0.isNumber }),
                  check(code, "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"") {
            id.team = team
        }
        return id
    }
}
