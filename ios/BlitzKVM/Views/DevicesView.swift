import ApprovalKit
import SwiftUI

/// The paired JetKVMs.
struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var center: ApprovalCenter

    var body: some View {
        NavigationStack {
            Group {
                if center.brokers.isEmpty {
                    NotPairedView()
                } else {
                    List(center.brokers) { b in
                        NavigationLink(value: b.id) { BrokerRow(broker: b) }
                    }
                }
            }
            .navigationTitle("Devices")
            .navigationDestination(for: String.self) { BrokerDetailView(brokerID: $0) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { model.startPairing() } label: { Label("Pair JetKVM", systemImage: "plus") }
                }
            }
        }
    }
}

private struct BrokerRow: View {
    let broker: PairedBroker
    @Environment(ApproverSession.self) private var session

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.connected.to.line.below")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(broker.name).font(.headline)
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        if RelayTransport.relay(for: broker) == nil { return "No relay" }
        guard let roster = broker.decodedRoster, session.isAdmitted(broker.id) else { return "Waiting for the owner" }
        let computers = roster.targets.count == 1 ? "1 computer" : "\(roster.targets.count) computers"
        let approvers = roster.approvers.count == 1 ? "1 approver" : "\(roster.approvers.count) approvers"
        return roster.isOwner(session.keys.id) ? "\(computers) · \(approvers) · Owner" : "\(computers) · \(approvers)"
    }
}

/// A JetKVM: its relay, computers, approvers and (for owners) devices that
/// ask to pair.
struct BrokerDetailView: View {
    let brokerID: String
    @Environment(ApproverSession.self) private var session
    @EnvironmentObject private var center: ApprovalCenter
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemove = false
    @State private var error: String?
    @State private var unlockError: String?

    var body: some View {
        if let broker = center.broker(brokerID) {
            detail(broker)
        } else {
            ContentUnavailableView("Not Paired", systemImage: "rectangle.connected.to.line.below")
        }
    }

    private func detail(_ broker: PairedBroker) -> some View {
        let roster = broker.decodedRoster
        let admitted = session.isAdmitted(broker.id)
        let enrollments = center.enrollments.filter { $0.brokerID == broker.id }
        return List {
            Section("Connection") {
                if let host = Format.host(broker.relay), RelayTransport.relay(for: broker) != nil {
                    LabeledContent("Relay", value: host)
                    relayState
                } else {
                    NoticeRow(symbol: "antenna.radiowaves.left.and.right.slash", tint: .orange, title: "No Relay",
                              text: "An iPhone reaches its JetKVM only through the relay. Set one up in BlitzKVM on the Mac.")
                }
                if !admitted {
                    NoticeRow(symbol: "hourglass", tint: .secondary, title: "Waiting for the Owner",
                              text: "An owner admits “\(session.name)” in BlitzKVM on their Mac. Requests arrive once it's admitted.")
                }
            }

            if let roster {
                Section {
                    if roster.targets.isEmpty {
                        Text("No computers yet").foregroundStyle(.secondary)
                    }
                    ForEach(roster.targets, id: \.id) { t in
                        HStack {
                            Label(t.name, systemImage: "desktopcomputer")
                            Spacer()
                            Button("Unlock") {
                                Task {
                                    do {
                                        try await session.unlock(brokerID: brokerID, target: t.id)
                                    } catch {
                                        unlockError = ErrorText.describe(error)
                                    }
                                }
                            }
                            .buttonStyle(.borderless)
                            .accessibilityHint("Asks \(t.name) to unlock its screen. If it's locked, a request comes up to approve.")
                        }
                    }
                } header: {
                    Text("Computers")
                } footer: {
                    Text(unlockError ?? "Requests come from these computers. Unlock asks a locked one for its password; you approve it here.")
                }

                Section("Approvers") {
                    ForEach(roster.approvers, id: \.id) { a in
                        HStack {
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(a.name)
                                    if a.id == session.keys.id {
                                        Text("This iPhone").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: a.platform == "ios" ? "iphone" : "laptopcomputer")
                            }
                            Spacer()
                            if roster.isOwner(a.id) { OwnerBadge() }
                        }
                    }
                }
            }

            if !enrollments.isEmpty {
                Section {
                    ForEach(enrollments) { e in enrollmentRow(e) }
                } header: {
                    Text("Asking to Pair")
                } footer: {
                    Text("Admit only devices you just paired yourself.")
                }
            }

            Section("Details") {
                LabeledContent("JetKVM ID") {
                    Text(Format.grouped(broker.id)).font(.footnote.monospaced())
                }
                if let roster {
                    LabeledContent("Roster", value: "Version \(roster.seq)")
                }
            }

            Section {
                Button("Remove from This iPhone", role: .destructive) { confirmRemove = true }
            } footer: {
                Text("This iPhone stops fetching its requests. To stop them being sent here, an owner removes this iPhone from the approvers on their Mac.")
            }
        }
        .navigationTitle(broker.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await session.refresh(sync: true) }
        .confirmationDialog("Remove \(broker.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                dismiss()
                session.remove(broker)
            }
        } message: {
            Text("Its open requests and the passwords stored for its computers are removed from this iPhone.")
        }
        .alert("Couldn't Complete", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    @ViewBuilder
    private var relayState: some View {
        switch session.relayStates[brokerID] {
        case .ok(let date):
            LabeledContent("Status") {
                Text("Reachable, checked \(date, style: .relative) ago")
            }
        case .failed(let message):
            Text(message).font(.footnote).foregroundStyle(.orange)
        case nil:
            LabeledContent("Status", value: "Not checked yet")
        }
    }

    private func enrollmentRow(_ e: Enrollment) -> some View {
        HStack {
            Label(e.approver.name, systemImage: e.approver.platform == "ios" ? "iphone" : "laptopcomputer")
            Spacer()
            Menu("Admit") {
                Button("Admit") { admit(e, asOwner: false) }
                Button("Admit as Owner") { admit(e, asOwner: true) }
                Button("Decline", role: .destructive) { session.decline(e) }
            }
        }
    }

    private func admit(_ e: Enrollment, asOwner: Bool) {
        Task {
            do {
                try await session.admit(e, asOwner: asOwner)
            } catch let e where ErrorText.isCancellation(e) {
            } catch {
                self.error = ErrorText.describe(error)
            }
        }
    }
}
