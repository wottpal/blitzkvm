import ApprovalKit
import Foundation

/// The phone's way to its brokers: every box goes to the broker's inbox at
/// the relay, in a request signed with this approver's transport key.
/// Callers that need to know (decisions, rosters) wait for `result(of:)`;
/// a lost sync shows as the relay's state on the next outbox fetch.
@MainActor
final class RelayTransport: CenterTransport {
    private let keys: ApproverKeys
    private var running: [UUID: Task<Bool, Never>] = [:]
    private var finished: [(id: UUID, ok: Bool)] = []
    /// The last box handed over (nil when its broker has no relay).
    private(set) var lastSend: UUID?

    init(keys: ApproverKeys) { self.keys = keys }

    /// The broker's relay endpoints; nil without a usable relay URL.
    static func relay(for broker: PairedBroker) -> RelayHTTP? {
        // https; http only to this device (a relay in development).
        guard let string = broker.relay, let url = URL(string: string), let host = url.host(),
              let scheme = url.scheme?.lowercased(), scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1"].contains(host))
        else { return nil }
        return RelayHTTP(base: url, brokerID: broker.id)
    }

    func send(box: Data, to broker: PairedBroker) {
        lastSend = nil
        guard let relay = Self.relay(for: broker) else { return }
        let id = UUID()
        lastSend = id
        let approver = keys.id, signer = keys.transport
        running[id] = Task {
            var delivered = false
            // A retry is harmless: the broker takes the first valid decision.
            for attempt in 0..<3 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(attempt)) }
                do {
                    try await relay.send(box: box, approver: approver, transport: signer)
                    delivered = true
                    break
                } catch {
                    continue
                }
            }
            self.running[id] = nil
            self.finished.append((id, delivered))
            if self.finished.count > 16 { self.finished.removeFirst() }
            return delivered
        }
    }

    /// Before a send: `lastSend` then names only that send's box (nil when
    /// the center sent nothing).
    func forgetLastSend() { lastSend = nil }

    /// Waits for a box to reach the relay; false if it didn't.
    func result(of id: UUID?) async -> Bool {
        guard let id else { return false }
        if let done = finished.first(where: { $0.id == id }) { return done.ok }
        guard let task = running[id] else { return false }
        return await task.value
    }
}
