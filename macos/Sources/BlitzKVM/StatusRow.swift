import SwiftUI

/// A row of a setup screen: an icon tile, a title (with an optional tag),
/// the state on one line (left out where the accessory already says it), a
/// one-line paragraph on what it means, and an accessory: the action that
/// moves it forward, or a badge once done.
struct StatusRow<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var tag: String?
    var state: String?
    /// Shown in red, and allowed to wrap so nothing of it is cut off.
    var isError = false
    /// The second paragraph, Markdown (for a link).
    var note: String?
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.body.weight(.medium))
                    if let tag {
                        Text(tag)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                if let state {
                    Text(state)
                        .font(.callout)
                        .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .textSelection(.enabled)
                        .lineLimit(isError ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note, let markdown = try? AttributedString(markdown: note) {
                    Text(markdown)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.top, state == nil ? 0 : 4)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            accessory()
        }
        .padding(.vertical, 4)
    }
}

/// Done: a green check and a word.
struct DoneBadge: View {
    let title: String

    var body: some View {
        Label(title, systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(.green)
            .labelStyle(.titleAndIcon)
    }
}
