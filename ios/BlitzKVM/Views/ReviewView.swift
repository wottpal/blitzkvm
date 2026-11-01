import ApprovalKit
import SwiftUI

/// One request: what, where, who asked, the matching code, and the answer.
struct ReviewView: View {
    let requestID: String
    @Environment(ApproverSession.self) private var session
    @EnvironmentObject private var center: ApprovalCenter
    @State private var attachPassword = true
    @State private var busy: Action?
    @State private var error: String?
    @State private var addingPassword = false
    @State private var approvedCount = 0

    private enum Action { case approve, grant, deny }

    private var request: OpenRequest? {
        center.requests.first { $0.id == requestID } ?? center.history.first { $0.id == requestID }
    }

    var body: some View {
        Group {
            if let request {
                review(request)
            } else if session.isRefreshing {
                ProgressView()
            } else {
                ContentUnavailableView("Request Closed", systemImage: "clock.badge.xmark",
                                       description: Text("It was answered on another device or expired."))
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .task { await session.poll(every: 3) }
        .sensoryFeedback(.success, trigger: approvedCount)
        .alert("Couldn't Complete", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func review(_ r: OpenRequest) -> some View {
        let broker = center.broker(r.brokerID)
        let stored = r.ask.secret != SecretKind.none && session.hasPassword(target: r.ask.target, kind: r.ask.secret)
        let c = ReviewContent(r, broker: broker, secretStored: stored)
        return List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    KindIcon(kind: c.kind, size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(c.title)
                            .font(.title3.weight(.semibold))
                            .textSelection(.enabled)
                        if let detail = c.detail {
                            Text(detail).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text("\(c.kindName) on \(c.targetName)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            if r.isPending {
                Section {
                    VStack(spacing: 4) {
                        Text(c.code)
                            .font(.system(size: 64, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .accessibilityLabel("Code \(c.code.map(String.init).joined(separator: " "))")
                        TimeLeft(expires: c.expires).font(.subheadline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                } footer: {
                    Text("Approve only if \(c.targetName) shows the same code where the request was made.")
                }
            }

            if let need = c.secret, r.isPending {
                Section {
                    if need.stored {
                        Toggle(isOn: $attachPassword) {
                            Label("Attach \(need.name)", systemImage: "key.fill")
                        }
                    } else {
                        Button {
                            addingPassword = true
                        } label: {
                            Label("Add \(need.name)…", systemImage: "key")
                        }
                    }
                } header: {
                    Text("Password")
                } footer: {
                    if !need.stored {
                        Text("Store it once, behind Face ID; later approvals can attach it.")
                    } else if attachPassword {
                        Text("Sealed to this request: only the JetKVM can open it, to type it into the prompt.")
                    } else {
                        Text("Approving sends no password.")
                    }
                }
            }

            if c.requester != nil || !c.chain.isEmpty {
                Section("Requested By") {
                    if let who = c.requester {
                        LabeledContent("User", value: who)
                    }
                    ForEach(c.chain) { ProcessRowView(row: $0) }
                }
            }

            if !c.evidence.isEmpty {
                Section("Seen on the Screen") {
                    ForEach(c.evidence) { LabeledContent($0.label, value: $0.value) }
                }
            }

            Section("Details") {
                LabeledContent("Computer", value: c.targetName)
                LabeledContent("JetKVM", value: c.brokerName)
                LabeledContent("Kind", value: c.kindName)
            }
        }
        .safeAreaInset(edge: .bottom) { actions(r, c) }
        .sheet(isPresented: $addingPassword) {
            PasswordSheet(targetID: r.ask.target, targetName: c.targetName, kind: r.ask.secret)
                .environment(session)
        }
    }

    @ViewBuilder
    private func actions(_ r: OpenRequest, _ c: ReviewContent) -> some View {
        VStack(spacing: 10) {
            if !r.isPending {
                RequestOutcome(state: r.state, by: session.approverName(r.by, brokerID: r.brokerID), target: c.targetName)
                    .label.font(.headline)
                if let note = r.note, !note.isEmpty {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
            } else if let sent = session.sent[r.id], sent != .sending {
                RequestOutcome(sent: sent, target: c.targetName).label.font(.headline)
            } else {
                Button {
                    approve(r, grant: false, attach: c.secret?.stored == true && attachPassword)
                } label: {
                    actionLabel("Approve", symbol: Biometrics.symbol, busy: busy == .approve)
                }
                .buttonStyle(.borderedProminent)
                HStack(spacing: 10) {
                    Button(role: .destructive) {
                        deny(r)
                    } label: {
                        actionLabel("Deny", symbol: "xmark", busy: busy == .deny)
                    }
                    if c.canGrant {
                        Button {
                            approve(r, grant: true, attach: false)
                        } label: {
                            actionLabel("10 Minutes", symbol: "timer", busy: busy == .grant)
                        }
                        .accessibilityLabel("Approve for 10 minutes")
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
        .disabled(busy != nil)
        .padding(.horizontal)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func actionLabel(_ title: String, symbol: String, busy: Bool) -> some View {
        HStack(spacing: 8) {
            if busy { ProgressView() } else { Image(systemName: symbol) }
            Text(title).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private func approve(_ r: OpenRequest, grant: Bool, attach: Bool) {
        busy = grant ? .grant : .approve
        Task {
            defer { busy = nil }
            do {
                try await session.approve(r, grant: grant, attachSecret: attach)
                approvedCount += 1
            } catch let e where ErrorText.isCancellation(e) {
            } catch {
                self.error = ErrorText.describe(error)
            }
        }
    }

    private func deny(_ r: OpenRequest) {
        busy = .deny
        Task {
            defer { busy = nil }
            do {
                try await session.deny(r)
            } catch {
                self.error = ErrorText.describe(error)
            }
        }
    }
}

/// A process of the requester chain: name and pid, path, arguments, signer.
private struct ProcessRowView: View {
    let row: ReviewContent.ProcessRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.name).font(.body.weight(.medium))
                Text(verbatim: "pid \(row.pid)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if let signer = row.signer {
                    Label(signer.label, systemImage: signer.trusted ? "checkmark.seal" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(signer.trusted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                        .lineLimit(1)
                }
            }
            if let path = row.path {
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let args = row.arguments {
                Text(args)
                    .font(.caption.monospaced())
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }
}
