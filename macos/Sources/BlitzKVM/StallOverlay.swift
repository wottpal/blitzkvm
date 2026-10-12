import AppKit

/// Covers the video while the picture is stalled (connecting, the remote
/// display re-detecting a new size, a stream waiting to resume): the last
/// frame stays visible, dimmed, under an icon for the state and a line of
/// text.
/// Never takes clicks, so input keeps reaching the remote.
final class StallOverlay: NSView {
    struct Content: Equatable {
        var title: String
        var detail: String?
        /// SF Symbol for the state.
        var symbol: String
        /// The symbol pulses: the app is waiting for something that ends by
        /// itself.
        var busy = true
    }

    private(set) var content: Content?
    private let panel = NSVisualEffectView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        appearance = NSAppearance(named: .darkAqua)
        alphaValue = 0
        isHidden = true

        panel.material = .hudWindow
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 18
        panel.layer?.masksToBounds = true
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .regular)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: .labelColor))
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .labelColor
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        for label in [title, detail] {
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
        }
        let stack = NSStackView(views: [icon, title, detail])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(14, after: icon)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        addSubview(panel)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
            panel.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            panel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -26),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows `content` (fading in), or hides the overlay for nil.
    func show(_ content: Content?) {
        guard content != self.content else { return }
        let shown = self.content
        self.content = content
        guard let content else {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; animator().alphaValue = 0 }) { [weak self] in
                guard let self, self.content == nil else { return }
                self.isHidden = true
                self.icon.removeAllSymbolEffects()
            }
            return
        }
        title.stringValue = content.title
        detail.stringValue = content.detail ?? ""
        detail.isHidden = content.detail?.isEmpty ?? true
        // Only on a new state: the detail of one changes every second.
        if content.symbol != shown?.symbol || content.busy != shown?.busy {
            icon.removeAllSymbolEffects()
            icon.image = NSImage(systemSymbolName: content.symbol, accessibilityDescription: nil)
            if content.busy { icon.addSymbolEffect(.pulse, options: .repeating) }
        }
        if shown == nil {
            isHidden = false
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; animator().alphaValue = 1 }
        }
    }
}
