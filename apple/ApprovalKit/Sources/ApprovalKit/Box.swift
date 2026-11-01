import CryptoKit
import Foundation

/// HPKE boxes (DHKEM P-256, HKDF-SHA256, AES-256-GCM, base mode).
public enum Box {
    static let suite = HPKE.Ciphersuite.P256_SHA256_AES_GCM_256
    static let infoBox = Data("BKA1 box".utf8)
    static let infoSecret = Data("BKA1 secret".utf8)
    static let encSize = 65

    static func seal(to x963: Data, info: Data, aad: Data, plaintext: Data) throws -> Data {
        guard let key = try? P256.KeyAgreement.PublicKey(x963Representation: x963) else { throw WireError.key }
        var sender = try HPKE.Sender(recipientKey: key, ciphersuite: suite, info: info)
        let ct = try sender.seal(plaintext, authenticating: aad)
        return sender.encapsulatedKey + ct
    }

    static func open(_ box: Data, with key: P256.KeyAgreement.PrivateKey, info: Data, aad: Data) throws -> Data {
        guard box.count >= encSize + 16 else { throw WireError.open }
        let enc = box.prefix(encSize), ct = box.dropFirst(encSize)
        do {
            var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: suite, info: info, encapsulatedKey: Data(enc))
            return try recipient.open(Data(ct), authenticating: aad)
        } catch {
            throw WireError.open
        }
    }

    /// Seals a message to a seal key (X9.63).
    public static func seal(_ message: Data, to x963: Data) throws -> Data {
        try seal(to: x963, info: infoBox, aad: Data(Wire.kid(x963).utf8), plaintext: message)
    }

    /// Seals a secret to a request's seal key, bound to the request.
    public static func sealSecret(_ secret: Data, to x963: Data, requestDigest: Data) throws -> Data {
        try seal(to: x963, info: infoSecret, aad: requestDigest, plaintext: secret)
    }
}

/// A key-agreement key that opens boxes.
public struct SealKey {
    public let key: P256.KeyAgreement.PrivateKey
    public init(_ key: P256.KeyAgreement.PrivateKey = .init()) { self.key = key }
    public var publicKey: Data { key.publicKey.x963Representation }
    public var id: String { Wire.kid(publicKey) }

    public func open(_ box: Data) throws -> Data {
        try Box.open(box, with: key, info: Box.infoBox, aad: Data(id.utf8))
    }

    public func openSecret(_ box: Data, requestDigest: Data) throws -> Data {
        try Box.open(box, with: key, info: Box.infoSecret, aad: requestDigest)
    }
}
