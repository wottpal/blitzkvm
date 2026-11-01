import LocalAuthentication

/// One Face ID prompt per approval: the evaluated context then unlocks the
/// Secure Enclave presence key and the vault without asking again.
enum Biometrics {
    static func authenticate(_ context: LAContext, reason: String) async throws {
        // The presence key needs the enrolled face, so a passcode fallback
        // would only fail later.
        context.localizedFallbackTitle = ""
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            _ = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            return
        }
        #if targetEnvironment(simulator)
        // Development keys: Face ID when enrolled (Features › Face ID), else nothing.
        return
        #else
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return
        }
        throw error ?? LAError(.biometryNotAvailable)
        #endif
    }

    /// The SF Symbol of the device's biometry.
    static var symbol: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return "faceid"
        }
    }
}
