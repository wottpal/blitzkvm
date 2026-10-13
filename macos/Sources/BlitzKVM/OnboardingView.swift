import SwiftUI

/// The welcome screen: the two permissions BlitzKVM needs, each with its
/// state and the one action that grants it. Continue needs Local Network;
/// Accessibility can follow later. BlitzKVM › Settings… shows the same
/// permissions afterwards.
struct OnboardingView: View {
    @ObservedObject var permissions: PermissionsModel

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(iconSize: 88, title: "Welcome to BlitzKVM", subtitle: "Two permissions, and BlitzKVM is ready.")
            Form {
                PermissionsSection(permissions: permissions)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(width: 540)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                if !allowed {
                    Button("Skip", action: permissions.finishOnboarding)
                }
                Spacer()
                Button("Continue", action: permissions.finishOnboarding)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!allowed)
            }
            .frame(width: 500)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 580, minHeight: 460)
        .navigationTitle("Welcome")
    }

    private var allowed: Bool { permissions.localNetwork == .allowed }
}
