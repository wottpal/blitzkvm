import AppKit
import ApprovalKit
import CoreGraphics
import Foundation
import Security
import RemoteCore

/// The per-user agent (gui LaunchAgent): reports what the user's session
/// shows to the daemon and brings an app back to the front when asked.
/// It uses only what needs no permission: NSWorkspace, window owners and
/// bounds (never their names or pixels), display bounds, the input source.
/// It never posts events, reads the screen, or scripts other apps: the
/// JetKVM's keyboard and pointer are the only input. With the user's switch
/// on, it also keeps 1Password running.
final class Agent {
    let socket: String
    let checkServerIsRoot: Bool
    private var conn: LineConn?
    private var last: AgentFacts?
    private var keyMap: (id: String, keyboardType: UInt32, map: [String: [Stroke]])?
    private var nextConnect = Date.distantPast
    private var nextKeepCheck = Date.distantPast
    private var lastOnePasswordStart = Date.distantPast

    init(socket: String, checkServerIsRoot: Bool) {
        self.socket = socket
        self.checkServerIsRoot = checkServerIsRoot
    }

    func run() -> Never {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        tick()
        RunLoop.main.run()
        exit(0)
    }

    private func tick() {
        keepOnePasswordRunning()
        if conn == nil { connect() }
        guard let conn else { return }
        let facts = collect()
        if facts != last, conn.send(LocalMessage(op: "facts", facts: facts)) { last = facts }
    }

    private func connect() {
        guard Date() >= nextConnect else { return }
        nextConnect = Date().addingTimeInterval(2)
        guard let fd = try? Sockets.connectUnix(path: socket) else { return }
        // Only the root daemon gets to tell this agent what to bring to the front.
        if checkServerIsRoot, PeerCredentials.of(fd)?.uid != 0 {
            Log.info("agent: the socket isn't root's")
            close(fd)
            return
        }
        let c = LineConn(fd: fd, queue: .main)
        conn = c
        last = nil
        c.start(onLine: { [weak self] in self?.handle($0) }, onClose: { [weak self] in
            self?.conn = nil
            Log.info("agent: daemon connection closed")
        })
        c.send(LocalMessage(op: "agent"))
        Log.info("agent: connected to \(socket)")
    }

    private func handle(_ data: Data) {
        guard let m = try? JSONDecoder().decode(LocalMessage.self, from: data) else { return }
        switch m.op {
        case "refresh":
            let facts = collect()
            if conn?.send(LocalMessage(op: "facts", facts: facts, seq: m.seq)) == true { last = facts }
        case "activate":
            if let app = m.app { activate(app) }
        default:
            break
        }
    }

    // MARK: Facts

    func collect() -> AgentFacts {
        var facts = AgentFacts()
        if let front = NSWorkspace.shared.frontmostApplication {
            facts.frontmost = AppRef(pid: front.processIdentifier, bundle: front.bundleIdentifier, name: front.localizedName)
        }
        facts.windows = promptWindows()
        let main = CGDisplayBounds(CGMainDisplayID())
        facts.display = .init(w: Double(main.width), h: Double(main.height))
        if let current = KeyLayout.current() {
            if keyMap?.id != current.id || keyMap?.keyboardType != current.keyboardType {
                keyMap = (current.id, current.keyboardType, KeyLayout.map(layout: current.layout, keyboardType: current.keyboardType))
            }
            facts.inputSource = current.id
            facts.keyMap = keyMap?.map
        }
        facts.capsLock = CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift)
        return facts
    }

    /// On-screen windows at the prompt layer: owner and bounds only (window
    /// names would need Screen Recording).
    private func promptWindows() -> [WindowFact] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return list.compactMap { w in
            let owner = w[kCGWindowOwnerName as String] as? String
            guard let layer = w[kCGWindowLayer as String] as? Int,
                  layer == OnePassword.layer || owner.map(PasswordDialog.owners.contains) == true,
                  let number = w[kCGWindowNumber as String] as? Int,
                  let pid = w[kCGWindowOwnerPID as String] as? Int32,
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return nil }
            return WindowFact(number: number, pid: pid, owner: w[kCGWindowOwnerName as String] as? String,
                              bundle: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, layer: layer,
                              x: Double(b.minX), y: Double(b.minY), w: Double(b.width), h: Double(b.height))
        }
    }

    // MARK: 1Password

    /// `op` run without 1Password fails without a prompt, and a 1Password
    /// that `op` started quits once its prompt is gone: with the switch on,
    /// 1Password is started again (in the background) a few seconds after it
    /// quit, at most every 30 s. It starts locked; its prompt then asks for
    /// the password, which an approval types.
    private func keepOnePasswordRunning() {
        guard Date() >= nextKeepCheck else { return }
        nextKeepCheck = Date().addingTimeInterval(5)
        let domain = OnePassword.keepRunningDomain as CFString
        CFPreferencesAppSynchronize(domain) // `defaults write` from the app's SSH session
        guard CFPreferencesGetAppBooleanValue(OnePassword.keepRunningKey as CFString, domain, nil),
              NSRunningApplication.runningApplications(withBundleIdentifier: OnePassword.bundle).isEmpty,
              Date().timeIntervalSince(lastOnePasswordStart) >= 30,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: OnePassword.bundle),
              Agent.isOnePassword(url) else { return }
        lastOnePasswordStart = Date()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            Log.info(error.map { "agent: starting 1Password failed: \($0.localizedDescription)" } ?? "agent: started 1Password")
        }
    }

    /// 1Password's app by its signature: another app can claim its bundle id.
    static func isOnePassword(_ url: URL) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let text = "anchor apple generic and identifier \"\(OnePassword.bundle)\" and certificate leaf[subject.OU] = \"\(OnePassword.team)\""
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    // MARK: Activation

    /// Brings an app to the front the way the Dock does (an open with
    /// `activates`), which macOS honors where a plain activate may be refused.
    private func activate(_ app: AppRef) {
        let running = NSRunningApplication(processIdentifier: app.pid)
        let url = running?.bundleIdentifier == app.bundle ? running?.bundleURL
            : app.bundle.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        guard let url else { return Log.info("agent: can't find \(app.bundle ?? "pid \(app.pid)") to bring back") }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error { Log.info("agent: bringing back \(url.lastPathComponent) failed: \(error.localizedDescription)") }
        }
    }
}
