import ApprovalKit
import SwiftUI

/// Pairing: scan (or paste) the code an owner's Mac shows, confirm, enroll
/// through the relay, and wait until the owner admits this iPhone.
struct PairView: View {
    @State var invite: PairingInvite?
    @Environment(ApproverSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var pasted = ""
    @State private var codeError: String?

    var body: some View {
        NavigationStack {
            Group {
                switch session.pairing {
                case .idle:
                    if let invite { confirm(invite) } else { scan }
                case .enrolling:
                    progress("Sending the Request…")
                case let .waiting(broker, since):
                    waiting(broker, since: since)
                case let .done(broker):
                    finished(broker)
                case let .failed(message):
                    failed(message)
                }
            }
            .navigationTitle("Pair JetKVM")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(session.pairing == .idle ? "Cancel" : "Close") { close() }
                }
            }
        }
        .onAppear {
            session.resetPairing()
            name = session.name
        }
    }

    private func close() {
        session.resetPairing()
        dismiss()
    }

    // MARK: Steps

    private var scan: some View {
        List {
            Section {
                QRScannerPanel { handle($0, typed: false) }
                    .aspectRatio(1, contentMode: .fit)
                    .listRowInsets(EdgeInsets())
            } footer: {
                Text("Scan the pairing code that BlitzKVM shows on a Mac that owns the JetKVM.")
            }
            Section {
                TextField("blitzkvm-pair:…", text: $pasted, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.footnote.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: pasted) { _, text in handle(text, typed: true) }
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in
                        pasted = strings.first ?? ""
                        handle(pasted, typed: true)
                    }
                }
                if let codeError {
                    Text(codeError).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Or Paste the Code")
            }
        }
    }

    private func handle(_ text: String, typed: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let found = PairingCode.invite(from: trimmed) {
            invite = found
            codeError = nil
        } else if typed {
            codeError = trimmed.isEmpty ? nil : "That isn't a BlitzKVM pairing code."
        }
    }

    private func confirm(_ invite: PairingInvite) -> some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.connected.to.line.below")
                        .font(.system(size: 40))
                        .foregroundStyle(.tint)
                    Text(invite.name).font(.title2.weight(.semibold))
                    Text("JetKVM \(Format.grouped(invite.broker.id))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            if let host = Format.host(invite.relay) {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                } header: {
                    Text("This iPhone's Name")
                } footer: {
                    Text("The owner sees this name when admitting the iPhone.")
                }
                Section {
                    LabeledContent("Relay", value: host)
                }
                Section {
                    Button {
                        session.pair(invite, name: name)
                    } label: {
                        Text("Pair").bold().frame(maxWidth: .infinity)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                } footer: {
                    Text("BlitzKVM then asks to send notifications, so requests reach this iPhone.")
                }
            } else {
                Section {
                    NoticeRow(symbol: "antenna.radiowaves.left.and.right.slash", tint: .orange, title: "No Relay",
                              text: ApproverSession.noRelayMessage(invite.name))
                }
            }
            Section {
                Button("Scan Another Code") {
                    self.invite = nil
                    pasted = ""
                }
            }
        }
    }

    private func progress(_ title: String) -> some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(title).font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func waiting(_ broker: String, since: Date) -> some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Waiting for the Owner").font(.title3.weight(.semibold))
            Text("On the Mac that showed the code, admit “\(session.name)” to \(broker). This iPhone joins as soon as it's admitted.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("Asked \(since, style: .relative) ago")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text("This iPhone's ID: \(Format.grouped(session.keys.id))")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Stop Waiting", role: .destructive) { session.cancelPairing() }
                .padding(.top, 8)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func finished(_ broker: String) -> some View {
        ContentUnavailableView {
            Label("Paired with \(broker)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } description: {
            Text("Requests from its computers now reach this iPhone.")
        } actions: {
            Button("Done") { close() }.buttonStyle(.borderedProminent)
        }
    }

    private func failed(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Pairing Failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") {
                session.resetPairing()
                invite = nil
                pasted = ""
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
