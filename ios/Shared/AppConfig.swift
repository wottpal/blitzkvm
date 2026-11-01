import ApprovalKit
import Foundation

/// What the app and its notification service extension share: identifiers,
/// the keychain group that holds the approver's keys, and the App Group
/// file that holds the paired brokers and their rosters.
enum AppConfig {
    static let appGroup = "group.com.fmdlabs.blitzkvm"
    static let keychainService = "com.fmdlabs.blitzkvm.approvals"
    /// The keychain item `ApproverKeys` keeps the seal key in.
    static let sealKeyName = "seal"
    static let category = "APPROVAL"
    static let denyAction = "DENY"
    /// The userInfo key the extension adds to a request's notification.
    static let requestKey = "request"

    /// The shared keychain access group ("<team>.com.fmdlabs.blitzkvm.shared",
    /// Info.plist's BKKeychainAccessGroup). Nil in builds without a team,
    /// whose AppIdentifierPrefix is empty: they use the default group.
    static var keychainAccessGroup: String? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "BKKeychainAccessGroup") as? String,
              let prefix = group.split(separator: ".").first, prefix.count == 10,
              prefix.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { return nil }
        return group
    }

    static func keychain() -> KeychainBlobStore {
        KeychainBlobStore(service: keychainService, accessGroup: keychainAccessGroup)
    }

    /// The App Group container (the app's Application Support without one).
    static var container: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// ApprovalCenter's file: the paired brokers and their rosters.
    static var brokersFile: URL { container.appendingPathComponent("Approvals/brokers.json") }

    /// The paired brokers as the app last saved them.
    static func loadBrokers(from file: URL = brokersFile) -> [PairedBroker] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? Wire.decoder.decode([PairedBroker].self, from: data)) ?? []
    }
}
