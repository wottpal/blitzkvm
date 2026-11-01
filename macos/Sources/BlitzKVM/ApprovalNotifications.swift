import AppKit
import ApprovalKit
import JetKVMCore
import UserNotifications

/// A notification per approval request ("Mac mini: sudo shutdown -r now",
/// "Code 47"), with Review (opens the panel) and Deny (no Touch ID: saying
/// no needs no presence). It goes when the request ends.
final class ApprovalNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let category = "APPROVAL"
    static let reviewAction = "REVIEW"
    static let denyAction = "DENY"

    private weak var service: ApprovalService?

    /// Notifications need an app bundle (swift run has none).
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil ? .current() : nil
    }

    /// At launch, so the actions of a notification that launched the app arrive.
    @MainActor
    func install(service: ApprovalService) {
        self.service = service
        guard let center else { return }
        center.delegate = self
        let review = UNNotificationAction(identifier: Self.reviewAction, title: "Review", options: [.foreground])
        let deny = UNNotificationAction(identifier: Self.denyAction, title: "Deny", options: [.destructive])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [review, deny],
                                                                 intentIdentifiers: [], options: [])])
    }

    /// Asked once approvals are on (macOS asks the user the first time only).
    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { AppLog.log("approvals: notifications: \(error.localizedDescription)") }
            else if !granted { AppLog.log("approvals: notifications are off") }
        }
    }

    /// Whether notifications reach the user (Settings says so when not).
    func authorized() async -> Bool? {
        guard let center else { return nil }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return true
        case .denied: return false
        default: return nil
        }
    }

    func post(_ r: OpenRequest, summary: ApprovalSummary) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = summary.notificationTitle
        content.body = summary.notificationBody
        content.categoryIdentifier = Self.category
        content.sound = .default
        content.threadIdentifier = r.brokerID
        content.userInfo = ["broker": r.brokerID, "request": r.id]
        center.add(UNNotificationRequest(identifier: r.id, content: content, trigger: nil)) { error in
            if let error { AppLog.log("approvals: notification not shown: \(error.localizedDescription)") }
        }
    }

    func remove(_ id: String) {
        center?.removeDeliveredNotifications(withIdentifiers: [id])
        center?.removePendingNotificationRequests(withIdentifiers: [id])
    }

    // MARK: UNUserNotificationCenterDelegate

    /// In front, the panel shows the request: the notification only goes to
    /// the list, with its sound.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["request"] as? String
        let action = response.actionIdentifier
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                if action == Self.denyAction, let id {
                    self?.service?.deny(requestID: id)
                } else if action != UNNotificationDismissActionIdentifier {
                    self?.service?.showPanel()
                }
            }
            completionHandler()
        }
    }
}
