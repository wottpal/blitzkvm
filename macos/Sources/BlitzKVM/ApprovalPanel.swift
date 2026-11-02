import AppKit
import ApprovalKit
import JetKVMCore
import SwiftUI

/// The floating panel that shows approval requests, oldest first: over
/// other apps and full-screen windows, without taking the keyboard until
/// its password field needs it. It closes once no request is left.
@MainActor
final class ApprovalPanelController {
    private unowned let service: ApprovalService
    private var panel: NSPanel?

    init(service: ApprovalService) {
        self.service = service
    }

    private var isEmpty: Bool { (service.center?.requests.isEmpty ?? true) && service.ended.isEmpty }

    func show() {
        guard !isEmpty else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible { place(panel) }
        panel.orderFrontRegardless()
    }

    /// Closes the panel when nothing is left to show.
    func update() {
        if isEmpty { panel?.orderOut(nil) }
    }

    private func makePanel() -> NSPanel {
        let host = NSHostingController(rootView: ApprovalPanelView(service: service))
        host.sizingOptions = [.preferredContentSize]
        // No .fullSizeContentView: with it, sizing to the preferred content
        // size loops at some heights on macOS 26 and AppKit raises ("more
        // Update Constraints in Window passes than there are views").
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                            styleMask: [.titled, .closable, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.contentViewController = host
        panel.title = "Approval Requests"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        // Any click (Approve too, not only the password field) makes it key,
        // so a device window that had the keyboard lets go before Touch ID
        // or the Mac's password is asked for. Showing it never takes focus.
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    /// Top right of the screen in use, below the menu bar, like a notification.
    private func place(_ panel: NSPanel) {
        guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main else { return }
        if let view = panel.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            panel.setContentSize(view.fittingSize)
        }
        let size = panel.frame.size
        let area = screen.visibleFrame
        panel.setFrameTopLeftPoint(NSPoint(x: area.maxX - size.width - 16, y: area.maxY - 12))
    }
}

/// The panel's content: the open requests, then the ones that just ended.
struct ApprovalPanelView: View {
    @ObservedObject var service: ApprovalService

    var body: some View {
        Group {
            if let center = service.center {
                ApprovalList(service: service, center: center)
            }
        }
        .frame(width: 420)
    }
}

private struct ApprovalList: View {
    @ObservedObject var service: ApprovalService
    @ObservedObject var center: ApprovalCenter
    /// Briefly after the cards change, their buttons take no click: a card
    /// that just moved under the pointer isn't approved by a click meant for
    /// another.
    @State private var settling = false
    @State private var changes = 0

    /// Three at most: more at once is unusual, and the panel must fit. The
    /// oldest show: a new request goes below (or waits), so no card moves
    /// when one arrives, and the next shows once one is answered.
    private static let shown = 3

    var body: some View {
        let open = center.requests.sorted { $0.received < $1.received }
        let ended = service.ended.map(\.request).filter { r in !open.contains { $0.id == r.id } }
        VStack(spacing: 0) {
            ForEach(Array(open.prefix(Self.shown).enumerated()), id: \.element.id) { index, r in
                if index > 0 { Divider() }
                RequestCard(service: service, request: r, settling: settling, screen: center.screens[r.id])
            }
            if open.count > Self.shown {
                Divider()
                Text("\(open.count - Self.shown) more waiting: they show once these are answered")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
            ForEach(ended.prefix(Self.shown), id: \.id) { r in
                if !open.isEmpty || r.id != ended.first?.id { Divider() }
                EndedCard(service: service, request: r)
            }
        }
        .padding(.top, 14) // below the close button
        .animation(.snappy(duration: 0.2), value: open.map(\.id) + ended.map(\.id))
        // A picture of the screen arriving moves the cards below it too.
        .onChange(of: open.prefix(Self.shown).map { $0.id + (center.screens[$0.id] == nil ? "" : "+") }) {
            changes += 1
            let change = changes
            settling = true
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                if change == changes { settling = false }
            }
        }
    }
}

/// One open request: what, where and who asked, the matching code, the
/// password the JetKVM will type, and the answer.
private struct RequestCard: View {
    @ObservedObject var service: ApprovalService
    let request: OpenRequest
    let settling: Bool
    let screen: RequestScreen?
    @State private var typed = ""
    @State private var remember = true
    @State private var busy = false
    @State private var error: String?
    @State private var showsChain = false
    @State private var showsTitle = false

    /// A title longer than this may not fit three lines: it can be shown whole.
    private static let longTitle = 120

    var body: some View {
        let s = service.summary(request)
        VStack(alignment: .leading, spacing: 12) {
            header(s)
            if let by = s.requestedBy {
                Label(s.requestedElsewhere ? "Asked for on \(by), not on this Mac." : "Asked for on this Mac.",
                      systemImage: s.requestedElsewhere ? "exclamationmark.triangle" : "person.crop.circle.badge.checkmark")
                    .font(.callout)
                    .foregroundStyle(s.requestedElsewhere ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail = s.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            code(s)
            if let shot = screen, let image = NSImage(data: shot.jpeg) {
                ScreenThumbnail(image: image, taken: shot.taken, target: s.targetName)
            }
            if request.state == "pending", service.answered[request.id] == nil, let password = s.password {
                passwordSection(password, summary: s)
            }
            requester(s)
            if !s.evidence.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    ForEach(s.evidence) { fact in
                        GridRow {
                            Text(fact.label).foregroundStyle(.secondary)
                            Text(fact.value).textSelection(.enabled)
                        }
                    }
                }
                .font(.caption)
            }
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions(s)
        }
        .padding(16)
    }

    private func header(_ s: ApprovalSummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            KindTile(symbol: s.symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title)
                    .font(.headline)
                    .lineLimit(showsTitle ? nil : 3)
                    .fixedSize(horizontal: false, vertical: showsTitle)
                    .textSelection(.enabled)
                if s.title.count > Self.longTitle || s.title.contains("\n") {
                    Button(showsTitle ? "Show Less" : "Show All") { showsTitle.toggle() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
                Text("\(s.kindName) on \(s.targetName) · \(s.brokerName)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            TimeLeftLabel(expires: s.expires)
        }
    }

    private func code(_ s: ApprovalSummary) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Text(s.code)
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .accessibilityLabel("Code \(s.code.map(String.init).joined(separator: " "))")
            Text(s.codeHint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func passwordSection(_ password: ApprovalSummary.Password, summary s: ApprovalSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(password.stored ? "The JetKVM types your \(password.name), stored on this Mac."
                    : "The JetKVM types your \(password.name) for this approval.",
                  systemImage: "key.fill")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if !password.stored {
                SecureField(password.name, text: $typed)
                    .textFieldStyle(.roundedBorder)
                Toggle("Remember for \(s.targetName)", isOn: $remember)
                    .font(.callout)
            }
        }
    }

    @ViewBuilder
    private func requester(_ s: ApprovalSummary) -> some View {
        if s.requester != nil || !s.chain.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if let first = s.chain.first { ProcessLineView(line: first) }
                if s.chain.count > 1 || s.requester != nil {
                    DisclosureGroup(isExpanded: $showsChain) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(s.chain.dropFirst()) { ProcessLineView(line: $0) }
                        }
                        .padding(.top, 4)
                    } label: {
                        Text(s.requester.map { "Requested by \($0)" } ?? "Requested by")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actions(_ s: ApprovalSummary) -> some View {
        if let answer = service.answered[request.id] {
            Label("\(answer). Waiting for the JetKVM…", systemImage: "hourglass")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if request.state == "approved" {
            Label("Approved on \(service.approverName(request.by, brokerID: request.brokerID) ?? "an approver"). "
                    + "The JetKVM answers the prompt…", systemImage: "keyboard")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            let needsPassword = s.password.map { !$0.stored && typed.isEmpty } ?? false
            HStack(spacing: 8) {
                Button(role: .destructive) { deny() } label: { Text("Deny").frame(minWidth: 52) }
                Spacer()
                if s.canGrant {
                    Button("Allow for 10 min") { approve(grant: true) }
                        .help("Approves this, and for 10 minutes the same user's requests of this kind from the same terminal without asking.")
                }
                Button { approve(grant: false) } label: {
                    Label("Approve", systemImage: "touchid").frame(minWidth: 72)
                }
                .buttonStyle(.borderedProminent)
                .disabled(needsPassword)
            }
            .controlSize(.large)
            .disabled(busy || settling)
        }
    }

    private func approve(grant: Bool) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await service.approve(request, grant: grant, typed: typed.isEmpty ? nil : typed, remember: remember)
                typed = ""
            } catch where ApprovalService.isCancellation(error) {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func deny() {
        do {
            try service.deny(request)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A request that ended a moment ago: how, and on which approver.
private struct EndedCard: View {
    @ObservedObject var service: ApprovalService
    let request: OpenRequest

    var body: some View {
        let s = service.summary(request)
        let outcome = ApprovalOutcome(state: request.state, byName: service.approverName(request.by, brokerID: request.brokerID),
                                      byMe: request.by == service.keys?.id, note: request.note)
        HStack(spacing: 12) {
            KindTile(symbol: s.symbol)
                .opacity(0.6)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title)
                    .font(.headline)
                    .lineLimit(1)
                Text([outcome.title, outcome.detail].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

/// The remote screen as the JetKVM saw it when the request came in; a
/// click shows it larger.
private struct ScreenThumbnail: View {
    let image: NSImage
    let taken: Date
    let target: String
    @State private var enlarged = false

    /// The card's width inside the panel's padding; the height follows the
    /// picture (explicit sizes keep the panel's sizing simple).
    private static let width: CGFloat = 388

    var body: some View {
        let aspect = image.size.width > 0 ? image.size.height / image.size.width : 0.6
        Button { enlarged = true } label: {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: Self.width, height: min(Self.width * aspect, 260))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .help("\(target) at \(taken.formatted(date: .omitted, time: .standard)), when the request came in. Click to enlarge.")
        .accessibilityLabel("Screen of \(target)")
        .popover(isPresented: $enlarged, arrowEdge: .leading) {
            let width = min(max(image.size.width, 640), 960)
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: width, height: width * aspect)
                .padding(8)
        }
    }
}

/// A process of the requester chain: name and pid, signer, path, arguments.
private struct ProcessLineView: View {
    let line: ApprovalSummary.ProcessLine

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(line.name).font(.callout.weight(.medium))
                Text("pid \(line.pid)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 4)
                if let signer = line.signer {
                    Label(signer, systemImage: line.trusted ? "checkmark.seal" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(line.trusted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                        .lineLimit(1)
                }
            }
            if let path = line.path {
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let args = line.arguments {
                Text(args)
                    .font(.caption.monospaced())
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }
}

/// The kind's symbol on a tile, as setup rows draw theirs.
struct KindTile: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// "0:42", every second.
private struct TimeLeftLabel: View {
    let expires: Int64

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = expires - Int64(context.date.timeIntervalSince1970)
            Text(ApprovalSummary.timeLeft(left))
                .font(.callout.monospacedDigit())
                .foregroundStyle(left <= 10 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .accessibilityLabel("\(max(0, left)) seconds left")
        }
    }
}
