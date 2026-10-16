import AppKit
import JetKVMCore

/// This Mac's side of clipboard sync: hands changes of the pasteboard to
/// every device window that syncs, and puts what a remote Mac copied on it,
/// marked with the device it came from so it isn't sent back there (it does
/// go on to other syncing devices).
@MainActor
final class ClipboardBridge {
    static let shared = ClipboardBridge()

    private struct Sink {
        var deviceID: String
        var send: ([String: Data]) -> Void
        /// What last went to or came from the device: the same content
        /// coming back (Universal Clipboard between two Macs on one Apple
        /// Account copies it without the marker) isn't sent again.
        var last: [String: Data]?
        /// Until then, changes wait (a paste on the remote is under way);
        /// the clipboard as it is then goes out.
        var holdUntil: Date?
    }

    private var sinks: [ObjectIdentifier: Sink] = [:]
    private var timer: Timer?
    private var changeCount = NSPasteboard.general.changeCount

    /// The pasteboard has no change notification: checking its change count
    /// is cheap, and reading happens only after a change.
    private static let interval: TimeInterval = 0.5

    /// Starts handing this Mac's clipboard changes to `send` (from the next
    /// change on: what is on the clipboard now stays here). Registered only
    /// while a session runs, so the clipboard isn't read for nothing.
    func register(_ owner: AnyObject, deviceID: String, send: @escaping ([String: Data]) -> Void) {
        if sinks.isEmpty { changeCount = NSPasteboard.general.changeCount }
        sinks[ObjectIdentifier(owner)] = Sink(deviceID: deviceID, send: send)
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { ClipboardBridge.shared.poll() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func unregister(_ owner: AnyObject) {
        sinks[ObjectIdentifier(owner)] = nil
        if sinks.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    /// The window sends `sent` itself (pasteFromApp): it counts as sent, and
    /// changes wait `seconds`, so a clipboard another app puts back can't
    /// overtake it on the remote.
    func hold(_ owner: AnyObject, sent: [String: Data], for seconds: TimeInterval) {
        let key = ObjectIdentifier(owner)
        guard sinks[key] != nil else { return }
        sinks[key]?.last = sent
        sinks[key]?.holdUntil = Date().addingTimeInterval(seconds)
    }

    /// Puts a remote Mac's clipboard on this Mac's.
    func write(_ items: [String: Data], from deviceID: String) {
        if let key = sinks.first(where: { $0.value.deviceID == deviceID })?.key {
            guard sinks[key]?.last != items else { return }
            sinks[key]?.last = items
        }
        let item = NSPasteboardItem()
        for (type, data) in items {
            item.setData(data, forType: NSPasteboard.PasteboardType(type))
        }
        item.setString(deviceID, forType: NSPasteboard.PasteboardType(ClipboardPolicy.marker))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    /// Whether macOS lets the app read the clipboard without asking each
    /// time (System Settings › Privacy & Security › Paste from Other Apps,
    /// macOS 15.4 and later).
    enum ReadAccess {
        case allowed, asks, denied
    }

    static var readAccess: ReadAccess {
        guard #available(macOS 15.4, *) else { return .allowed }
        switch NSPasteboard.general.accessBehavior {
        case .ask: return .asks
        case .alwaysDeny: return .denied
        default: return .allowed
        }
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        let now = Date()
        // A hold that ended sends what changed meanwhile.
        let released = sinks.filter { $0.value.holdUntil.map { $0 <= now } ?? false }.map(\.key)
        released.forEach { sinks[$0]?.holdUntil = nil }
        guard pasteboard.changeCount != changeCount || !released.isEmpty else { return }
        changeCount = pasteboard.changeCount
        guard let item = pasteboard.pasteboardItems?.first else { return }
        let origin = item.string(forType: NSPasteboard.PasteboardType(ClipboardPolicy.marker))
        let targets = sinks.filter { $0.value.deviceID != origin && $0.value.holdUntil == nil }.map(\.key)
        guard !targets.isEmpty,
              let items = ClipboardPolicy.select(types: item.types.map(\.rawValue),
                                                 data: { item.data(forType: NSPasteboard.PasteboardType($0)) }) else { return }
        for key in targets where sinks[key]?.last != items {
            sinks[key]?.last = items
            sinks[key]?.send(items)
        }
    }
}
