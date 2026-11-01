import ApprovalKit
import Foundation
import LocalAuthentication

/// Where the app keeps the passwords it attaches to approvals.
protocol PasswordVault: AnyObject {
    func store(_ secret: String, target: String, kind: String) throws
    func has(target: String, kind: String) -> Bool
    func remove(target: String, kind: String)
    func secret(target: String, kind: String, context: LAContext?) throws -> String?
}

extension SecretVault: PasswordVault {}

enum Vaults {
    /// SecretVault: a Secure Enclave key behind Face ID on a device, a
    /// software key on the Simulator (development).
    static func make(store: BlobStore) -> PasswordVault { SecretVault(store: store) }
}
