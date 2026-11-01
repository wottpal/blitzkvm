import ApprovalKit

/// How the app names and draws an ask's kind and the secret it needs.
enum KindInfo {
    static func name(_ kind: String) -> String {
        switch kind {
        case Kind.sudo: "sudo"
        case Kind.confirm: "Confirmation"
        case Kind.onePassword: "1Password"
        case Kind.securityAgent: "Password dialog"
        case Kind.unlock: "Unlock screen"
        default: kind
        }
    }

    static func symbol(_ kind: String) -> String {
        switch kind {
        case Kind.sudo: "apple.terminal"
        case Kind.confirm: "checkmark.shield"
        case Kind.onePassword: "key.horizontal"
        case Kind.securityAgent: "lock.shield"
        case Kind.unlock: "lock.open"
        default: "questionmark.circle"
        }
    }

    /// The password a secret kind stands for ("Mac password").
    static func secretName(_ secret: String) -> String {
        switch secret {
        case SecretKind.mac: "Mac password"
        case SecretKind.onePassword: "1Password password"
        default: secret
        }
    }

    /// The secret kinds a target can have stored, in display order.
    static let secretKinds = [SecretKind.mac, SecretKind.onePassword]
}
