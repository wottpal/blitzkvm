import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// A Secure Enclave signing key. With an access control that requires
/// presence, `signature` asks for Face ID / Touch ID unless `context` was
/// already evaluated.
public struct SecureEnclaveSigner: EnvelopeSigner {
    public let blob: Data
    public let publicKey: Data
    public var context: LAContext?

    public init(blob: Data, context: LAContext? = nil) throws {
        let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context)
        self.blob = blob
        publicKey = key.publicKey.x963Representation
        self.context = context
    }

    public func signature(for message: Data) throws -> Data {
        let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context)
        return try key.signature(for: message).rawRepresentation
    }

    public func with(context: LAContext) -> SecureEnclaveSigner {
        var copy = self
        copy.context = context
        return copy
    }
}

/// Where key blobs and small files live: the keychain on both platforms.
public protocol BlobStore {
    func load(_ name: String) -> Data?
    func save(_ name: String, _ data: Data) -> Bool
    func remove(_ name: String)
}

/// Generic password items. `accessGroup` shares them with an app
/// extension (iOS); macOS uses the login keychain, which needs no
/// provisioning profile.
public struct KeychainBlobStore: BlobStore {
    public let service: String
    public let accessGroup: String?

    public init(service: String = "xyz.scio.blitzkvm.approvals", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func base(_ name: String) -> [CFString: Any] {
        var q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name]
        if let accessGroup { q[kSecAttrAccessGroup] = accessGroup }
        return q
    }

    public func load(_ name: String) -> Data? {
        var q = base(name)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    public func save(_ name: String, _ data: Data) -> Bool {
        let status = SecItemUpdate(base(name) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = base(name)
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public func remove(_ name: String) { SecItemDelete(base(name) as CFDictionary) }
}

/// A BlobStore in memory, for tests.
public final class MemoryBlobStore: BlobStore {
    private var items: [String: Data] = [:]
    public init() {}
    public func load(_ name: String) -> Data? { items[name] }
    public func save(_ name: String, _ data: Data) -> Bool { items[name] = data; return true }
    public func remove(_ name: String) { items[name] = nil }
}

/// This approver's keys: presence (approvals, behind biometrics), transport
/// (connections, denials) and seal (opens what the broker sends).
public struct ApproverKeys {
    public let presence: EnvelopeSigner
    public let transport: EnvelopeSigner
    public let seal: SealKey
    /// False on a Simulator or a Mac without a Secure Enclave: the keys are
    /// software keys, for development only.
    public let hardwareBacked: Bool
    public var id: String { presence.id }

    public init(presence: EnvelopeSigner, transport: EnvelopeSigner, seal: SealKey, hardwareBacked: Bool) {
        self.presence = presence; self.transport = transport; self.seal = seal; self.hardwareBacked = hardwareBacked
    }

    /// Whether keys can live in a Secure Enclave here. The Simulator claims
    /// one (`SecureEnclave.isAvailable`) but refuses to make keys in it.
    public static var hasSecureEnclave: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return SecureEnclave.isAvailable
        #endif
    }

    public func approver(name: String, platform: String) -> Approver {
        Approver(name: name, platform: platform, presence: presence.publicKey, transport: transport.publicKey,
                 seal: seal.publicKey)
    }

    /// The presence key bound to an evaluated context, so one Face ID or
    /// Touch ID covers the signature and the vault.
    public func presence(with context: LAContext) -> EnvelopeSigner {
        (presence as? SecureEnclaveSigner)?.with(context: context) ?? presence
    }

    /// Presence flags: Touch ID or the Mac's password on a Mac, the
    /// currently enrolled Face ID on an iPhone.
    public static var presenceFlags: SecAccessControlCreateFlags {
        #if os(iOS)
        return [.privateKeyUsage, .biometryCurrentSet]
        #else
        return [.privateKeyUsage, .userPresence]
        #endif
    }

    /// Forgets the keys (an iPhone's stop working for good when Face ID
    /// changes) and the vault's: the next loadOrCreate makes new ones, and
    /// pairing starts over.
    public static func reset(in store: BlobStore) {
        for name in ["presence", "transport", "seal", "vault.key"] { store.remove(name) }
    }

    /// Loads the keys, making them the first time.
    public static func loadOrCreate(in store: BlobStore) throws -> ApproverKeys {
        let hardware = hasSecureEnclave
        func signer(_ name: String, flags: SecAccessControlCreateFlags) throws -> EnvelopeSigner {
            if let blob = store.load(name) {
                return hardware ? try SecureEnclaveSigner(blob: blob)
                    : SoftwareSigner(try P256.Signing.PrivateKey(rawRepresentation: blob))
            }
            if hardware {
                var error: Unmanaged<CFError>?
                guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                                   flags, &error) else {
                    throw error!.takeRetainedValue() as Error
                }
                let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
                guard store.save(name, key.dataRepresentation) else { throw WireError.invalid("keychain") }
                return try SecureEnclaveSigner(blob: key.dataRepresentation)
            }
            let key = P256.Signing.PrivateKey()
            guard store.save(name, key.rawRepresentation) else { throw WireError.invalid("keychain") }
            return SoftwareSigner(key)
        }
        let presence = try signer("presence", flags: presenceFlags)
        let transport = try signer("transport", flags: [.privateKeyUsage])
        let seal: SealKey
        if let raw = store.load("seal") {
            seal = SealKey(try P256.KeyAgreement.PrivateKey(rawRepresentation: raw))
        } else {
            seal = SealKey()
            guard store.save("seal", seal.key.rawRepresentation) else { throw WireError.invalid("keychain") }
        }
        return ApproverKeys(presence: presence, transport: transport, seal: seal, hardwareBacked: hardware)
    }
}
