import ApprovalKit
import Foundation

/// One process of a requester chain, with what grants need beyond the
/// protocol's fields.
public struct ChainEntry: Equatable {
    public var process: ApprovalKit.Process
    public var uid: uid_t
    public var start: Double
    public var tty: String?

    public init(process: ApprovalKit.Process, uid: uid_t, start: Double, tty: String? = nil) {
        self.process = process; self.uid = uid; self.start = start; self.tty = tty
    }

    public var pid: Int32 { Int32(process.pid) }
    /// The name to match against lists: lowercased, a login shell's "-" off.
    var key: String {
        let n = name.lowercased()
        return n.hasPrefix("-") ? String(n.dropFirst()) : n
    }
    /// The executable's name: argv[0] of a login shell is "-zsh".
    public var name: String {
        if let path = process.path { return (path as NSString).lastPathComponent }
        return process.name
    }
}

/// The process a grant belongs to: the nearest ancestor that does the work
/// (an agent, an editor, a terminal), past the shells and wrappers between
/// it and the request. Pid and start time together survive pid reuse.
public struct Anchor: Hashable {
    public var pid: Int32
    public var start: Double
    public var name: String

    public init(pid: Int32, start: Double, name: String) { self.pid = pid; self.start = start; self.name = name }
}

public enum Chain {
    public static let maxLength = 8

    /// Shells and wrappers: looked past, since a grant to a shell would
    /// cover whatever else runs in it.
    public static let wrappers: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "sudo", "su", "env", "login", "sshd",
        "sshd-session", "sshd-auth", "launchd", "script", "nohup", "timeout", "gtimeout", "xargs", "nice", "time",
        "caffeinate", "sandbox-exec", "blitzkvm-remote",
    ]

    /// Terminal emulators and multiplexers: a person's terminal, where every
    /// tab would share the grant. Reaching one ends the search: approve once.
    public static let terminals: Set<String> = [
        "terminal", "iterm2", "ghostty", "wezterm", "wezterm-gui", "alacritty", "kitty", "warp", "hyper", "tmux",
        "screen", "zellij",
    ]
    static let terminalApps = ["/Terminal.app/", "/iTerm.app/", "/Ghostty.app/", "/WezTerm.app/", "/Alacritty.app/",
                               "/kitty.app/", "/Warp.app/", "/Hyper.app/"]

    public static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu"]

    /// Where a wrapper has to live to be looked past: a process names
    /// itself, so a binary renamed "zsh" elsewhere is no wrapper.
    static let wrapperDirectories = ["/bin/", "/usr/bin/", "/usr/sbin/", "/sbin/", "/usr/libexec/", "/opt/homebrew/bin/",
                                     "/opt/homebrew/Cellar/", "/usr/local/bin/", "/usr/local/Cellar/",
                                     "/Library/Application Support/BlitzKVM/Remote/"]

    /// Hosts that run many tenants' code (every extension of an editor, every
    /// plugin of an app): a grant to one would cover them all.
    static let multiTenant = ["Helper (Plugin)", "extensionHost", "Code Helper", "Cursor Helper", "Electron Helper"]

    public static func isWrapper(_ e: ChainEntry) -> Bool {
        guard wrappers.contains(e.key) else { return false }
        guard let path = e.process.path else { return false }
        return wrapperDirectories.contains { path.hasPrefix($0) }
    }

    static func isMultiTenant(_ e: ChainEntry) -> Bool {
        multiTenant.contains { e.name.contains($0) || (e.process.path?.contains($0) == true) }
    }

    public static func isTerminal(_ e: ChainEntry) -> Bool {
        terminals.contains(e.key) || terminalApps.contains { e.process.path?.contains($0) == true }
    }

    /// The chain from `pid` up through its parents, at most maxLength.
    public static func build(from pid: Int32, inspector: ProcessInspector) -> [ChainEntry] {
        var out: [ChainEntry] = []
        var next = pid
        while out.count < maxLength, next > 0, let info = inspector.info(next) {
            let path = inspector.path(next)
            // What a process says about itself is shown, never trusted.
            let name = Display.safe(path.map { ($0 as NSString).lastPathComponent } ?? info.comm, maxBytes: 256)
            let process = ApprovalKit.Process(pid: Int(info.pid), name: name, path: path.map { Display.safe($0, maxBytes: 1024) },
                                              args: inspector.args(next).map(clipArgs),
                                              signer: inspector.identity(next)?.signer ?? "unsigned")
            // A parent started after its child is a reused pid: the chain
            // ends rather than run through someone else's processes.
            if let child = out.last, info.start > child.start { break }
            out.append(ChainEntry(process: process, uid: info.uid, start: info.start, tty: info.tty))
            if info.ppid == next { break }
            next = info.ppid
        }
        return out
    }

    /// The anchor of a chain whose first process is the requesting tool
    /// itself (sudo, blitzkvm-remote): the first process above it that is
    /// neither a wrapper nor a terminal. nil (not grantable) when a terminal,
    /// launchd or the chain's end comes first.
    public static func anchor(_ chain: [ChainEntry]) -> Anchor? {
        for entry in chain.dropFirst() {
            if entry.pid <= 1 || isTerminal(entry) || isMultiTenant(entry) { return nil }
            if isWrapper(entry) { continue }
            return Anchor(pid: entry.pid, start: entry.start, name: entry.name)
        }
        return nil
    }

    /// "sudo ← zsh ← node", for an ask's detail.
    public static func summary(_ chain: [ChainEntry]) -> String {
        chain.map(\.name).joined(separator: " ← ")
    }

    public static func reachesShell(_ chain: [ChainEntry]) -> Bool {
        chain.dropFirst().contains { shells.contains($0.key) }
    }

    /// Arguments as an approver needs them, display-safe and not as long as
    /// a process may have them: at most 24, each at most 200 bytes, 512 in all.
    static func clipArgs(_ args: [String]) -> [String] {
        var out: [String] = []
        var total = 0
        for (i, a) in args.enumerated() {
            let c = Display.safe(a, maxBytes: 200)
            if i == 24 || total + c.utf8.count > 512 { out.append(Display.truncated); break }
            total += c.utf8.count
            out.append(c)
        }
        return out
    }
}

/// What the daemon needs to know about processes (a protocol so tests can
/// describe processes that don't exist).
public protocol ProcessInspector {
    func info(_ pid: Int32) -> ProcInfo?
    func path(_ pid: Int32) -> String?
    func args(_ pid: Int32) -> [String]?
    func cwd(_ pid: Int32) -> String?
    func identity(_ pid: Int32) -> CodeIdentity?
    func all() -> [ProcInfo]
}

public struct SystemProcesses: ProcessInspector {
    public init() {}
    public func info(_ pid: Int32) -> ProcInfo? { Processes.info(pid) }
    public func path(_ pid: Int32) -> String? { Processes.path(pid) }
    public func args(_ pid: Int32) -> [String]? { Processes.args(pid) }
    public func cwd(_ pid: Int32) -> String? { Processes.cwd(pid) }
    public func identity(_ pid: Int32) -> CodeIdentity? { CodeSigning.identity(pid: pid) }
    public func all() -> [ProcInfo] { Processes.all() }
}

extension String {
    /// At most `bytes` UTF-8 bytes, cut at a character boundary and marked
    /// (the protocol caps titles and details at 2048 bytes).
    public func clipped(bytes: Int) -> String {
        guard utf8.count > bytes else { return self }
        var out = ""
        for c in self {
            if out.utf8.count + c.utf8.count + Display.truncated.utf8.count > bytes { break }
            out.append(c)
        }
        return out + Display.truncated
    }
}
