import CryptoKit
import Foundation
import Security

/// Trust on first use for https devices, matching the engine (Go tlspin):
/// the device's self-signed CA is pinned (or, without one, the leaf); a
/// publicly trusted device is pinned to public trust ("webpki"). The probe
/// sends no credentials; the engine enforces the pin before logging in.
public enum CertificatePin {
    public static let webPKI = "webpki"

    public static func fingerprint(_ der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether a chain macOS built (leaf first; each certificate signed by
    /// the next) contains the pinned certificate. Without a pin any chain is
    /// acceptable (first use).
    public static func accepts(chain: [Data], pin: String?) -> Bool {
        guard !chain.isEmpty else { return false }
        guard let pin, !pin.isEmpty else { return true }
        return chain.contains { fingerprint($0) == pin.lowercased() }
    }

    /// Evaluates a server trust against the pin.
    public static func accepts(_ trust: SecTrust, pin: String?) -> Bool {
        let systemTrusted = SecTrustEvaluateWithError(trust, nil)
        switch pin {
        case nil, "":
            return true
        case webPKI:
            return systemTrusted
        default:
            let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []).map { SecCertificateCopyData($0) as Data }
            return accepts(chain: chain, pin: pin)
        }
    }
}

/// URLSession delegate for probing https devices with CertificatePin.
final class PinningDelegate: NSObject, URLSessionDelegate {
    private let pin: String?

    init(pin: String?) {
        self.pin = pin
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if CertificatePin.accepts(trust, pin: pin) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
