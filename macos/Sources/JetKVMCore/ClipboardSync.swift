import Foundation

/// Clipboard sync with a remote Mac over the BlitzKVM firmware's USB link
/// (pkg/hostlink): set up once from JetKVM Setup, which installs this Mac's
/// key on the remote Mac, then on or off per device.
public struct ClipboardSync: Codable, Equatable {
    /// The remote Mac's account the key was installed for.
    public var user: String
    /// The remote Mac's name, for display.
    public var computerName: String?
    /// The remote Mac's SSH host key, pinned at setup (authorized_keys format).
    public var hostKey: String
    /// Syncing; off keeps the key installed.
    public var enabled: Bool

    public init(user: String, computerName: String?, hostKey: String, enabled: Bool = true) {
        self.user = user
        self.computerName = computerName
        self.hostKey = hostKey
        self.enabled = enabled
    }
}

/// What of a pasteboard item goes to the other Mac, the same rules as the
/// remote side's clipboard.js.
public enum ClipboardPolicy {
    /// Added to what sync puts on a pasteboard, with the device ID it came
    /// from, so it isn't sent back there.
    public static let marker = "com.blitzkvm.synced"
    /// A clip's data limit; what doesn't fit is left out from the end of
    /// `types` (images first).
    public static let maxBytes = 8 << 20
    /// The types synced, most important first.
    public static let types = ["public.utf8-plain-text", "public.rtf", "public.html", "public.url", "public.png", "public.tiff"]
    /// Password managers mark secrets and one-off data so that clipboard
    /// tools leave them alone (nspasteboard.org).
    public static let privateTypes = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]

    /// The data to send for an item with `types`, read through `data`; nil
    /// when it has nothing synced, or is private and not `includingPrivate`
    /// (pasted on purpose: an app's paste into the window, which dictation
    /// apps mark transient). A private item keeps its marks, so the other
    /// Mac's clipboard tools leave it alone too.
    public static func select(types itemTypes: [String], includingPrivate: Bool = false, data: (String) -> Data?) -> [String: Data]? {
        let marks = privateTypes.filter(itemTypes.contains)
        if !marks.isEmpty && !includingPrivate { return nil }
        var items: [String: Data] = [:]
        var size = 0
        for type in types where itemTypes.contains(type) {
            if type == "public.tiff" && items["public.png"] != nil { continue } // the same image, larger
            guard let value = data(type), size + value.count <= maxBytes else { continue }
            size += value.count
            items[type] = value
        }
        guard !items.isEmpty else { return nil }
        for mark in marks { items[mark] = Data() }
        return items
    }

    /// The engine's clipboardSet parameters for `items` (base64 data).
    public static func params(_ items: [String: Data]) -> JSONValue {
        .object(["items": .object(items.mapValues { .string($0.base64EncodedString()) })])
    }

    /// Decodes a "clipboard" event's clip ({"items": {type: base64}}),
    /// keeping only the synced types within the size limit: what the remote
    /// Mac sends can't put files or other types on this Mac's clipboard.
    public static func items(fromClip clip: Any?) -> [String: Data]? {
        guard let object = clip as? [String: Any], let encoded = object["items"] as? [String: String] else { return nil }
        return select(types: Array(encoded.keys)) { type in encoded[type].flatMap { Data(base64Encoded: $0) } }
    }
}
