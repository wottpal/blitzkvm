import ApprovalKit
import SwiftUI

/// Enters a computer's password for the vault (stored after a Face ID).
struct PasswordSheet: View {
    let targetID: String
    let targetName: String
    let kind: String
    @Environment(ApproverSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var saving = false
    @State private var error: String?

    private var valid: Bool { !password.isEmpty && password == confirmation }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Password", text: $password)
                    SecureField("Repeat Password", text: $confirmation)
                        .onSubmit(save)
                } footer: {
                    Text(footer)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle(KindInfo.secretName(kind))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button("Save", action: save).disabled(!valid) }
                }
            }
        }
    }

    private var footer: String {
        let what = kind == SecretKind.mac ? "the password of your account on \(targetName)" : "your 1Password account password on \(targetName)"
        return "Enter \(what). It is sealed to this iPhone's Secure Enclave, read only with Face ID, and sent only with an approval that asks for it, sealed to that request."
    }

    private func save() {
        guard valid, !saving else { return }
        if password != confirmation { error = "The passwords don't match."; return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await session.storePassword(password, target: targetID, targetName: targetName, kind: kind)
                dismiss()
            } catch let e where ErrorText.isCancellation(e) {
            } catch {
                self.error = ErrorText.describe(error)
            }
        }
    }
}
