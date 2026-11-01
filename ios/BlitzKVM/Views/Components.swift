import ApprovalKit
import SwiftUI

/// A kind's symbol on a tinted rounded square.
struct KindIcon: View {
    let kind: String
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: KindInfo.symbol(kind))
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(.tint)
            .frame(width: size, height: size)
            .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// "0:42 left", ticking; "Expired" at the end.
struct TimeLeft: View {
    let expires: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = Int(expires.timeIntervalSince(context.date).rounded(.up))
            Text(seconds > 0 ? "\(Format.timeLeft(seconds)) left" : "Expired")
                .monospacedDigit()
                .foregroundStyle(seconds > 0 && seconds <= 15 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
    }
}

/// A row that explains a state: development keys, no relay, waiting.
struct NoticeRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.footnote).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }
}

struct OwnerBadge: View {
    var body: some View {
        Text("Owner")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(.tint)
            .background(.tint.opacity(0.12), in: Capsule())
    }
}

/// How a request ended, or where it stands.
struct RequestOutcome {
    let title: String
    let symbol: String
    let tint: Color

    init(state: String, by: String?, target: String) {
        let suffix = by.map { " by \($0)" } ?? ""
        switch state {
        case "approved":
            self.init("Approved\(suffix)", "checkmark.circle.fill", .green)
        case "denied":
            self.init("Denied\(suffix)", "xmark.circle.fill", .red)
        case "done":
            self.init("Done on \(target)", "checkmark.circle.fill", .green)
        case "failed":
            self.init("Failed on \(target)", "exclamationmark.triangle.fill", .orange)
        case "expired":
            self.init("Expired", "clock.badge.xmark", .secondary)
        case "cancelled":
            self.init("Cancelled on \(target)", "minus.circle.fill", .secondary)
        default:
            self.init("Waiting for an answer", "clock", .secondary)
        }
    }

    init(sent: SentDecision, target: String) {
        switch sent {
        case .sending: self.init("Sending…", "arrow.up.circle", .secondary)
        case .approved(let grant): self.init(grant ? "Approved for 10 minutes · waiting for \(target)" : "Approved · waiting for \(target)",
                                             "checkmark.circle", .green)
        case .denied: self.init("Denied", "xmark.circle", .red)
        }
    }

    private init(_ title: String, _ symbol: String, _ tint: Color) {
        self.title = title; self.symbol = symbol; self.tint = tint
    }

    var label: some View {
        Label(title, systemImage: symbol).foregroundStyle(tint)
    }
}

extension OpenRequest {
    var isPending: Bool { state == "pending" }
}
