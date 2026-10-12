import AppKit

/// Covers the video while the picture is stalled (connecting, the remote
/// display re-detecting a new size, a stream waiting to resume): the last
/// frame stays visible, dimmed, under an icon for the state and a line of
/// text, and for a state the user can end (a sleeping computer) a button.
/// Only that button takes clicks, so input keeps reaching the remote.
final class StallOverlay: NSView {
    struct Content: Equatable {
        var title: String
        var detail: String?
        /// SF Symbol for the state.
        var symbol: String
        /// The symbol pulses: the app is waiting for something that ends by
        /// itself.
        var busy = true
        var action: Action?
    }

    enum Action: Equatable {
        case wake
        case reconnect

        var title: String {
            switch self {
            case .wake: return "Wake Computer"
            case .reconnect: return "Reconnect"
            }
        }
    }

    private(set) var content: Content?
    /// The button was clicked.
    var onAction: ((Action) -> Void)?
    private let panel = NSVisualEffectView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)

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
        button.bezelStyle = .push
        button.controlSize = .large
        button.refusesFirstResponder = true // the keyboard stays with the remote
        button.target = self
        button.action = #selector(runAction)
        button.isHidden = true
        let stack = NSStackView(views: [icon, title, detail, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(14, after: icon)
        stack.setCustomSpacing(18, after: detail)
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

    /// Only the button takes clicks; everywhere else they reach the remote.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, !button.isHidden, let hit = super.hitTest(point), hit === button else { return nil }
        return hit
    }

    /// The pointer shows over the button (the video hides it elsewhere).
    override func resetCursorRects() {
        guard !isHidden, !button.isHidden else { return }
        addCursorRect(convert(button.bounds, from: button), cursor: .pointingHand)
    }

    @objc private func runAction() {
        if let action = content?.action { onAction?(action) }
    }

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
        button.title = content.action?.title ?? ""
        button.isHidden = content.action == nil
        window?.invalidateCursorRects(for: self)
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
