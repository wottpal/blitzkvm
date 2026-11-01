import ApprovalKit
import Combine
import Foundation
import LocalAuthentication
import Observation
import UIKit

/// What this iPhone sent for a request, until the broker's status arrives.
enum SentDecision: Equatable {
    case sending
    case approved(grant: Bool)
    case denied
}

/// A broker's relay as last seen.
enum RelayState: Equatable {
    case ok(Date)
    case failed(String)
}

enum PairingPhase: Equatable {
    case idle
    case enrolling
    case waiting(broker: String, since: Date)
    case done(String)
    case failed(String)
}

/// The approver with its keys: wraps ApprovalCenter with the relay (the
/// phone's only transport), the vault, pairing and push registration.
@MainActor @Observable
final class ApproverSession {
    let keys: ApproverKeys
    let vault: PasswordVault
    private(set) var center: ApprovalCenter
    private(set) var relayStates: [String: RelayState] = [:]
    private(set) var sent: [String: SentDecision] = [:]
    private(set) var pairing: PairingPhase = .idle
    private(set) var isRefreshing = false
    private(set) var deviceToken: String?
    /// Bumped when a stored password changes, so views read the vault again.
    private(set) var passwordsVersion = 0

    @ObservationIgnored private let transport: RelayTransport
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var registered = Set<String>()
    @ObservationIgnored private var pairingTask: Task<Void, Never>?
    @ObservationIgnored private var badge: AnyCancellable?

    static let nameKey = "approverName"

    init(keys: ApproverKeys, store: BlobStore, name: String, file: URL?) {
        self.keys = keys
        self.file = file
        vault = Vaults.make(store: store)
        transport = RelayTransport(keys: keys)
        center = ApprovalCenter(keys: keys, name: name, platform: "ios", file: file)
        attach(center)
    }

    private func attach(_ center: ApprovalCenter) {
        center.transport = transport
        center.onStatus = { r in Notifications.removeDelivered(requestID: r.id) }
        badge = center.$requests
            .map { $0.filter { $0.state == "pending" }.count }
            .removeDuplicates()
            .sink { Notifications.setBadge($0) }
    }

    private var now: Int64 { Int64(Date().timeIntervalSince1970) }

    // MARK: This approver

    /// The name owners see when this iPhone asks to pair.
    var name: String { center.name }

    /// Renames this approver for later pairings (a roster keeps the name the
    /// device enrolled with). ApprovalCenter's name is fixed, so this makes a
    /// new center from the same file.
    func rename(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != center.name else { return }
        UserDefaults.standard.set(trimmed, forKey: Self.nameKey)
        center.transport = nil
        center = ApprovalCenter(keys: keys, name: trimmed, platform: "ios", file: file)
        attach(center)
        Task { await refresh(sync: true) }
    }

    /// Whether the roster lists this iPhone (an owner admitted it).
    func isAdmitted(_ brokerID: String) -> Bool { center.roster(brokerID)?.approver(keys.id) != nil }

    func approverName(_ id: String?, brokerID: String) -> String? {
        guard let id else { return nil }
        if id == keys.id { return "this iPhone" }
        return center.roster(brokerID)?.approver(id)?.name
    }

    /// Every computer of every paired JetKVM, once.
    var targets: [(target: Target, broker: PairedBroker)] {
        var seen = Set<String>()
        return center.brokers.flatMap { b in (b.decodedRoster?.targets ?? []).map { (target: $0, broker: b) } }
            .filter { seen.insert($0.target.id).inserted }
    }

    // MARK: Receiving

    /// Fetches what the brokers queued for this iPhone. `sync` first asks
    /// the brokers for their roster and open requests (they arrive a moment
    /// later, so the outbox is fetched again).
    func refresh(sync: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefresh = Date()
        }
        if sync {
            for b in center.brokers where isAdmitted(b.id) && RelayTransport.relay(for: b) != nil { center.sync(b.id) }
        }
        await fetchOutboxes()
        if sync {
            try? await Task.sleep(for: .seconds(1.5))
            await fetchOutboxes()
        }
        center.expire()
        Notifications.prune(open: Set(center.requests.map(\.id)), ended: Set(center.history.map(\.id)))
    }

    private func fetchOutboxes() async {
        for b in center.brokers { await fetchOutbox(b) }
    }

    private func fetchOutbox(_ broker: PairedBroker) async {
        guard let relay = RelayTransport.relay(for: broker) else {
            relayStates[broker.id] = nil
            return
        }
        do {
            let boxes = try await relay.outbox(approver: keys.id, transport: keys.transport)
            for box in boxes { center.receive(box: box, from: broker.id) }
            relayStates[broker.id] = .ok(Date())
        } catch {
            relayStates[broker.id] = .failed(ErrorText.describe(error))
        }
    }

    /// Expires requests every second and fetches the outbox every
    /// `interval` while the app is active, until cancelled (a view's task).
    func poll(every interval: TimeInterval) async {
        while !Task.isCancelled {
            center.expire()
            if UIApplication.shared.applicationState == .active, Date().timeIntervalSince(lastRefresh) >= interval {
                await refresh()
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Takes a push's box (when it carried one) and returns the request it
    /// is about, if known.
    @discardableResult
    func receive(push userInfo: [AnyHashable: Any]) -> String? {
        guard let push = ApprovalPush(userInfo: userInfo) else { return nil }
        if let box = push.box { center.receive(box: box, from: push.brokerID) }
        if let id = userInfo[AppConfig.requestKey] as? String { return id }
        if let message = PushedMessage(push, seal: keys.seal, brokers: center.brokers, now: now),
           case let .request(verified, _, _) = message { return verified.id }
        return nil
    }

    /// The request a notification is about: the one it names, else the only
    /// pending one of its broker (a push without the box).
    func request(for userInfo: [AnyHashable: Any]) async -> OpenRequest? {
        let id = receive(push: userInfo)
        func find() -> OpenRequest? {
            if let id { return center.requests.first { $0.id == id } }
            guard let broker = ApprovalPush(userInfo: userInfo)?.brokerID else { return nil }
            let pending = center.requests.filter { $0.brokerID == broker && $0.state == "pending" }
            return pending.count == 1 ? pending[0] : nil
        }
        if let r = find() { return r }
        await refresh()
        return find()
    }

    // MARK: Deciding

    /// Approves behind one Face ID: the evaluated context signs with the
    /// presence key and, when attached, reads the stored password.
    func approve(_ r: OpenRequest, grant: Bool, attachSecret: Bool) async throws {
        guard r.ask.expires > now else { throw UserError("This request has expired.") }
        let target = center.roster(r.brokerID)?.target(r.ask.target)?.name ?? "the computer"
        let context = LAContext()
        try await Biometrics.authenticate(context, reason: "Approve “\(r.ask.title)” on \(target)")
        var secret: String?
        if attachSecret, r.ask.secret != SecretKind.none {
            do {
                secret = try vault.secret(target: r.ask.target, kind: r.ask.secret, context: context)
            } catch {
                throw UserError("The stored \(KindInfo.secretName(r.ask.secret)) can't be read (Face ID may have changed). Enter it again in Settings.")
            }
            guard secret != nil else { throw UserError("No \(KindInfo.secretName(r.ask.secret)) is stored for \(target).") }
        }
        try await deliver(r, as: .approved(grant: grant)) {
            try self.center.approve(r, grant: grant, secret: secret, presence: self.keys.presence(with: context))
        }
    }

    /// Asks a computer to unlock its screen: if it's locked, it raises an
    /// unlock request naming this iPhone, approved with Face ID like any
    /// other (the JetKVM then types the Mac's password there).
    func unlock(brokerID: String, target: String) async throws {
        try center.unlock(brokerID, target: target)
        guard await transport.result(of: transport.lastSend) else {
            throw UserError("The request didn't reach the relay. Check the connection and try again.")
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            await refresh()
        }
    }

    /// Denies with the transport key: no Face ID needed to say no.
    func deny(_ r: OpenRequest) async throws {
        try await deliver(r, as: .denied) { try self.center.deny(r) }
    }

    private func deliver(_ r: OpenRequest, as decision: SentDecision, _ make: () throws -> Void) async throws {
        sent[r.id] = .sending
        do {
            try make()
        } catch {
            sent[r.id] = nil
            throw error
        }
        guard await transport.result(of: transport.lastSend) else {
            sent[r.id] = nil
            throw UserError("The decision didn't reach the relay. Check the connection and try again.")
        }
        sent[r.id] = decision
        Notifications.removeDelivered(requestID: r.id)
        Task {
            try? await Task.sleep(for: .seconds(1))
            await refresh()
        }
    }

    /// The notification's Deny action (the app may run in the background).
    func deny(notification userInfo: [AnyHashable: Any]) async {
        guard let r = await request(for: userInfo), r.state == "pending", sent[r.id] == nil else { return }
        try? await deny(r)
    }

    // MARK: Owners

    /// Admits a device that asked to pair (owners only), behind Face ID.
    func admit(_ e: Enrollment, asOwner: Bool) async throws {
        let context = LAContext()
        try await Biometrics.authenticate(context, reason: "Admit “\(e.approver.name)”")
        try center.admit(e, owner: asOwner, presence: keys.presence(with: context))
        guard await transport.result(of: transport.lastSend) else {
            throw UserError("The new roster didn't reach the relay. Try again.")
        }
    }

    func decline(_ e: Enrollment) { center.decline(e) }

    // MARK: Passwords

    func hasPassword(target: String, kind: String) -> Bool {
        _ = passwordsVersion
        return vault.has(target: target, kind: kind)
    }

    /// Stores a password after a Face ID (storing itself needs none).
    func storePassword(_ password: String, target: String, targetName: String, kind: String) async throws {
        let context = LAContext()
        try await Biometrics.authenticate(context, reason: "Store the \(KindInfo.secretName(kind)) for \(targetName)")
        try vault.store(password, target: target, kind: kind)
        passwordsVersion += 1
    }

    func removePassword(target: String, kind: String) {
        vault.remove(target: target, kind: kind)
        passwordsVersion += 1
    }

    // MARK: Devices

    /// Forgets a JetKVM here, with the passwords of computers no other
    /// paired JetKVM has. The roster still lists this iPhone until an owner
    /// revokes it.
    func remove(_ broker: PairedBroker) {
        let targets = broker.decodedRoster?.targets.map(\.id) ?? []
        center.remove(brokerID: broker.id)
        relayStates[broker.id] = nil
        let remaining = Set(center.brokers.flatMap { $0.decodedRoster?.targets.map(\.id) ?? [] })
        for t in targets where !remaining.contains(t) {
            for kind in KindInfo.secretKinds { vault.remove(target: t, kind: kind) }
        }
        passwordsVersion += 1
    }

    // MARK: Pairing

    static func noRelayMessage(_ name: String) -> String {
        "\(name) has no relay. An iPhone reaches its JetKVM only through the relay: set one up in BlitzKVM on the Mac, then show a new pairing code."
    }

    func pair(_ invite: PairingInvite, name: String) {
        pairingTask?.cancel()
        pairingTask = Task { await runPairing(invite, name: name) }
    }

    /// Stops waiting for the owner; the JetKVM stays listed until removed.
    func cancelPairing() {
        pairingTask?.cancel()
        pairingTask = nil
        pairing = .idle
    }

    /// Clears a finished or failed pairing.
    func resetPairing() {
        switch pairing {
        case .done, .failed: pairing = .idle
        default: break
        }
    }

    /// Enrolls through the relay, then waits for an owner to admit this
    /// iPhone (the roster arrives in the outbox) and registers for pushes.
    private func runPairing(_ invite: PairingInvite, name: String) async {
        let id = invite.broker.id
        guard let relayURL = invite.relay.flatMap(URL.init(string:)), relayURL.host() != nil else {
            pairing = .failed(Self.noRelayMessage(invite.name))
            return
        }
        rename(name)
        if isAdmitted(id) {
            pairing = .done(invite.name)
            return
        }
        // A pairing that never finished: start over with this invite's owner.
        if let existing = center.broker(id), existing.roster == nil { center.remove(brokerID: id) }
        pairing = .enrolling
        do {
            let box = try center.join(invite)
            try await RelayHTTP(base: relayURL, brokerID: id).enroll(box: box)
        } catch {
            if center.broker(id)?.roster == nil { center.remove(brokerID: id) }
            pairing = .failed(ErrorText.describe(error))
            return
        }
        await Notifications.requestAuthorization()
        pairing = .waiting(broker: invite.name, since: Date())
        let deadline = Date().addingTimeInterval(5 * 60) // the pairing token's lifetime
        while !Task.isCancelled, Date() < deadline {
            if let broker = center.broker(id) { await fetchOutbox(broker) }
            if isAdmitted(id) {
                await registerPush()
                pairing = .done(invite.name)
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
        if !Task.isCancelled {
            pairing = .failed("No owner admitted this iPhone within 5 minutes. Pair again with a new code.")
        }
    }

    // MARK: Push

    static var apnsEnvironment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    func setDeviceToken(_ token: String) {
        deviceToken = token
        Task { await registerPush() }
    }

    /// Registers the APNs token with the relay of every JetKVM that admitted
    /// this iPhone (the relay refuses others), once per launch.
    func registerPush() async {
        guard let token = deviceToken else { return }
        for b in center.brokers where isAdmitted(b.id) {
            let key = "\(b.id) \(token)"
            guard !registered.contains(key), let relay = RelayTransport.relay(for: b) else { continue }
            do {
                try await relay.register(token: token, env: Self.apnsEnvironment, approver: keys.id, transport: keys.transport)
                registered.insert(key)
            } catch {
                relayStates[b.id] = .failed(ErrorText.describe(error))
            }
        }
    }
}
