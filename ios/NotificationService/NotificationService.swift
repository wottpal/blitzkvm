import ApprovalKit
import CryptoKit
import UserNotifications

/// Replaces the relay's generic alert ("Approval requested") with the
/// request itself: it opens the pushed box with the approver's seal key
/// (shared keychain group) and checks it against the roster the app saved
/// in the App Group. Anything that fails leaves the generic text.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        if let push = ApprovalPush(userInfo: request.content.userInfo) {
            content.threadIdentifier = push.brokerID
            if let text = Self.text(for: push) {
                content.title = text.title
                content.body = text.body
                content.threadIdentifier = text.thread
                if let id = text.requestID { content.userInfo[AppConfig.requestKey] = id }
            }
        }
        content.categoryIdentifier = AppConfig.category
        contentHandler(content)
    }

    static func text(for push: ApprovalPush) -> NotificationText? {
        guard push.box != nil, let raw = AppConfig.keychain().load(AppConfig.sealKeyName),
              let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw) else { return nil }
        let now = Int64(Date().timeIntervalSince1970)
        return PushedMessage(push, seal: SealKey(key), brokers: AppConfig.loadBrokers(), now: now).map(NotificationText.init)
    }
}
