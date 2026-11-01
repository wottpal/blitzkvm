import CryptoKit
import Foundation

/// The protocol's base64: URL alphabet, no padding (decoding is strict).
public enum B64 {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ string: String) -> Data? {
        guard !string.contains("="), !string.contains("+"), !string.contains("/") else { return nil }
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let rem = s.count % 4
        if rem == 1 { return nil }
        if rem > 0 { s += String(repeating: "=", count: 4 - rem) }
        return Data(base64Encoded: s)
    }
}

/// Bytes that travel as b64 in JSON.
public struct B64Data: Codable, Hashable, Sendable {
    public var data: Data
    public init(_ data: Data) { self.data = data }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let d = B64.decode(s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad b64"))
        }
        data = d
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(B64.encode(data))
    }
}

public enum WireError: Error, Equatable {
    case type, signer, signature, payload, key, open, expired, stale, mismatch, unknownApprover, unknownTarget
    case roster(String), invalid(String)
}

public enum Wire {
    /// A key's id: hex of the first 12 bytes of SHA-256 of its X9.63 bytes.
    public static func kid(_ x963: Data) -> String {
        SHA256.hash(data: x963).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func hex(_ bytes: some Sequence<UInt8>) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    static func signedMessage(type: String, payload: Data) -> Data {
        var msg = Data("BKA1 \(type)\n".utf8)
        msg.append(payload)
        return msg
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    public static let decoder = JSONDecoder()

    public static func randomBytes(_ n: Int) -> Data {
        var b = [UInt8](repeating: 0, count: n)
        // Nonces and ids must never be zeros: stop rather than go on.
        precondition(SecRandomCopyBytes(kSecRandomDefault, n, &b) == errSecSuccess, "no random bytes")
        return Data(b)
    }

    public static func randomID() -> String { hex(randomBytes(16)) }

    /// The ask's matching code: two digits from its digest.
    public static func code(askDigest: Data) -> String {
        String(format: "%02d", ((Int(askDigest[askDigest.startIndex]) << 8) | Int(askDigest[askDigest.startIndex + 1])) % 100)
    }
}

/// Something that signs envelopes: a software key, or a Secure Enclave key
/// (presence keys sign behind Face ID or Touch ID).
public protocol EnvelopeSigner {
    var publicKey: Data { get } // X9.63
    func signature(for message: Data) throws -> Data // raw r || s
}

extension EnvelopeSigner {
    public var id: String { Wire.kid(publicKey) }
}

public struct SoftwareSigner: EnvelopeSigner {
    public let key: P256.Signing.PrivateKey
    public init(_ key: P256.Signing.PrivateKey = .init()) { self.key = key }
    public var publicKey: Data { key.publicKey.x963Representation }
    public func signature(for message: Data) throws -> Data { try key.signature(for: message).rawRepresentation }
}

/// A signed JSON payload.
public struct Envelope: Codable, Hashable, Sendable {
    public var t: String
    public var k: String
    public var p: B64Data
    public var s: B64Data

    public var type: String { t }
    public var payload: Data { p.data }
    public var signedMessage: Data { Wire.signedMessage(type: t, payload: p.data) }

    /// SHA-256 of the signed message.
    public var digest: Data { Data(SHA256.hash(data: signedMessage)) }
    public var digestHex: String { Wire.hex(digest) }

    public static func sign<T: Encodable>(_ payload: T, type: String, with signer: EnvelopeSigner) throws -> Envelope {
        try sign(bytes: Wire.encoder.encode(payload), type: type, with: signer)
    }

    public static func sign(bytes: Data, type: String, with signer: EnvelopeSigner) throws -> Envelope {
        let sig = try signer.signature(for: Wire.signedMessage(type: type, payload: bytes))
        return Envelope(t: type, k: signer.id, p: B64Data(bytes), s: B64Data(sig))
    }

    /// Checks that this is a `type` envelope signed by `key` (X9.63).
    public func verify(type: String, key: Data) throws {
        guard t == type else { throw WireError.type }
        guard k == Wire.kid(key) else { throw WireError.signer }
        guard let pub = try? P256.Signing.PublicKey(x963Representation: key) else { throw WireError.key }
        guard s.data.count == 64, let sig = try? P256.Signing.ECDSASignature(rawRepresentation: s.data),
              pub.isValidSignature(sig, for: signedMessage) else { throw WireError.signature }
    }

    /// verify, then decode the payload.
    public func open<T: Decodable>(_: T.Type, type: String, key: Data) throws -> T {
        try verify(type: type, key: key)
        return try peek(T.self)
    }

    /// Decodes the payload without checking the signature: only to find the
    /// key to check it with.
    public func peek<T: Decodable>(_: T.Type) throws -> T {
        do { return try Wire.decoder.decode(T.self, from: p.data) } catch { throw WireError.payload }
    }
}
