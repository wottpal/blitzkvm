import ApprovalKit
import SwiftUI

struct RequestsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ApproverSession.self) private var session
    @EnvironmentObject private var center: ApprovalCenter
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if center.brokers.isEmpty {
                    NotPairedView()
                } else {
                    list
                }
            }
            .navigationTitle("Requests")
            .navigationDestination(for: String.self) { ReviewView(requestID: $0) }
        }
        .onChange(of: model.openRequest, initial: true) { _, id in
            guard let id else { return }
            path = [id]
            model.openRequest = nil
        }
    }

    private var list: some View {
        List {
            StatusNotices()
            if !center.requests.isEmpty {
                Section("Open") {
                    ForEach(center.requests) { r in
                        NavigationLink(value: r.id) { RequestRow(request: r) }
                    }
                }
            }
            if !center.history.isEmpty {
                Section("Recent") {
                    ForEach(center.history.prefix(10)) { r in
                        NavigationLink(value: r.id) { RequestRow(request: r) }
                    }
                }
            }
        }
        .overlay {
            if center.requests.isEmpty && center.history.isEmpty {
                ContentUnavailableView("No Requests", systemImage: "checkmark.shield",
                                       description: Text("Requests from your computers appear here and as notifications."))
            }
        }
        .refreshable { await session.refresh(sync: true) }
        .task { await session.poll(every: 10) }
    }
}

/// Requests, before any JetKVM is paired.
struct NotPairedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Not Paired", systemImage: "rectangle.connected.to.line.below")
        } description: {
            Text("Pair this iPhone with a JetKVM to approve sudo, password prompts and other requests from its computer.")
        } actions: {
            Button("Pair JetKVM") { model.startPairing() }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// Why requests might not arrive: development keys, a JetKVM without a
/// relay or not admitted yet, notifications turned off.
struct StatusNotices: View {
    @Environment(AppModel.self) private var model
    @Environment(ApproverSession.self) private var session
    @EnvironmentObject private var center: ApprovalCenter

    var body: some View {
        if !session.keys.hardwareBacked {
            Section {
                NoticeRow(symbol: "exclamationmark.triangle.fill", tint: .orange, title: "Development Keys",
                          text: "This build signs with software keys, not the Secure Enclave. For development only.")
            }
        }
        let noRelay = center.brokers.filter { RelayTransport.relay(for: $0) == nil }
        let waiting = center.brokers.filter { RelayTransport.relay(for: $0) != nil && !session.isAdmitted($0.id) }
        if !noRelay.isEmpty || !waiting.isEmpty || model.notifications.authorization == .denied {
            Section {
                ForEach(noRelay) { b in
                    NoticeRow(symbol: "antenna.radiowaves.left.and.right.slash", tint: .orange, title: "\(b.name): No Relay",
                              text: "The relay isn't configured for this JetKVM, so its requests can't reach this iPhone.")
                }
                ForEach(waiting) { b in
                    NoticeRow(symbol: "hourglass", tint: .secondary, title: "\(b.name): Waiting for the Owner",
                              text: "An owner admits this iPhone on their Mac. Then its requests arrive here.")
                }
                if model.notifications.authorization == .denied {
                    NoticeRow(symbol: "bell.slash.fill", tint: .orange, title: "Notifications Off",
                              text: "Requests only show while BlitzKVM is open. Turn notifications on in Settings.")
                }
            }
        }
    }
}

struct RequestRow: View {
    let request: OpenRequest
    @Environment(ApproverSession.self) private var session
    @EnvironmentObject private var center: ApprovalCenter

    var body: some View {
        let target = center.roster(request.brokerID)?.target(request.ask.target)?.name ?? "Unknown computer"
        HStack(spacing: 12) {
            KindIcon(kind: request.ask.kind)
            VStack(alignment: .leading, spacing: 3) {
                Text(request.ask.title)
                    .font(.headline)
                    .lineLimit(2)
                Text("\(target) · \(KindInfo.name(request.ask.kind))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !request.isPending {
                    RequestOutcome(state: request.state, by: session.approverName(request.by, brokerID: request.brokerID),
                                   target: target).label
                        .font(.caption)
                } else if let sent = session.sent[request.id] {
                    RequestOutcome(sent: sent, target: target).label.font(.caption)
                }
            }
            Spacer(minLength: 8)
            if request.isPending {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(request.verified.code)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .accessibilityLabel("Code \(request.verified.code.map(String.init).joined(separator: " "))")
                    TimeLeft(expires: Date(timeIntervalSince1970: TimeInterval(request.ask.expires)))
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
