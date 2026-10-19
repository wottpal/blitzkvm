import Foundation

/// Which of a device's addresses a window's session uses while the Mac moves
/// between networks: the LAN address at home, the tailnet name away. The
/// addresses are in the order the user prefers them. The window probes them
/// over HTTP (AddressProbe; never WebRTC, whose new session would take over
/// the current one) and asks this what to do with the answer:
/// - While the session is down (connecting, or waiting to retry), it moves
///   to the answer, the most preferred address that answers. When the
///   current address starts answering again while the engine waits out its
///   retry backoff, it reconnects now.
/// - While connected through a less preferred address, it moves to a more
///   preferred one once that answers, unless the picture already takes a
///   LAN path (at home the direct path finds the LAN past the JetKVM's own
///   Tailscale, so moving would only interrupt it).
/// - An address that answers while no session comes up through it for
///   `connectWithin` goes last until the network changes or `skipFor` has
///   passed, so a window never bounces between two addresses.
///
/// A pure value: callers pass times (seconds on one monotonic clock) and the
/// device's addresses as they are now (Device Settings may change them).
public struct AddressRoaming {
    public struct Tuning: Equatable {
        /// Probe this often while the session is down, and for
        /// `networkSettle` after the network changed ...
        public var downInterval: TimeInterval = 3
        /// ... this often while it is up through a less preferred address ...
        public var upgradeInterval: TimeInterval = 15
        /// ... and this soon after the network changed (path updates come in
        /// bursts, and the new network needs a moment).
        public var afterNetworkChange: TimeInterval = 0.5
        public var networkSettle: TimeInterval = 10
        /// An address that answers this long without a session coming up
        /// (a connect attempt takes at most 15 s) ...
        public var connectWithin: TimeInterval = 20
        /// ... goes last for this long, or until the network changes.
        public var skipFor: TimeInterval = 1800

        public init() {}
    }

    /// The session, as far as roaming goes.
    public enum Session: Equatable {
        /// Connected; `lanPicture` when the video already takes a LAN path.
        case connected(lanPicture: Bool)
        /// A connect attempt runs, or is about to.
        case connecting
        /// The engine waits out its retry backoff after a failed attempt.
        case waiting
        /// Hands off: another session took over, the login failed, the
        /// device's identity or certificate changed, or it is rebooting.
        case paused

        /// From the engine's session phase and the video's path (engine
        /// stats "Path").
        public init(phase: String, path: String?) {
            switch phase {
            case "connected": self = .connected(lanPicture: path == "lan")
            case "idle", "connecting", "reconnecting": self = .connecting
            case "disconnected": self = .waiting
            default: self = .paused // other_session, auth_failed, fatal_error, rebooting
            }
        }
    }

    public enum Action: Equatable {
        case stay
        /// The current address answers again: retry now.
        case reconnect
        /// Connect to this address instead (then call `moved`).
        case move(to: String)
    }

    public var tuning = Tuning()
    public private(set) var current: String
    /// Addresses that answered while no session came up, and until when
    /// they go last.
    private var skipped: [String: TimeInterval] = [:]
    /// Since when the current address has answered while the session was down.
    private var answeringSince: TimeInterval?
    private var lastProbe: TimeInterval
    private var networkChangedAt: TimeInterval?

    /// `answered`: the window's first probe found `current` answering.
    public init(current: String, answered: Bool, at now: TimeInterval) {
        self.current = current
        answeringSince = answered ? now : nil
        lastProbe = now
    }

    /// The addresses in the order to probe them: as listed, skipped ones last.
    public func order(_ addresses: [String], at now: TimeInterval) -> [String] {
        let skip = { (address: String) in (skipped[address] ?? -.infinity) > now }
        return addresses.filter { !skip($0) } + addresses.filter(skip)
    }

    /// Whether to probe now.
    public func probeDue(_ addresses: [String], session: Session, at now: TimeInterval) -> Bool {
        guard !addresses.isEmpty else { return false }
        let settling = networkChangedAt.map { now - $0 < tuning.networkSettle } ?? false
        let interval: TimeInterval
        switch session {
        case .paused:
            return false
        case .connecting, .waiting:
            interval = tuning.downInterval
        case .connected(let lanPicture):
            // Nothing better to move to.
            guard !lanPicture, order(addresses, at: now).first != current else { return false }
            interval = settling ? tuning.downInterval : tuning.upgradeInterval
        }
        if let changed = networkChangedAt, changed > lastProbe {
            return now >= changed + tuning.afterNetworkChange
        }
        return now >= lastProbe + interval
    }

    /// What to do with a probe's answer: the address AddressProbe chose from
    /// `order(addresses)`, nil when none answered. `session` is the session
    /// as it is now, when the probe has finished.
    public mutating func decide(_ addresses: [String], answer: String?, session: Session, at now: TimeInterval) -> Action {
        lastProbe = now
        switch session {
        case .paused:
            return .stay
        case .connected(let lanPicture):
            guard !lanPicture, let answer, answer != current else { return .stay }
            let order = order(addresses, at: now)
            // An address no longer listed is the least preferred.
            guard let better = order.firstIndex(of: answer), better < order.firstIndex(of: current) ?? order.count else { return .stay }
            return .move(to: answer)
        case .connecting, .waiting:
            guard let answer else {
                answeringSince = nil
                return .stay
            }
            if answer != current { return .move(to: answer) }
            guard let since = answeringSince else {
                // It answers again: retry now rather than after the engine's
                // backoff. Once; a retry that fails gets the backoff again.
                answeringSince = now
                return session == .waiting ? .reconnect : .stay
            }
            if now - since >= tuning.connectWithin && addresses.count > 1 {
                // It answers, but no session comes up through it: the other
                // addresses first, probed again at once.
                skipped[current] = now + tuning.skipFor
                answeringSince = nil
                lastProbe = now - tuning.downInterval
            }
            return .stay
        }
    }

    /// The session now connects to `address`, which just answered.
    public mutating func moved(to address: String, at now: TimeInterval) {
        current = address
        answeringSince = now
    }

    /// The session came up.
    public mutating func connected() {
        answeringSince = nil
    }

    /// The Mac joined another network (or left one): skipped addresses get
    /// another chance, and probing follows soon.
    public mutating func networkChanged(at now: TimeInterval) {
        skipped.removeAll()
        answeringSince = nil
        networkChangedAt = now
    }
}
