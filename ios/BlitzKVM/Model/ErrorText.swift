import ApprovalKit
import Foundation
import LocalAuthentication

/// An error with a message for the user.
struct UserError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Turns errors into what the user reads.
enum ErrorText {
    /// The user dismissed Face ID (or the system did): nothing to show.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let e = error as? LAError { return [.userCancel, .appCancel, .systemCancel, .userFallback].contains(e.code) }
        return false
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? UserError { return e.message }
        if let e = error as? LAError {
            switch e.code {
            case .biometryNotEnrolled: return "Set up Face ID to approve requests."
            case .biometryLockout: return "Face ID is locked. Unlock iPhone with its passcode, then try again."
            case .passcodeNotSet: return "Set a passcode and Face ID to approve requests."
            case .authenticationFailed: return "Face ID didn't recognize you."
            default: return e.localizedDescription
            }
        }
        if let e = error as? URLError { return "Couldn't reach the relay: \(e.localizedDescription)" }
        if let e = error as? WireError {
            if case let .invalid(message) = e, let status = relayStatus(message) { return describeRelay(status) }
            switch e {
            case .expired: return "This request has expired."
            case .stale: return "This iPhone's clock is off. Set it automatically in Settings › General › Date & Time."
            default: return "The message didn't check out (\(e))."
            }
        }
        return error.localizedDescription
    }

    /// The HTTP status of a RelayHTTP error ("relay outbox: 403").
    static func relayStatus(_ message: String) -> Int? {
        guard message.hasPrefix("relay "), let last = message.split(separator: " ").last else { return nil }
        return Int(last)
    }

    static func describeRelay(_ status: Int) -> String {
        switch status {
        case 401: "The relay refused the request. Check that this iPhone sets its clock automatically."
        case 403: "The relay doesn't list this iPhone yet: no owner has admitted it."
        case 404: "The relay doesn't know this JetKVM yet: it hasn't connected to the relay."
        case 429: "Too many attempts. Try again later."
        case 0: "The relay didn't answer."
        default: "The relay answered with error \(status)."
        }
    }
}
