import ApprovalKit
import CryptoKit
import Darwin
import Foundation

/// Where the daemon keeps its files and listens.
public struct Paths: Equatable {
    public var state: URL
    public var socket: String

    public static let systemState = "/Library/Application Support/BlitzKVM/Remote"
    public static let systemSocket = "/var/run/blitzkvm-remote.sock"

    /// The root daemon's.
    public static let system = Paths(state: URL(fileURLWithPath: systemState), socket: systemSocket)

    /// --user-mode: everything in the user's Application Support.
    public static func user(home: String = NSHomeDirectory()) -> Paths {
        let state = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/BlitzKVM/Remote")
        return Paths(state: state, socket: state.appendingPathComponent("blitzkvm-remote.sock").path)
    }

    public init(state: URL, socket: String) { self.state = state; self.socket = socket }

    public var key: URL { state.appendingPathComponent("target.key") }
    public var roster: URL { state.appendingPathComponent("roster.json") }
    public var link: URL { state.appendingPathComponent("link.json") }
    /// Written only by the installer while it changes things: the PAM
    /// client then steps aside at once (sudo asks for the password).
    public var maintenance: URL { state.appendingPathComponent("maintenance") }
}

public enum StoreError: Error, CustomStringConvertible {
    case io(String), notThisTarget, badFile(String)

    public var description: String {
        switch self {
        case .io(let s): return s
        case .notThisTarget: return "the roster doesn't name this target"
        case .badFile(let s): return "unreadable \(s)"
        }
    }
}

/// The target's key and trust store. The key never leaves this file (0600);
/// the roster changes only through Roster.accept.
public struct TargetStore {
    public let paths: Paths

    public init(paths: Paths) { self.paths = paths }

    struct StoredKey: Codable {
        var v = 1
        var sign: B64Data
    }

    /// The target's signing key, made on first use.
    public func loadOrCreateKey() throws -> SoftwareSigner {
        if let data = try? Data(contentsOf: paths.key) {
            guard let stored = try? JSONDecoder().decode(StoredKey.self, from: data),
                  let key = try? P256.Signing.PrivateKey(rawRepresentation: stored.sign.data) else {
                throw StoreError.badFile(paths.key.path)
            }
            var st = stat()
            if stat(paths.key.path, &st) == 0, st.st_mode & 0o077 != 0 {
                chmod(paths.key.path, 0o600)
                Log.info("target.key was readable by others; made it 0600")
            }
            return SoftwareSigner(key)
        }
        try makeStateDir()
        let key = P256.Signing.PrivateKey()
        let data = try JSONEncoder.wire.encode(StoredKey(sign: B64Data(key.rawRepresentation)))
        try Self.writeAtomically(data, to: paths.key, mode: 0o600)
        Log.info("made the target key \(SoftwareSigner(key).id)")
        return SoftwareSigner(key)
    }

    /// What the installer puts in the genesis roster.
    public struct Identity: Codable, Equatable {
        public var id: String
        public var key: B64Data
    }

    public func identity() throws -> Identity {
        let signer = try loadOrCreateKey()
        return Identity(id: signer.id, key: B64Data(signer.publicKey))
    }

    /// The roster held now. A stored roster was checked before it was saved
    /// and only root can write it, so one whose signer has since left the
    /// owners (an owner removing themselves) still loads.
    public func loadRoster() -> (roster: Roster, envelope: Envelope)? {
        guard let data = try? Data(contentsOf: paths.roster),
              let env = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        if let roster = try? Roster.accept(env, current: nil) { return (roster, env) }
        guard env.t == "roster", let roster = try? env.peek(Roster.self), (try? roster.check()) != nil else {
            Log.info("the stored roster doesn't check out; ignoring it")
            return nil
        }
        return (roster, env)
    }

    public func saveRoster(_ env: Envelope) throws {
        try makeStateDir()
        try Self.writeAtomically(try JSONEncoder.wire.encode(env), to: paths.roster, mode: 0o600)
    }

    /// The installer's genesis roster: signed by one of its own owners and
    /// naming this target. It replaces whatever was there (the installer is
    /// root, the authenticated setup path).
    @discardableResult
    public func installGenesis(_ env: Envelope, targetID: String) throws -> Roster {
        let roster = try Roster.accept(env, current: nil)
        guard roster.target(targetID) != nil else { throw StoreError.notThisTarget }
        try saveRoster(env)
        return roster
    }

    public func loadLink() -> HostLink.Config? {
        guard let data = try? Data(contentsOf: paths.link) else { return nil }
        return try? JSONDecoder().decode(HostLink.Config.self, from: data)
    }

    public var inMaintenance: Bool { FileManager.default.fileExists(atPath: paths.maintenance.path) }

    func makeStateDir() throws {
        do {
            try FileManager.default.createDirectory(at: paths.state, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o755])
        } catch {
            throw StoreError.io("can't make \(paths.state.path): \(error.localizedDescription)")
        }
    }

    /// Writes a new file next to `url` with `mode` from the start, then
    /// renames it into place.
    static func writeAtomically(_ data: Data, to url: URL, mode: mode_t) throws {
        let tmp = url.path + ".\(getpid()).tmp"
        unlink(tmp)
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard fd >= 0 else { throw StoreError.io("can't write \(tmp): \(String(cString: strerror(errno)))") }
        let ok = data.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return false }
                off += n
            }
            return fsync(fd) == 0
        }
        close(fd)
        // chmod: the umask may have taken bits off `mode`.
        guard ok, chmod(tmp, mode) == 0, rename(tmp, url.path) == 0 else {
            unlink(tmp)
            throw StoreError.io("can't write \(url.path)")
        }
    }
}
