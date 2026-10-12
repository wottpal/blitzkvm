import Foundation

/// View › Local Pointer: what this Mac's own pointer looks like over the
/// remote picture. The target draws its cursor into the HDMI picture, which
/// trails the hand (70 ms median in a window, plan §24); the local pointer
/// moves at the display's refresh. While moving both show; at rest the local
/// one hides (PointerRest) and only the remote cursor remains.
public enum LocalPointer: String, CaseIterable {
    /// Only the remote cursor shows (the default).
    case hidden
    /// A small ring, legible on any picture.
    case dot
    /// The system arrow.
    case arrow

    public var menuTitle: String {
        switch self {
        case .hidden: return "Hidden"
        case .dot: return "Dot"
        case .arrow: return "Arrow"
        }
    }
}

/// When a shown local pointer hides: once it has rested for `delay`, by
/// which time the remote cursor has caught up. The next move shows it again
/// (the window server does). A held button keeps it visible (dragging), and
/// the release starts a new rest.
public struct PointerRest {
    /// Well past the remote cursor's lag, including its slow tail.
    public static let delay: TimeInterval = 0.15

    public enum Decision: Equatable {
        /// Hide the pointer until it moves again.
        case hide
        /// Decide again at this time.
        case wait(until: TimeInterval)
        /// Nothing to do until the next move or button change.
        case idle
    }

    private var lastMove: TimeInterval?

    public init() {}

    /// The pointer moved, or a button went down or up (NSEvent timestamp).
    public mutating func moved(at time: TimeInterval) {
        lastMove = time
    }

    /// What to do at `now` (same clock); hides once per rest.
    public mutating func decide(at now: TimeInterval, buttonsHeld: Bool) -> Decision {
        guard let lastMove, !buttonsHeld else { return .idle }
        let due = lastMove + Self.delay
        guard now >= due else { return .wait(until: due) }
        self.lastMove = nil
        return .hide
    }
}
