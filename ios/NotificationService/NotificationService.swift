import ApprovalKit
import CryptoKit
import UserNotifications

/// Replaces the relay's generic alert ("Approval requested") with the
/// request itself: it opens the pushed box with the approver's seal key
/// (shared keychain group) and checks it against the roster the app saved
/// in the App Group. Anything that fails leaves the generic text.
///
/// The broker pushes an open request again until it's answered, each time
/// as a notification of its own (one replaced under the same id may not
/// alert again): this keeps only the newest of a request's notifications,
/// silences repeats when Repeat Until Answered is off, and turns the push
/// that ends a request into a quiet note of how it ended.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        // A quiet push (a request that ended) has nothing to deny, also when
        // it can't be opened.
        content.categoryIdentifier = request.content.interruptionLevel == .passive ? "" : AppConfig.category
        guard let push = ApprovalPush(userInfo: request.content.userInfo) else {
            contentHandler(content)
            return
        }
        content.threadIdentifier = push.brokerID
        guard let text = Self.text(for: push) else {
            contentHandler(content)
            return
        }
        content.title = text.title
        content.body = text.body
        content.threadIdentifier = text.thread
        if let id = text.requestID { content.userInfo[AppConfig.requestKey] = id }
        if text.ended {
            content.categoryIdentifier = "" // nothing left to deny
        }
        if text.ended || (text.repeats > 0 && !AppConfig.repeatsNotifications) {
            content.sound = nil
            content.interruptionLevel = .passive
        }
        guard let id = text.requestID else {
            contentHandler(content)
            return
        }
        // The request's earlier notifications go once this one shows.
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let older = delivered.filter { n in
                n.request.identifier != request.identifier && n.request.content.threadIdentifier == text.thread
                    && (n.request.content.userInfo[AppConfig.requestKey] as? String == id || n.request.identifier.hasPrefix(id))
            }.map(\.request.identifier)
            if !older.isEmpty { center.removeDeliveredNotifications(withIdentifiers: older) }
            contentHandler(content)
        }
    }

    static func text(for push: ApprovalPush) -> NotificationText? {
        guard push.box != nil, let raw = AppConfig.keychain().load(AppConfig.sealKeyName),
              let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw) else { return nil }
        let now = Int64(Date().timeIntervalSince1970)
        return PushedMessage(push, seal: SealKey(key), brokers: AppConfig.loadBrokers(), now: now).map(NotificationText.init)
    }
}
