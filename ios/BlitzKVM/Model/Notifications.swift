import ApprovalKit
import UIKit
import UserNotifications

/// The notification side: the APPROVAL category, authorization, the badge,
/// and clearing notifications of requests that ended.
enum Notifications {
    /// "Deny" works from the notification (the transport key signs it, no
    /// Face ID); approving always happens in the app. It asks for the device
    /// to be unlocked, as the transport key is only usable then.
    static func registerCategories() {
        let deny = UNNotificationAction(identifier: AppConfig.denyAction, title: "Deny",
                                        options: [.destructive, .authenticationRequired])
        let category = UNNotificationCategory(identifier: AppConfig.category, actions: [deny], intentIdentifiers: [],
                                              hiddenPreviewsBodyPlaceholder: "Approval requested", options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Asks once for alerts, then registers for remote notifications (the
    /// token arrives in the app delegate).
    @MainActor static func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        UIApplication.shared.registerForRemoteNotifications()
    }

    static func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count)
    }

    /// The request a delivered notification is about.
    private static func requestID(_ n: UNNotification) -> String? {
        if let id = n.request.content.userInfo[AppConfig.requestKey] as? String { return id }
        return requestID(identifier: n.request.identifier)
    }

    /// The request a notification identifier names: the relay collapses a
    /// request's pushes under its id, "<id>", its repeats "<id>.<n>", the
    /// push that ends it "<id>.end".
    static func requestID(identifier: String) -> String? {
        let id = String(identifier.prefix { $0 != "." })
        return id.count == 32 && Data(hex: id) != nil ? id : nil
    }

    static func removeDelivered(requestID: String) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered.filter { Self.requestID($0) == requestID }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    /// Removes notifications of requests that are no longer open: ended
    /// ones, and any older than an ask can live.
    static func prune(open: Set<String>, ended: Set<String>) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let cutoff = Date().addingTimeInterval(-Double(Limits.maxAskLifetime + 10))
            let ids = delivered.filter { n in
                guard let id = Self.requestID(n), !open.contains(id) else { return false }
                return ended.contains(id) || n.date < cutoff
            }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }
}

/// What the user allowed.
struct NotificationStatus: Equatable {
    var authorization: UNAuthorizationStatus = .notDetermined
    var timeSensitive: UNNotificationSetting = .notSupported

    var allowed: Bool { [.authorized, .provisional, .ephemeral].contains(authorization) }

    static func current() async -> NotificationStatus {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        return NotificationStatus(authorization: s.authorizationStatus, timeSensitive: s.timeSensitiveSetting)
    }
}
