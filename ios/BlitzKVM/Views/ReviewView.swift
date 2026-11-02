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
    @State private var showsScreen = false

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
        let c = ReviewContent(r, broker: broker, secretStored: stored, me: session.keys.id)
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
                if let by = c.requestedBy {
                    Label(c.requestedElsewhere ? "Asked for on \(by), not on this iPhone." : "Asked for on this iPhone.",
                          systemImage: c.requestedElsewhere ? "exclamationmark.triangle" : "person.crop.circle.badge.checkmark")
                        .font(.subheadline)
                        .foregroundStyle(c.requestedElsewhere ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
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
                    Text(Kind.isTyping(c.kind) ? "Approving lets the JetKVM answer this prompt on \(c.targetName)."
                        : "Approve only if \(c.targetName) shows the same code where the request was made.")
                }
            }

            if let shot = center.screens[r.id], let image = UIImage(data: shot.jpeg) {
                Section {
                    Button { showsScreen = true } label: {
                        ScreenImage(image: image)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Screen of \(c.targetName)")
                    .accessibilityHint("Shows it larger")
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text("\(c.targetName) at \(shot.taken.formatted(date: .omitted, time: .standard)), when the request came in.")
                }
                .fullScreenCover(isPresented: $showsScreen) {
                    ScreenViewer(image: image, title: c.targetName)
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
            // The spinner takes the symbol's place at its size: the button
            // doesn't grow while it works.
            Image(systemName: symbol)
                .opacity(busy ? 0 : 1)
                .overlay {
                    if busy { ProgressView().controlSize(.small) }
                }
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

/// The remote screen as the JetKVM saw it, edge to edge in its row.
private struct ScreenImage: View {
    let image: UIImage

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
    }
}

/// The screen picture on its own: pinch to zoom, drag to pan.
private struct ScreenViewer: View {
    let image: UIImage
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let fit = min(geo.size.width / image.size.width, geo.size.height / image.size.height)
                let scale = fit * min(max(zoom * pinch, 1), 6)
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: image.size.width * scale, height: image.size.height * scale)
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                }
                .scrollIndicators(.hidden)
                .gesture(MagnifyGesture()
                    .updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { value in zoom = min(max(zoom * value.magnification, 1), 6) })
                .onTapGesture(count: 2) { withAnimation(.snappy) { zoom = zoom > 1 ? 1 : 2.5 } }
            }
            .background(.black)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
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
