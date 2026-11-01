import ApprovalKit
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ApproverSession.self) private var session
    @EnvironmentObject private var center: ApprovalCenter
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                passwords
                notifications
                thisIPhone
                about
            }
            .navigationTitle("Settings")
            .task { await model.refreshNotificationStatus() }
            .onAppear { name = session.name }
            .onDisappear { session.rename(name) }
        }
    }

    private var passwords: some View {
        Section {
            let targets = session.targets
            if targets.isEmpty {
                Text("No computers yet").foregroundStyle(.secondary)
            }
            ForEach(targets, id: \.target.id) { entry in
                NavigationLink {
                    TargetPasswordsView(targetID: entry.target.id, targetName: entry.target.name)
                } label: {
                    LabeledContent {
                        Text(storedSummary(entry.target.id))
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.target.name)
                                if targets.filter({ $0.target.name == entry.target.name }).count > 1 {
                                    Text(entry.broker.name).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "desktopcomputer")
                        }
                    }
                }
            }
        } header: {
            Text("Passwords")
        } footer: {
            Text("A stored password is sealed to this iPhone's Secure Enclave and read only with Face ID. It is sent only with an approval whose request asks for it.")
        }
    }

    private func storedSummary(_ target: String) -> String {
        let count = KindInfo.secretKinds.filter { session.hasPassword(target: target, kind: $0) }.count
        return count == 0 ? "None" : "\(count) stored"
    }

    @ViewBuilder
    private var notifications: some View {
        let status = model.notifications
        Section {
            LabeledContent("Notifications") {
                switch status.authorization {
                case .notDetermined:
                    Button("Allow") {
                        Task {
                            await Notifications.requestAuthorization()
                            await model.refreshNotificationStatus()
                        }
                    }
                case .denied:
                    Button("Off · Open Settings") { openNotificationSettings() }
                default:
                    Text("On")
                }
            }
            if status.timeSensitive != .notSupported {
                LabeledContent("Time Sensitive", value: status.timeSensitive == .enabled ? "On" : "Off")
            }
            LabeledContent("Push", value: session.deviceToken == nil ? "Not registered" : "Registered")
        } header: {
            Text("Notifications")
        } footer: {
            if status.authorization == .denied {
                Text("Without notifications, requests only show while BlitzKVM is open.")
            } else if status.timeSensitive == .disabled {
                Text("Time Sensitive notifications are off, so a Focus can hold requests back until they expire.")
            } else {
                Text("Requests arrive as Time Sensitive notifications. Deny right from the notification; approving opens BlitzKVM.")
            }
        }
    }

    private var thisIPhone: some View {
        Section {
            LabeledContent("Name") {
                TextField("Name", text: $name)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
                    .onSubmit { session.rename(name) }
            }
            LabeledContent("Approver ID") {
                Text(Format.grouped(session.keys.id))
                    .font(.footnote.monospaced())
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            if session.keys.hardwareBacked {
                LabeledContent("Keys", value: "Secure Enclave")
            } else {
                NoticeRow(symbol: "exclamationmark.triangle.fill", tint: .orange, title: "Development Keys",
                          text: "This build signs with software keys, not the Secure Enclave. For development only.")
            }
        } header: {
            Text("This iPhone")
        } footer: {
            Text("Owners see this name when the iPhone asks to pair. A JetKVM keeps the name it was paired with.")
        }
    }

    private var about: some View {
        Section("About") {
            LabeledContent("Version", value: Self.version)
            if let url = URL(string: "https://github.com/wottpal/blitzkvm") {
                Link("Source Code", destination: url)
            }
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private func openNotificationSettings() {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
    }
}

/// The passwords stored for one computer.
struct TargetPasswordsView: View {
    let targetID: String
    let targetName: String
    @Environment(ApproverSession.self) private var session
    @State private var editing: String?
    @State private var removing: String?

    var body: some View {
        Form {
            ForEach(KindInfo.secretKinds, id: \.self) { kind in
                Section {
                    let stored = session.hasPassword(target: targetID, kind: kind)
                    LabeledContent(KindInfo.secretName(kind), value: stored ? "Stored" : "Not stored")
                    Button(stored ? "Replace…" : "Set…") { editing = kind }
                    if stored {
                        Button("Remove", role: .destructive) { removing = kind }
                    }
                } footer: {
                    Text(kind == SecretKind.mac
                         ? "Typed into macOS password dialogs and the lock screen when you approve them."
                         : "Typed into 1Password's unlock prompt when you approve it.")
                }
            }
        }
        .navigationTitle(targetName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(get: { editing.map(KindItem.init) }, set: { editing = $0?.id })) { item in
            PasswordSheet(targetID: targetID, targetName: targetName, kind: item.id)
                .environment(session)
        }
        .confirmationDialog("Remove the \(removing.map(KindInfo.secretName) ?? "password")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let removing { session.removePassword(target: targetID, kind: removing) }
            }
        }
    }

    private struct KindItem: Identifiable { let id: String }
}
