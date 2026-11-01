import AppKit
import ApprovalKit
import JetKVMCore
import ServiceManagement
import SwiftUI

/// Settings › Approvals: per JetKVM with approvals, its approvers and
/// computer, pairing an iPhone, the stored passwords; the relay; whether
/// approvals start BlitzKVM at login.
struct ApprovalsSettings: View {
    @ObservedObject var service: ApprovalService

    var body: some View {
        if let center = service.center, !center.brokers.isEmpty {
            ApprovalBrokers(service: service, center: center)
        } else {
            Section {
                Text("No JetKVM uses approvals yet.")
            } footer: {
                SettingsFooter("Turn them on in JetKVM Setup (Device › Set Up JetKVM): sudo, password dialogs and 1Password "
                    + "on the remote computer then ask here and on your iPhone, and you approve with Touch ID.")
            }
        }
        RelaySection(service: service)
        ApprovalsGeneralSection(service: service)
    }
}

private struct ApprovalBrokers: View {
    @ObservedObject var service: ApprovalService
    @ObservedObject var center: ApprovalCenter

    var body: some View {
        ForEach(center.brokers) { broker in
            BrokerSection(service: service, center: center, broker: broker)
        }
    }
}

/// One JetKVM: its approvers, its computer and the passwords stored for it.
private struct BrokerSection: View {
    @ObservedObject var service: ApprovalService
    @ObservedObject var center: ApprovalCenter
    let broker: PairedBroker
    @AppStorage(ApprovalService.relayKey) private var relayText = ""
    @State private var invite: PairingInvite?
    @State private var revoking: ApproverLine?
    @State private var editing: PasswordEdit?
    @State private var forgetting = false
    @State private var error: String?

    private var me: String { center.keys.id }
    private var isOwner: Bool { center.isOwner(broker.id) }

    var body: some View {
        let roster = broker.decodedRoster
        Section {
            if let roster {
                ForEach(ApproverLine.lines(roster, me: me)) { approverRow($0) }
                ForEach(roster.targets, id: \.id) { target in
                    targetRows(target)
                }
            } else {
                Text("Waiting for the JetKVM's approvers…").foregroundStyle(.secondary)
            }
            if isOwner, invite == nil { // the pairing sheet lists them while it shows
                ForEach(center.enrollments.filter { $0.brokerID == broker.id }) {
                    EnrollmentRow(service: service, center: center, enrollment: $0)
                }
            }
            actions(roster)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            HStack {
                Text(broker.name)
                Spacer()
                Text(connection).foregroundStyle(.secondary).font(.callout)
            }
        }
        .sheet(item: Binding(get: { invite.map(InviteItem.init) }, set: { if $0 == nil { invite = nil } })) { item in
            PairingSheet(service: service, center: center, brokerID: broker.id, invite: item.invite) { invite = $0 }
        }
        .sheet(item: $editing) { edit in
            StoredPasswordSheet(edit: edit) { password in
                do {
                    try service.storePassword(password, target: edit.target.id, kind: edit.kind)
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
        .alert("Revoke \(revoking?.name ?? "")?", isPresented: Binding { revoking != nil } set: { if !$0 { revoking = nil } },
               presenting: revoking) { approver in
            Button("Revoke", role: .destructive) { revoke(approver) }
            Button("Cancel", role: .cancel) {}
        } message: { approver in
            Text("\(approver.name) stops getting requests from \(broker.name), and can't approve them any more.")
        }
        .alert("Forget \(broker.name) on this Mac?", isPresented: $forgetting) {
            Button("Forget", role: .destructive) { center.remove(brokerID: broker.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This Mac stops getting its requests. The JetKVM keeps its approvals: turn them off in JetKVM Setup.")
        }
    }

    private var connection: String {
        let routes = service.routes[broker.id] ?? []
        if routes.contains(.direct) { return "Connected" }
        if routes.contains(.relay) { return "Connected through the relay" }
        return "Not connected"
    }

    private func approverRow(_ a: ApproverLine) -> some View {
        HStack(spacing: 10) {
            Image(systemName: a.symbol)
                .frame(width: 20)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(a.isMe ? "\(a.name) (this Mac)" : a.name)
            if a.owner { Tag("Owner") }
            Spacer()
            if isOwner && !a.isMe {
                Button("Revoke…") { revoking = a }
            }
        }
    }

    @ViewBuilder
    private func targetRows(_ target: Target) -> some View {
        let _ = service.vaultRevision // stored passwords
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer")
                .frame(width: 20)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(target.name)
            Tag("Computer")
            Spacer()
            Button("Unlock…") {
                do {
                    try service.unlock(brokerID: broker.id, target: target.id)
                } catch {
                    self.error = error.localizedDescription
                }
            }
            .help("Asks \(target.name) to unlock its screen: if it's locked, a request comes up here, and approving it types the Mac's password there.")
        }
        ForEach(ApprovalSummary.passwordKinds, id: \.self) { kind in
            let stored = service.hasPassword(target: target.id, kind: kind)
            LabeledContent {
                if stored {
                    HStack(spacing: 8) {
                        Button("Replace…") { editing = PasswordEdit(target: target, kind: kind) }
                        Button("Remove") { service.removePassword(target: target.id, kind: kind) }
                    }
                } else {
                    Button("Set…") { editing = PasswordEdit(target: target, kind: kind) }
                }
            } label: {
                Text(ApprovalSummary.passwordName(kind).prefix(1).uppercased() + ApprovalSummary.passwordName(kind).dropFirst())
                Text(stored ? "Stored on this Mac, behind Touch ID." : "Not stored: asked for when a request needs it.")
            }
        }
    }

    /// Owners pair and change the relay; anyone can forget a JetKVM here.
    private func actions(_ roster: Roster?) -> some View {
        let relay = ApprovalAddress.relay(relayText)
        return HStack {
            if isOwner {
                Button("Pair iPhone…") { pair() }
                if let roster, relay != roster.relay, relay != nil || roster.relay != nil {
                    Button(relay == nil ? "Stop Using the Relay" : "Use Relay") { useRelay(relay) }
                        .help(relay.map { "Requests from \(broker.name) also go through \($0)." } ?? "")
                }
            }
            Spacer()
            Button("Forget…") { forgetting = true }
        }
    }

    private func pair() {
        error = nil
        Task {
            do {
                invite = try await service.signAsOwner(reason: "pair an iPhone with \(broker.name)") { presence in
                    try center.invite(broker.id, presence: presence)
                }
            } catch where ApprovalService.isCancellation(error) {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func revoke(_ approver: ApproverLine) {
        error = nil
        Task {
            do {
                try await service.signAsOwner(reason: "revoke \(approver.name) for \(broker.name)") { presence in
                    try center.revoke(approver.id, brokerID: broker.id, presence: presence)
                }
            } catch where ApprovalService.isCancellation(error) {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func useRelay(_ relay: String?) {
        error = nil
        Task {
            do {
                try await service.signAsOwner(reason: "change the relay of \(broker.name)") { presence in
                    try center.update(broker.id, presence: presence) { $0.relay = relay }
                }
            } catch where ApprovalService.isCancellation(error) {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct InviteItem: Identifiable {
    let invite: PairingInvite
    var id: String { B64.encode(invite.token.data) }
}

/// A capsule after a name ("Owner").
private struct Tag: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }
}

/// The relay: carries sealed boxes to approvers away from the JetKVM's
/// network, and push notifications to iPhones.
private struct RelaySection: View {
    @ObservedObject var service: ApprovalService
    @AppStorage(ApprovalService.relayKey) private var relayText = ""

    var body: some View {
        Section {
            TextField("Relay URL", text: $relayText, prompt: Text("https://relay.example.workers.dev"))
                .autocorrectionDisabled()
        } header: {
            Text("Relay")
        } footer: {
            SettingsFooter(!relayText.isEmpty && ApprovalAddress.relay(relayText) == nil
                ? "Not a URL: it starts with https://."
                : "Reaches your iPhone, and this Mac away from the JetKVM's network. It only ever sees sealed messages. "
                    + "JetKVMs turned on from now use it; Use Relay applies it to one already on.")
        }
    }
}

/// Starting at login, and what this Mac's keys are.
private struct ApprovalsGeneralSection: View {
    @ObservedObject var service: ApprovalService
    @State private var startsAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var notifications: Bool?

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { startsAtLogin }, set: setStartsAtLogin)) {
                Text("Approvals start BlitzKVM at login")
                Text("So requests reach this Mac without opening BlitzKVM first.")
            }
            if notifications == false {
                LabeledContent {
                    Button("Open Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                } label: {
                    Text("Notifications are off")
                    Text("Requests still show in a panel while BlitzKVM runs.")
                }
            }
        } footer: {
            SettingsFooter(loginError ?? (service.hardwareBacked
                ? "This Mac's approval keys are in its Secure Enclave and never leave it."
                : "This Mac has no Secure Enclave: its approval keys are software keys, for development only."))
        }
        .task { notifications = await service.notifications.authorized() }
    }

    private func setStartsAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change the login item: \(error.localizedDescription)"
        }
        startsAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Pairing

/// The invite as a QR code for the iPhone app, for 5 minutes, and the
/// devices that enrolled with it: an owner adds each with Touch ID.
private struct PairingSheet: View {
    @ObservedObject var service: ApprovalService
    @ObservedObject var center: ApprovalCenter
    let brokerID: String
    let invite: PairingInvite
    /// A new invite, or nil to close.
    let replace: (PairingInvite?) -> Void
    @State private var issued = Date()
    @State private var error: String?

    private static let lifetime: TimeInterval = 300

    var body: some View {
        let enrollments = center.enrollments.filter { $0.brokerID == brokerID }
        VStack(spacing: 0) {
            Text("Pair an iPhone")
                .font(.title3.weight(.semibold))
                .padding(.top, 20)
            Text("Scan this with BlitzKVM on the iPhone.")
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = Int64(Self.lifetime - context.date.timeIntervalSince(issued))
                VStack(spacing: 8) {
                    QRImage(text: invite.qrString)
                        .opacity(left > 0 ? 1 : 0.15)
                        .overlay {
                            if left <= 0 { Button("New Code") { renew() } }
                        }
                    Text(left > 0 ? "Expires in \(ApprovalSummary.timeLeft(left))" : "Expired")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 16)
            if (service.routes[brokerID] ?? []).isEmpty {
                Text("Waiting for the JetKVM: the code works once BlitzKVM reaches it.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
            } else if invite.relay == nil {
                Text("Without a relay, the iPhone reaches the JetKVM on its network or tailnet only.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .padding(.horizontal, 20)
            }
            if !enrollments.isEmpty {
                Form {
                    Section("Asking to Join") {
                        ForEach(enrollments) { EnrollmentRow(service: service, center: center, enrollment: $0) }
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).padding(.horizontal, 20).padding(.top, 8)
            }
            HStack {
                Spacer()
                Button("Done") { replace(nil) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func renew() {
        error = nil
        Task {
            do {
                let next = try await service.signAsOwner(reason: "pair an iPhone") { presence in
                    try center.invite(brokerID, presence: presence)
                }
                issued = Date()
                replace(next)
            } catch where ApprovalService.isCancellation(error) {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// A device that enrolled with an invite: an owner adds it (also as an
/// owner, by default) with Touch ID, or declines.
private struct EnrollmentRow: View {
    @ObservedObject var service: ApprovalService
    @ObservedObject var center: ApprovalCenter
    let enrollment: Enrollment
    @State private var asOwner = true
    @State private var error: String?

    var body: some View {
        let e = enrollment
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: e.approver.platform == "ios" ? "iphone" : "laptopcomputer")
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(e.approver.name)
                Tag("Asks to join")
                Spacer()
                Toggle("Also owner", isOn: $asOwner)
                    .toggleStyle(.checkbox)
                    .help("Owners can pair and revoke approvers, and change the relay.")
                Button("Decline") { center.decline(e) }
                Button("Add") { admit() }
                    .buttonStyle(.borderedProminent)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func admit() {
        error = nil
        let e = enrollment, owner = asOwner
        Task {
            do {
                try await service.signAsOwner(reason: "add \(e.approver.name) as an approver") { presence in
                    try center.admit(e, owner: owner, presence: presence)
                }
            } catch where ApprovalService.isCancellation(error) {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// A QR code, one module per pixel scaled up without smoothing; drawn once
/// per text (the countdown around it redraws every second).
private struct QRImage: View {
    let text: String
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
            } else {
                Color.clear
            }
        }
        .frame(width: 240, height: 240)
        .padding(10)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Pairing code")
        .task(id: text) { image = QRCode.image(text) }
    }
}

// MARK: - Stored passwords

private struct PasswordEdit: Identifiable {
    let target: Target
    let kind: String
    var id: String { target.id + kind }
}

/// Stores (or replaces) a password the JetKVM may type for one approval.
private struct StoredPasswordSheet: View {
    let edit: PasswordEdit
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    var body: some View {
        let name = ApprovalSummary.passwordName(edit.kind)
        VStack(alignment: .leading, spacing: 0) {
            Text("\(name.prefix(1).uppercased() + name.dropFirst()) for \(edit.target.name)")
                .font(.title3.weight(.semibold))
                .padding([.horizontal, .top], 20)
            Text("Kept behind Touch ID. The JetKVM types it only into a prompt you approve, sealed to that one request.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.top, 4)
            Form {
                SecureField(name.prefix(1).uppercased() + name.dropFirst(), text: $password)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(password)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
