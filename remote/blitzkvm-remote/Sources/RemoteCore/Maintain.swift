import ApprovalKit
import CryptoKit
import Darwin
import Foundation
import Security

/// Updating and removing the remote side on an owner's signed order
/// (`blitzkvm-remote maintain`, PROTOCOL.md "Maintenance"), so no password
/// travels through the user's login. The BlitzKVM app stages the files as
/// the user; the daemon copies each into a directory only root can change,
/// checks it against the hash the owner signed (and the binaries' code
/// signatures against its own Team ID), and runs install.sh or uninstall.sh
/// from there as a launchd job of its own, which outlives the daemon's
/// restart.
public enum Maintenance {
    public static let jobLabel = "xyz.scio.blitzkvm.remote.maintain"
    /// The largest staged file (the binary is a few MB).
    static let maxFileSize = 64 << 20

    /// What the binaries must satisfy: signed like the daemon itself.
    public static func requirements(team: String) -> [String: String] {
        let anchor = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        return ["blitzkvm-remote": "\(anchor) and identifier \"xyz.scio.blitzkvm.remote\"",
                "pam_blitzkvm.so": "\(anchor) and identifier \"xyz.scio.blitzkvm.remote.pam\""]
    }

    public enum Failure: Error, CustomStringConvertible {
        case refused(String)
        public var description: String {
            switch self {
            case .refused(let why): return why
            }
        }
    }

    /// Copies the order's files from its staging directory into `dir`
    /// (root's), checking each: a plain file (no link, no FIFO) whose
    /// SHA-256 is the signed one.
    static func copy(_ order: MaintainOrder, into dir: URL) throws {
        for (name, want) in order.files.sorted(by: { $0.key < $1.key }) {
            let fd = open(order.stage + "/" + name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw Failure.refused("\(name) isn't in the staging directory") }
            defer { Darwin.close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= maxFileSize else {
                throw Failure.refused("\(name) isn't a plain file")
            }
            var data = Data(capacity: Int(st.st_size))
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n < 0 { throw Failure.refused("can't read \(name)") }
                if n == 0 { break }
                data.append(buffer, count: n)
                if data.count > maxFileSize { throw Failure.refused("\(name) is too large") }
            }
            let got = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard got == want else { throw Failure.refused("\(name) isn't the file the owner signed") }
            try TargetStore.writeAtomically(data, to: dir.appendingPathComponent(name), mode: 0o600)
        }
    }

    /// Whether a file's code signature satisfies a requirement (strictly,
    /// all architectures).
    public static func satisfies(_ file: URL, requirement: String) -> Bool {
        var code: SecStaticCode?
        var req: SecRequirement?
        guard SecStaticCodeCreateWithPath(file as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess
    }

    /// The job's script: install.sh --update (or uninstall.sh), its last
    /// line into the status file the app reads, its output into the log.
    static func script(_ order: MaintainOrder, dir: URL, state: URL) -> String {
        let run = order.action == MaintainOrder.update ? "/bin/sh install.sh --update \"$d\"" : "/bin/sh uninstall.sh"
        return """
        #!/bin/sh
        # An owner's order (blitzkvm-remote maintain), in a launchd job of its
        # own: the daemon's restart doesn't stop it.
        PATH=/usr/bin:/bin:/usr/sbin:/sbin
        d=\(quote(dir.path))
        s=\(quote(state.path))
        cd "$d" || exit 1
        if \(run) >"$d/out" 2>&1; then r=done; else r="failed: $(tail -n 1 "$d/out")"; fi
        if [ -d "$s" ]; then
        \tprintf '%s\\n' "$r" >"$s/maintain.status.new" && chmod 0644 "$s/maintain.status.new" && mv -f "$s/maintain.status.new" "$s/maintain.status"
        fi
        cat "$d/out" >>/Library/Logs/BlitzKVM/remote.log 2>/dev/null
        rm -rf "$d"
        exec launchctl bootout system/\(jobLabel)

        """
    }

    /// Loads the job (a plist in `dir` that runs run.sh there).
    static func launch(_ dir: URL) throws {
        let plist: [String: Any] = ["Label": jobLabel, "ProgramArguments": ["/bin/sh", dir.appendingPathComponent("run.sh").path],
                                    "RunAtLoad": true]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let url = dir.appendingPathComponent("maintain.plist")
        try TargetStore.writeAtomically(data, to: url, mode: 0o644)
        _ = launchctl(["bootout", "system/\(jobLabel)"]) // one left from an order that didn't finish
        guard launchctl(["bootstrap", "system", url.path]) == 0 else { throw Failure.refused("launchd didn't take the job") }
    }

    static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
}

extension Daemon {
    /// An owner's maintenance order from a local client (any user: the
    /// signature is what counts). The reply comes once the job runs.
    func maintain(_ c: Client, _ m: LocalMessage) {
        guard let env = m.order, let roster = roster?.roster else {
            return c.reply(text: "BlitzKVM: no order, or no roster yet", outcome: .refused)
        }
        let t = now()
        maintainNonces = maintainNonces.filter { $0.value > t }
        let order: MaintainOrder
        do {
            order = try MaintainOrder.verify(env, roster: roster, target: targetID, now: t)
        } catch {
            Log.info("maintenance order refused: \(error)")
            return c.reply(text: "BlitzKVM: the order was refused: \(error)", outcome: .refused)
        }
        guard maintainNonces[order.nonce.data] == nil else {
            return c.reply(text: "BlitzKVM: that order was used already", outcome: .refused)
        }
        maintainNonces[order.nonce.data] = t + 2 * Limits.clockSkew
        guard let team = config.maintainTeam else {
            Log.info("maintenance order refused: this daemon has no Developer ID to check the new files against")
            return c.reply(text: "BlitzKVM: this daemon can't check signatures; reinstall with the password", outcome: .unavailable)
        }
        var dir: URL?
        do {
            let made = try config.maintainRoot.makeDirectory()
            dir = made
            try Maintenance.copy(order, into: made)
            for (name, requirement) in Maintenance.requirements(team: team) where order.files[name] != nil {
                guard config.codeCheck(made.appendingPathComponent(name), requirement) else {
                    throw Maintenance.Failure.refused("\(name) isn't signed like this daemon")
                }
            }
            try TargetStore.writeAtomically(Data(Maintenance.script(order, dir: made, state: config.paths.state).utf8),
                                            to: made.appendingPathComponent("run.sh"), mode: 0o700)
            try TargetStore.writeAtomically(Data("running\n".utf8), to: config.paths.state.appendingPathComponent("maintain.status"),
                                            mode: 0o644)
            try config.launchMaintenance(made)
        } catch {
            if let dir { try? FileManager.default.removeItem(at: dir) }
            Log.info("maintenance order refused: \(error)")
            return c.reply(text: "BlitzKVM: \(error)", outcome: .refused)
        }
        let owner = roster.approvers.first { Wire.kid($0.presence.data) == env.k }?.name ?? "an owner"
        Log.info("maintenance: \(order.action) ordered by \(owner)")
        c.reply(text: order.action == MaintainOrder.update ? "BlitzKVM: updating; the daemon restarts" : "BlitzKVM: removing",
                outcome: .approved)
    }
}

/// Where the daemon makes the job's directory: root's alone.
public struct MaintainRoot {
    public var url: URL
    public init(_ url: URL) { self.url = url }
    public static let system = MaintainRoot(URL(fileURLWithPath: "/private/var/tmp"))

    func makeDirectory() throws -> URL {
        var template = Array(url.appendingPathComponent("blitzkvm-maintain.XXXXXX").path.utf8CString)
        guard let made = mkdtemp(&template) else { throw Maintenance.Failure.refused("can't make a directory for the job") }
        return URL(fileURLWithPath: String(cString: made), isDirectory: true)
    }
}
