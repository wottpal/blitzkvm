import AppKit
import ApprovalKit
import Combine
import JetKVMCore
import LocalAuthentication
import SystemConfiguration

/// Remote approvals on this Mac (approval/PROTOCOL.md): this Mac is an
/// approver of the JetKVMs that turned them on (BlitzKVM firmware D20). It
/// keeps a channel to each one's broker (directly to the JetKVM, and
/// through the relay when there is one), shows each request in a panel and
/// a notification, and signs decisions behind Touch ID.
///
/// Nothing happens until approvals are used: the keys are made when this
/// Mac first turns them on (JetKVM Setup), and later launches pick up the
/// paired JetKVMs from approvals.json. Self-tests never start it.
@MainActor
final class ApprovalService: ObservableObject, CenterTransport {
    static let shared = ApprovalService()

    /// Settings › Approvals' relay URL; new rosters name it (no default).
    static let relayKey = "approvalsRelayURL"
    /// Opens Settings › Approvals (the app delegate listens).
    static let showSettings = Notification.Name("BlitzKVMShowApprovalsSettings")
    static let file = DeviceStore.defaultURL().deletingLastPathComponent().appendingPathComponent("approvals.json")
    /// How long an ended request stays in the panel, saying how it ended.
    static let endedFor: TimeInterval = 4

    /// nil until approvals are used on this Mac.
    @Published private(set) var center: ApprovalCenter?
    private(set) var keys: ApproverKeys?
    /// The passwords the JetKVM may type for one approval, behind Touch ID.
    let vault = SecretVault(store: KeychainBlobStore(service: "xyz.scio.blitzkvm.approvals.vault"))
    /// Changes when a password is stored or removed (the vault isn't observable).
    @Published private(set) var vaultRevision = 0
    /// The channels that are up, per broker.
    @Published private(set) var routes: [String: Set<ApprovalRoute>] = [:]
    /// Requests that ended a moment ago, newest first.
    @Published private(set) var ended: [(request: OpenRequest, until: Date)] = []
    /// What this Mac answered, by request, until the broker says how it went.
    @Published private(set) var answered: [String: String] = [:]

    let notifications = ApprovalNotifications()
    private lazy var panel = ApprovalPanelController(service: self)
    private var channels: [String: BrokerChannels] = [:]
    private var outbox = ApprovalOutbox()
    private var generation = 0
    private var timer: Timer?
    private var started = false
    private var subscriptions = Set<AnyCancellable>()

    private final class BrokerChannels {
        var direct: (channel: BoxChannel, generation: Int)?
        var relay: (channel: BoxChannel, generation: Int)?
    }

    private init() {}

    /// At launch: picks up the JetKVMs paired before.
    func start() {
        guard !started else { return }
        started = true
        notifications.install(service: self)
        guard FileManager.default.fileExists(atPath: Self.file.path) else { return }
        do {
            try prepare()
            if center?.brokers.isEmpty == false { notifications.requestAuthorization() }
        } catch {
            AppLog.log("approvals: can't load this Mac's keys: \(error)")
        }
    }

    /// The approval state, loaded (and this Mac's keys made) on first use.
    @discardableResult
    func prepare() throws -> ApprovalCenter {
        if let center { return center }
        let keys = try ApproverKeys.loadOrCreate(in: KeychainBlobStore())
        let center = ApprovalCenter(keys: keys, name: Self.computerName, platform: "macos", file: Self.file)
        center.transport = self
        center.onRequest = { [weak self] in self?.requestArrived($0) }
        center.onStatus = { [weak self] in self?.requestEnded($0) }
        self.keys = keys
        self.center = center
        // @Published sends the new value before the property has it.
        center.$brokers.sink { [weak self] in self?.reconcile($0) }.store(in: &subscriptions)
        center.$requests.sink { [weak self] requests in
            // A typing ask stays open while the JetKVM types: its notification can go.
            for r in requests where r.state != "pending" { self?.notifications.remove(r.id) }
        }.store(in: &subscriptions)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        AppLog.log("approvals: approver \(keys.id) (\(keys.hardwareBacked ? "Secure Enclave" : "software keys")), "
            + "\(center.brokers.count) JetKVM\(center.brokers.count == 1 ? "" : "s")")
        return center
    }

    /// This Mac's name as other approvers see it (read without a network
    /// lookup, unlike Host.current()).
    static var computerName: String { (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac" }

    /// Whether this Mac's keys are (or would be) in the Secure Enclave.
    var hardwareBacked: Bool { keys?.hardwareBacked ?? ApproverKeys.hasSecureEnclave }

    // MARK: Channels

    /// One direct channel per broker that has a device URL, one relay
    /// channel per broker whose roster names a relay.
    private func reconcile(_ brokers: [PairedBroker]) {
        guard let keys else { return }
        for b in brokers {
            let c = channels[b.id] ?? BrokerChannels()
            channels[b.id] = c
            let direct = b.direct.flatMap(URL.init(string:)).flatMap(BoxChannel.directURL(deviceBase:))
            if c.direct?.channel.url != direct {
                if let old = c.direct { old.channel.stop(); markDown(b.id, .direct) }
                c.direct = direct.map { (makeChannel($0, .direct, broker: b.id, keys: keys), generation) }
                c.direct?.channel.start()
            }
            let relay = b.relay.flatMap { BoxChannel.relayURL(base: $0, broker: b.id, approver: keys.id) }
            if c.relay?.channel.url != relay {
                if let old = c.relay { old.channel.stop(); markDown(b.id, .relay) }
                c.relay = relay.map { (makeChannel($0, .relay, broker: b.id, keys: keys), generation) }
                c.relay?.channel.start()
            }
        }
        for (id, c) in channels where !brokers.contains(where: { $0.id == id }) {
            c.direct?.channel.stop()
            c.relay?.channel.stop()
            channels[id] = nil
            routes[id] = nil
            _ = outbox.take(for: id, at: Self.now)
        }
    }

    private func makeChannel(_ url: URL, _ route: ApprovalRoute, broker: String, keys: ApproverKeys) -> BoxChannel {
        generation += 1
        let gen = generation
        return BoxChannel(url: url, route: route == .direct ? .direct : .relay, brokerID: broker, approverID: keys.id,
                          transport: keys.transport, serverTrust: route == .direct ? Self.devicePinTrust(for: url) : nil,
                          onBox: { [weak self] box in
                              DispatchQueue.main.async { MainActor.assumeIsolated { self?.center?.receive(box: box, from: broker) } }
                          },
                          onState: { [weak self] up in
                              DispatchQueue.main.async { MainActor.assumeIsolated { self?.channel(broker, route, gen, up: up) } }
                          })
    }

    /// An https JetKVM shows its own certificate authority: accept the one
    /// pinned for that address in the device library, or, unpinned, any
    /// (approvals are sealed and signed end to end; TLS only hides the
    /// handshake there).
    nonisolated static func devicePinTrust(for url: URL) -> (@Sendable (SecTrust) -> Bool)? {
        guard url.scheme == "wss", let host = url.host else { return nil }
        let store = DeviceStore(url: DeviceStore.defaultURL())
        store.load()
        let pin = store.devices.first { device in
            device.addresses.contains { (URL(string: $0)?.host ?? $0) == host }
        }?.certificateSHA256
        return { trust in pin == nil || CertificatePin.accepts(trust, pin: pin) }
    }

    private func channel(_ broker: String, _ route: ApprovalRoute, _ gen: Int, up: Bool) {
        guard let c = channels[broker], (route == .direct ? c.direct?.generation : c.relay?.generation) == gen else { return }
        guard up else { return markDown(broker, route) }
        routes[broker, default: []].insert(route)
        AppLog.log("approvals: \(center?.broker(broker)?.name ?? broker) connected (\(route.rawValue))")
        let held = outbox.take(for: broker, at: Self.now)
        if let b = center?.broker(broker) { held.forEach { send(box: $0, to: b) } }
        center?.sync(broker)
    }

    private func markDown(_ broker: String, _ route: ApprovalRoute) {
        guard routes[broker]?.contains(route) == true else { return }
        routes[broker]?.remove(route)
    }

    /// The connected direct channel, else the relay's; else the box waits
    /// for one (30 s at most).
    func send(box: Data, to broker: PairedBroker) {
        let c = channels[broker.id]
        let direct = c?.direct?.channel, relay = c?.relay?.channel
        switch ApprovalOutbox.route(directConnected: direct?.isConnected ?? false, relayConnected: relay?.isConnected ?? false) {
        case .direct?: if direct?.send(box: box) == true || relay?.send(box: box) == true { return }
        case .relay?: if relay?.send(box: box) == true { return }
        case nil: break
        }
        outbox.hold(box, for: broker.id, at: Self.now)
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// A device window connected at `address`: see deviceState.
    func deviceConnected(engine: EngineProcess, address: String) {
        guard let center, !center.brokers.isEmpty else { return }
        Task {
            if let state = try? await engine.call("getApprovalsState", as: DeviceApprovals.self) {
                deviceState(state, address: address)
            }
        }
    }

    /// What a connected JetKVM says about its approvals, over the window's
    /// identity-pinned session: the direct channel follows the window (LAN
    /// address at home, tailnet name away), and a pairing the JetKVM no
    /// longer has goes (approvals turned off, this Mac revoked), so no
    /// channel keeps knocking.
    func deviceState(_ state: DeviceApprovals, address: String) {
        guard let center, let b = center.broker(state.broker.id) else { return }
        if !state.enabled || !(state.approvers ?? []).contains(where: { $0.id == center.keys.id }) {
            AppLog.log("approvals: \(b.name) \(state.enabled ? "no longer lists this Mac" : "has approvals off"); forgetting it")
            center.remove(brokerID: b.id)
        } else if let base = ApprovalAddress.base(address), b.direct != base {
            AppLog.log("approvals: \(b.name) reached at \(base)")
            center.setDirect(base, brokerID: b.id)
        }
    }

    // MARK: Requests

    private func tick() {
        center?.expire()
        outbox.prune(at: Self.now)
        if ended.contains(where: { $0.until < Date() }) { ended.removeAll { $0.until < Date() } }
        // Requests also go with their target or broker (a roster change, Turn Off).
        panel.update()
    }

    private func requestArrived(_ r: OpenRequest) {
        AppLog.log("approvals: request \(r.id) (\(r.ask.kind)) from \(center?.broker(r.brokerID)?.name ?? r.brokerID)")
        notifications.post(r, summary: summary(r))
        panel.show()
    }

    private func requestEnded(_ r: OpenRequest) {
        notifications.remove(r.id)
        answered[r.id] = nil
        ended.insert((r, Date().addingTimeInterval(Self.endedFor)), at: 0)
        panel.update()
    }

    func summary(_ r: OpenRequest) -> ApprovalSummary {
        ApprovalSummary(r, broker: center?.broker(r.brokerID),
                        passwordStored: r.ask.secret != SecretKind.none && vault.has(target: r.ask.target, kind: r.ask.secret))
    }

    /// The name of an approver of a request's broker.
    func approverName(_ id: String?, brokerID: String) -> String? {
        guard let id else { return nil }
        return center?.roster(brokerID)?.approver(id)?.name
    }

    func showPanel() { panel.show() }

    /// Approves with Touch ID (or the Mac's password): one evaluated context
    /// signs with the presence key and opens the stored password. `typed`
    /// is a password entered for this request, kept when `remember`.
    func approve(_ r: OpenRequest, grant: Bool, typed: String?, remember: Bool) async throws {
        guard let center, let keys else { return }
        let summary = summary(r)
        let context = LAContext()
        try await Self.authenticate(context, reason: summary.authenticationReason)
        guard r.ask.expires > Int64(Date().timeIntervalSince1970) else { throw ApprovalError("The request expired.") }
        var secret: String?
        if let password = summary.password {
            if let typed, !typed.isEmpty {
                secret = typed
                if remember { try storePassword(typed, target: r.ask.target, kind: password.kind) }
            } else {
                secret = try vault.secret(target: r.ask.target, kind: password.kind, context: context)
            }
            guard secret != nil else { throw ApprovalError("No \(password.name) is stored for \(summary.targetName).") }
        }
        try center.approve(r, grant: grant, secret: secret, presence: keys.presence(with: context))
        answered[r.id] = grant ? "Approved for 10 minutes" : "Approved"
        AppLog.log("approvals: approved \(r.id)\(grant ? " for 10 minutes" : "")\(secret == nil ? "" : " with the \(summary.password?.name ?? "password")")")
    }

    /// Denies without Touch ID (saying no needs no presence).
    func deny(_ r: OpenRequest) throws {
        try center?.deny(r)
        answered[r.id] = "Denied"
        AppLog.log("approvals: denied \(r.id)")
    }

    /// Denies an open request by id (the notification's Deny).
    func deny(requestID: String) {
        guard let r = center?.requests.first(where: { $0.id == requestID && $0.state == "pending" }) else { return }
        try? deny(r)
    }

    /// Asks the computer to unlock its screen: it raises an unlock request
    /// that names this Mac, approved like any other (Touch ID).
    func unlock(brokerID: String, target: String) throws {
        guard let center else { throw ApprovalError("Approvals aren't set up on this Mac.") }
        try center.unlock(brokerID, target: target)
    }

    // MARK: Owners

    /// One Touch ID for an owner's change, signed with the presence key.
    @discardableResult
    func signAsOwner<T>(reason: String, _ change: (EnvelopeSigner) throws -> T) async throws -> T {
        guard let keys else { throw ApprovalError("Approvals aren't set up on this Mac.") }
        let context = LAContext()
        try await Self.authenticate(context, reason: reason)
        return try change(keys.presence(with: context))
    }

    // MARK: Passwords

    func hasPassword(target: String, kind: String) -> Bool { vault.has(target: target, kind: kind) }

    func storePassword(_ password: String, target: String, kind: String) throws {
        try vault.store(password, target: target, kind: kind)
        vaultRevision += 1
    }

    func removePassword(target: String, kind: String) {
        vault.remove(target: target, kind: kind)
        vaultRevision += 1
    }

    // MARK: Touch ID

    /// Touch ID, or the Mac's password where there is none.
    /// Device windows let go of the keyboard when this is posted: nothing
    /// typed into a Touch ID or password prompt may reach a remote computer.
    static let releaseKeyboard = Notification.Name("BlitzKVMReleaseKeyboard")

    static func authenticate(_ context: LAContext, reason: String) async throws {
        await MainActor.run { NotificationCenter.default.post(name: releaseKeyboard, object: nil) }
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw error ?? LAError(.passcodeNotSet)
        }
        _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }

    /// Cancelling Touch ID isn't an error to show.
    static func isCancellation(_ error: Error) -> Bool {
        guard let error = error as? LAError else { return false }
        return [.userCancel, .systemCancel, .appCancel].contains(error.code)
    }
}

struct ApprovalError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
