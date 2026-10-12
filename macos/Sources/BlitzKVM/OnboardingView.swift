import SwiftUI

/// The welcome screen: the two permissions BlitzKVM needs, each with its
/// state and the one action that grants it. Continue needs Local Network;
/// Accessibility can follow later.
struct OnboardingView: View {
    @ObservedObject var permissions: PermissionsModel

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)
            Text("Welcome to BlitzKVM")
                .font(.title.weight(.semibold))
                .padding(.top, 10)
            Text("Two permissions, and BlitzKVM is ready.")
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            Form {
                Section {
                    localNetworkRow
                    accessibilityRow
                } footer: {
                    Text("Change these anytime in System Settings › Privacy & Security.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
        .frame(minWidth: 580, minHeight: 500)
        .navigationTitle("Welcome")
        .animation(.snappy(duration: 0.2), value: permissions.localNetwork)
        .animation(.snappy(duration: 0.2), value: permissions.accessibility)
    }

    private var allowed: Bool { permissions.localNetwork == .allowed }

    private var localNetworkRow: some View {
        let state = permissions.localNetwork
        return StatusRow(symbol: "network", tint: .blue, title: "Local Network", tag: "Required",
                         state: localNetworkState, note: state == .denied
                             ? "Turn on BlitzKVM in Privacy & Security › Local Network."
                             : "Reach your JetKVMs on this network.") {
            switch state {
            case .allowed:
                DoneBadge(title: "Allowed")
            case .asking:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Waiting for your answer")
            case .notAsked:
                Button("Allow…", action: permissions.allowLocalNetwork)
            case .denied:
                Button("Open Settings…", action: permissions.allowLocalNetwork)
            }
        }
    }

    private var localNetworkState: String {
        switch permissions.localNetwork {
        case .notAsked: return "Not allowed yet"
        case .asking: return "Waiting for your answer…"
        case .allowed: return "Allowed"
        case .denied: return "Turned off"
        }
    }

    private var accessibilityRow: some View {
        StatusRow(symbol: "keyboard", tint: .purple, title: "Accessibility", tag: "Recommended",
                  state: permissions.accessibility ? "Allowed" : "Not allowed yet",
                  note: "Send ⌘Tab and ⌘Space to the remote computer.") {
            if permissions.accessibility {
                DoneBadge(title: "Allowed")
            } else {
                Button("Allow…", action: permissions.allowAccessibility)
            }
        }
    }
}
