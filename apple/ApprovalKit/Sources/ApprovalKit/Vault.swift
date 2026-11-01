import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Passwords the approver may hand to the broker for one approval: the
/// target's Mac password, the 1Password account password. Each is sealed
/// to a Secure Enclave key-agreement key that needs presence (Touch ID or
/// the Mac's password; Face ID), so reading one needs the same evaluated
/// context that signs the approval. Without a Secure Enclave (Simulator)
/// the key is a software key.
public final class SecretVault {
    private let store: BlobStore
    private static let keyName = "vault.key"
    private static let info = Data("BKA1 vault".utf8)

    public init(store: BlobStore) { self.store = store }

    private func entryName(target: String, kind: String) -> String { "vault.\(target).\(kind)" }

    private func publicKey() throws -> P256.KeyAgreement.PublicKey {
        if let blob = store.load(Self.keyName) {
            if ApproverKeys.hasSecureEnclave {
                // Loading needs no presence: only the agreement does.
                return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob).publicKey
            }
            return try P256.KeyAgreement.PrivateKey(rawRepresentation: blob).publicKey
        }
        if ApproverKeys.hasSecureEnclave {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                               ApproverKeys.presenceFlags, &error) else {
                throw error!.takeRetainedValue() as Error
            }
            let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
            guard store.save(Self.keyName, key.dataRepresentation) else { throw WireError.invalid("keychain") }
            return key.publicKey
        }
        let key = P256.KeyAgreement.PrivateKey()
        guard store.save(Self.keyName, key.rawRepresentation) else { throw WireError.invalid("keychain") }
        return key.publicKey
    }

    private static func symmetricKey(_ shared: SharedSecret, ephemeral: Data) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeral, sharedInfo: info, outputByteCount: 32)
    }

    /// Stores a secret (no presence needed to store).
    public func store(_ secret: String, target: String, kind: String) throws {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: try publicKey())
        let eph = ephemeral.publicKey.x963Representation
        let sealed = try AES.GCM.seal(Data(secret.utf8), using: Self.symmetricKey(shared, ephemeral: eph))
        guard let combined = sealed.combined, store.save(entryName(target: target, kind: kind), eph + combined) else {
            throw WireError.invalid("keychain")
        }
    }

    public func has(target: String, kind: String) -> Bool { store.load(entryName(target: target, kind: kind)) != nil }

    public func remove(target: String, kind: String) { store.remove(entryName(target: target, kind: kind)) }

    /// Reads a secret with an evaluated context (nil prompts by itself).
    public func secret(target: String, kind: String, context: LAContext?) throws -> String? {
        guard let entry = store.load(entryName(target: target, kind: kind)), entry.count > 65,
              let blob = store.load(Self.keyName) else { return nil }
        let eph = entry.prefix(65), combined = entry.dropFirst(65)
        let ephKey = try P256.KeyAgreement.PublicKey(x963Representation: eph)
        let shared: SharedSecret
        if ApproverKeys.hasSecureEnclave {
            shared = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob, authenticationContext: context)
                .sharedSecretFromKeyAgreement(with: ephKey)
        } else {
            shared = try P256.KeyAgreement.PrivateKey(rawRepresentation: blob).sharedSecretFromKeyAgreement(with: ephKey)
        }
        let box = try AES.GCM.SealedBox(combined: combined)
        let plain = try AES.GCM.open(box, using: Self.symmetricKey(shared, ephemeral: Data(eph)))
        return String(data: plain, encoding: .utf8)
    }
}
