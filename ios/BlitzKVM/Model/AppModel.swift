import ApprovalKit
import Foundation
import LocalAuthentication
import Observation
import UIKit
import UserNotifications

/// A request to show the pairing sheet, with an invite when one came in a
/// link.
struct PairingSheet: Identifiable {
    let id = UUID()
    var invite: PairingInvite?
}

/// The app: loads the approver's keys, routes notifications and links, and
/// holds the navigation state they change.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    enum Screen: Hashable { case requests, devices, settings }

    var screen: Screen = .requests
    /// A request to open (a notification was tapped).
    var openRequest: String?
    var pairingSheet: PairingSheet?
    private(set) var session: ApproverSession?
    private(set) var keysError: String?
    private(set) var notifications = NotificationStatus()

    init() { loadKeys() }

    /// Loads the keys (made in the Secure Enclave the first time).
    func loadKeys() {
        #if targetEnvironment(simulator) && DEBUG
        if DemoData.requested, let demo = try? DemoData.session() {
            session = demo
            if let i = DemoData.openIndex, demo.center.requests.indices.contains(i) { openRequest = demo.center.requests[i].id }
            if let screen = DemoData.screen { self.screen = screen }
            return
        }
        #endif
        let store = AppConfig.keychain()
        do {
            // Software keys on the Simulator, whose Secure Enclave makes none.
            let keys = try ApproverKeys.loadOrCreate(in: store)
            let name = UserDefaults.standard.string(forKey: ApproverSession.nameKey) ?? UIDevice.current.model
            session = ApproverSession(keys: keys, store: store, name: name, file: AppConfig.brokersFile)
            keysError = nil
        } catch {
            session = nil
            if !LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
                keysError = "BlitzKVM keeps its approval key in the Secure Enclave behind Face ID. Set up Face ID and a passcode in Settings, then try again."
            } else {
                keysError = "The approval keys couldn't be created or loaded: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Lifecycle

    func launched() {
        guard let session, !session.center.brokers.isEmpty else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func becameActive() {
        Task { await refreshNotificationStatus() }
        guard let session else { return }
        session.center.expire()
        Task { await session.refresh(sync: true) }
    }

    func refreshNotificationStatus() async {
        notifications = await NotificationStatus.current()
    }

    func didRegister(deviceToken: Data) {
        session?.setDeviceToken(deviceToken.map { String(format: "%02x", $0) }.joined())
    }

    // MARK: Routing

    func open(url: URL) {
        guard let invite = PairingCode.invite(from: url.absoluteString) else { return }
        screen = .devices
        pairingSheet = PairingSheet(invite: invite)
    }

    func startPairing() { pairingSheet = PairingSheet() }

    /// A push while the app is in front: take its box and fetch the rest.
    func receivedInForeground(_ userInfo: [AnyHashable: Any]) {
        guard let session else { return }
        session.receive(push: userInfo)
        Task { await session.refresh() }
    }

    func handle(_ response: UNNotificationResponse) async {
        guard let session else { return }
        let userInfo = response.notification.request.content.userInfo
        switch response.actionIdentifier {
        case AppConfig.denyAction:
            // The app may have been launched in the background for this.
            let task = UIApplication.shared.beginBackgroundTask(withName: "Deny")
            await session.deny(notification: userInfo)
            UIApplication.shared.endBackgroundTask(task)
        case UNNotificationDefaultActionIdentifier:
            screen = .requests
            if let r = await session.request(for: userInfo) { openRequest = r.id }
        default:
            break
        }
    }
}
