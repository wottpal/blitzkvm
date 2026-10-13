import AppKit
import Combine
import Sparkle

/// Updates from BlitzKVM's GitHub releases, through Sparkle: the appcast
/// (`SUFeedURL`) and every archive are signed with the EdDSA key whose public
/// half is Info.plist's `SUPublicEDKey`, and Sparkle checks that the new app
/// carries the same Developer ID signature before it installs it. Settings
/// and BlitzKVM › Check for Updates… drive it; Sparkle keeps the settings in
/// the app's user defaults.
@MainActor
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate, NSMenuItemValidation {
    /// `BLITZKVM_UPDATE_FEED`: an appcast URL to use instead of the
    /// published one (to test a release before publishing it).
    nonisolated static let feedOverride = ProcessInfo.processInfo.environment["BLITZKVM_UPDATE_FEED"]

    private var controller: SPUStandardUpdaterController!
    @Published private(set) var canCheck = false
    @Published private(set) var lastCheck: Date?
    private var observation: AnyCancellable?

    /// `start`: false for self-tests, which must not check or install.
    init(start: Bool) {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: self, userDriverDelegate: nil)
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheck = $0 }
        lastCheck = controller.updater.lastUpdateCheckDate
    }

    var updater: SPUUpdater { controller.updater }

    /// Checks now and shows the result (an update, or that this is the latest).
    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }

    /// BlitzKVM › Check for Updates… is off while a check runs.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(checkForUpdates(_:)) ? canCheck : true
    }

    /// Sparkle's own settings, written only when the user changes them.
    var checksAutomatically: Bool {
        get { updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyChecksForUpdates = newValue
        }
    }

    var installsAutomatically: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyDownloadsUpdates = newValue
        }
    }

    /// Whether the installation allows automatic installs (Sparkle can't
    /// update an app it may not write, e.g. in a read-only location).
    var allowsAutomaticInstalls: Bool { updater.allowsAutomaticUpdates }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? { Self.feedOverride }

    /// Sparkle calls its delegate on the main thread.
    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        MainActor.assumeIsolated { lastCheck = updater.lastUpdateCheckDate }
    }
}
