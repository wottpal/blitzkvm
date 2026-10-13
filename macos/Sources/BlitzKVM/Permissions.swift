import AppKit
import Network

/// The macOS permissions BlitzKVM needs, asked for on the welcome screen and
/// shown in Settings:
/// Local Network (required: JetKVMs answer on the local network) and
/// Accessibility (system shortcuts such as ⌘Tab reach the remote computer).
@MainActor
final class PermissionsModel: ObservableObject {
    enum LocalNetwork: Equatable {
        case notAsked
        /// macOS is showing its prompt, or the app is checking.
        case asking
        case allowed
        case denied
    }

    @Published private(set) var localNetwork = LocalNetwork.notAsked
    @Published private(set) var accessibility = InputController.accessibilityTrusted(prompt: false)
    /// The welcome screen shows: on first launch, and whenever Local Network
    /// access is off.
    @Published private(set) var showsOnboarding: Bool

    private static let doneKey = "onboardingDone"
    private static let localNetworkAskedKey = "localNetworkAsked"
    private var probe: LocalNetworkProbe?
    /// Local Network was checked since launch (it rarely changes once allowed).
    private var checkedLocalNetwork = false
    private var poll: Timer?
    /// Open views that show the permissions besides the welcome screen
    /// (Settings).
    private var watchers = 0
    private var activation: NSObjectProtocol?

    init() {
        showsOnboarding = !UserDefaults.standard.bool(forKey: Self.doneKey)
        // Returning from System Settings: pick up what changed there.
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
        updatePolling()
    }

    /// Re-reads both. Local Network only once it has been asked for
    /// (checking it the first time shows the system prompt), and once allowed
    /// only at launch and on the welcome screen, as each check briefly
    /// advertises on the network.
    func refresh() {
        accessibility = InputController.accessibilityTrusted(prompt: false)
        guard UserDefaults.standard.bool(forKey: Self.localNetworkAskedKey), localNetwork != .asking,
              !checkedLocalNetwork || localNetwork != .allowed || showsOnboarding || watchers > 0 else { return }
        checkLocalNetwork(timeout: 3)
    }

    // MARK: Local Network

    /// Shows the system prompt (the first time), or the settings pane once
    /// it was turned off.
    func allowLocalNetwork() {
        if localNetwork == .denied {
            return open("Privacy_LocalNetwork")
        }
        UserDefaults.standard.set(true, forKey: Self.localNetworkAskedKey)
        checkLocalNetwork(timeout: 120) // the user is reading the prompt
    }

    private func checkLocalNetwork(timeout: TimeInterval) {
        checkedLocalNetwork = true
        let wasAllowed = localNetwork == .allowed
        if !wasAllowed { localNetwork = .asking }
        let probe = LocalNetworkProbe()
        self.probe = probe
        probe.run(timeout: timeout) { [weak self] allowed in
            guard let self, self.probe === probe else { return }
            self.probe = nil
            switch allowed {
            case true?: self.localNetwork = .allowed
            case false?:
                self.localNetwork = .denied
                self.showsOnboarding = true // connecting can't work: say why
            case nil: if !wasAllowed { self.localNetwork = .notAsked }
            }
            self.updatePolling()
        }
    }

    // MARK: Accessibility

    /// Shows the system prompt the first time, then the settings pane.
    func allowAccessibility() {
        let asked = InputController.askedForAccessibilityKey
        if UserDefaults.standard.bool(forKey: asked) {
            open("Privacy_Accessibility")
        } else {
            UserDefaults.standard.set(true, forKey: asked)
            accessibility = InputController.accessibilityTrusted(prompt: true)
        }
    }

    // MARK: Welcome screen

    /// Settings shows the permissions: keep them current while it is open.
    func startWatching() {
        watchers += 1
        refresh()
        updatePolling()
    }

    func stopWatching() {
        watchers = max(0, watchers - 1)
        updatePolling()
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        showsOnboarding = false
        updatePolling()
    }

    /// Accessibility has no change notification: read it every second
    /// while the welcome screen or Settings shows.
    private func updatePolling() {
        guard showsOnboarding || watchers > 0 else {
            poll?.invalidate()
            poll = nil
            return
        }
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let trusted = InputController.accessibilityTrusted(prompt: false)
                if trusted != self.accessibility { self.accessibility = trusted }
            }
        }
    }

    private func open(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

/// Local Network privacy has no status API (Apple TN3179): the app
/// advertises a Bonjour service for a moment and browses for it. Finding it
/// means allowed, PolicyDenied means not allowed, and nothing means macOS is
/// still asking. The first check shows the system prompt. Publishing only
/// registers a record: no socket listens, so the firewall never asks.
private final class LocalNetworkProbe: NSObject {
    /// Listed in Info.plist's NSBonjourServices.
    static let serviceType = "_blitzkvm._tcp"
    private static let policyDenied: DNSServiceErrorType = -65570 // kDNSServiceErr_PolicyDenied

    private let name = UUID().uuidString
    private var service: NetService?
    private var browser: NWBrowser?
    private var completion: ((Bool?) -> Void)?

    /// Calls back on the main queue: true (allowed), false (denied) or nil
    /// (no answer within the timeout).
    func run(timeout: TimeInterval, completion: @escaping (Bool?) -> Void) {
        self.completion = completion
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: NWParameters())
        browser.stateUpdateHandler = { [weak self] state in
            if case .waiting(let error) = state, case .dns(let code) = error, code == Self.policyDenied {
                self?.finish(false)
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let found = results.contains {
                if case .service(let name, _, _, _) = $0.endpoint { return name == self.name }
                return false
            }
            if found { self.finish(true) }
        }
        self.browser = browser
        browser.start(queue: .main)
        let service = NetService(domain: "local.", type: Self.serviceType + ".", name: name, port: 9)
        self.service = service
        service.publish()
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(nil) }
    }

    private func finish(_ allowed: Bool?) {
        guard let completion else { return }
        self.completion = nil
        browser?.cancel()
        service?.stop()
        completion(allowed)
    }
}
