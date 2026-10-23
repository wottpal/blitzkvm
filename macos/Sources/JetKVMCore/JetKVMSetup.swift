import Foundation
import zlib

/// A firmware build this app ships (`Firmware.json`, with each build as xz
/// next to it in the app's resources).
public struct FirmwareBuild: Decodable, Equatable, Identifiable {
    public enum Kind: String, Decodable {
        /// The BlitzKVM firmware (github.com/wottpal/kvm).
        case blitzkvm
        /// JetKVM's own release.
        case stock
    }

    public var kind: Kind
    /// The release tag, e.g. "release/0.5.9-fork.4".
    public var tag: String
    public var sha256: String
    public var size: Int

    public init(kind: Kind, tag: String, sha256: String, size: Int) {
        self.kind = kind
        self.tag = tag
        self.sha256 = sha256
        self.size = size
    }

    public var id: String { tag }

    /// "0.5.9-fork.4"
    public var version: String { tag.hasPrefix("release/") ? String(tag.dropFirst(8)) : tag }

    /// "BlitzKVM 0.5.9-fork.4", "JetKVM 0.5.9"
    public var title: String { kind == .blitzkvm ? "BlitzKVM \(version)" : "JetKVM \(version)" }

    /// The binary's file name in the app's resources (xz).
    public var fileName: String { tag.replacingOccurrences(of: "/", with: "-") + ".xz" }

    /// Writes the binary in `xz` as gzip, which the JetKVM's gunzip takes:
    /// the app ships xz, a quarter smaller.
    public static func gzip(xz: URL, to destination: URL) throws {
        let binary = try (Data(contentsOf: xz) as NSData).decompressed(using: .lzma) as Data
        guard let file = gzopen(destination.path, "wb9") else { throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: destination]) }
        var written = 0
        binary.withUnsafeBytes { bytes in
            while written < bytes.count {
                let count = gzwrite(file, bytes.baseAddress! + written, UInt32(min(1 << 20, bytes.count - written)))
                if count <= 0 { break }
                written += Int(count)
            }
        }
        guard gzclose(file) == Z_OK, written == binary.count else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: destination])
        }
    }

    /// The builds in a `Firmware.json`.
    public static func manifest(_ data: Data) throws -> [FirmwareBuild] {
        struct Manifest: Decodable { var builds: [FirmwareBuild] }
        return try JSONDecoder().decode(Manifest.self, from: data).builds
    }
}

/// Which firmware a JetKVM runs, as far as the app can tell.
public enum FirmwareState: Equatable {
    /// One of the builds this app ships.
    case bundled(FirmwareBuild)
    /// A BlitzKVM build this app doesn't ship (an older one).
    case otherBlitzKVM
    /// The BlitzKVM firmware; which build takes SSH to tell.
    case unverified
    /// JetKVM's own firmware in a version this app doesn't ship, or one it
    /// couldn't check without SSH.
    case stock(String)

    /// From what the device answers: whether it has the encoder control only
    /// the BlitzKVM firmware has, its app version, and (over SSH) the
    /// SHA-256 of the installed app. Fork builds keep upstream's version, so
    /// only the hash tells builds apart.
    public static func evaluate(hasEncoderControl: Bool, appVersion: String, installedSHA256: String?,
                                bundled: [FirmwareBuild]) -> FirmwareState {
        if let sha = installedSHA256?.lowercased(), let build = bundled.first(where: { $0.sha256.lowercased() == sha }) {
            return .bundled(build)
        }
        guard hasEncoderControl else { return .stock(appVersion) }
        return installedSHA256 == nil ? .unverified : .otherBlitzKVM
    }
}

/// The firmware's getTailscaleStatus result.
public struct TailscaleStatus: Decodable, Equatable {
    public var installed: Bool
    public var running: Bool
    public var backendState: String?
    public var authURL: String?
    public var node: Node?

    public struct Node: Decodable, Equatable {
        public var hostName: String?
        public var dnsName: String?
        public var tailscaleIPs: [String]?

        public init(hostName: String? = nil, dnsName: String? = nil, tailscaleIPs: [String]? = nil) {
            self.hostName = hostName
            self.dnsName = dnsName
            self.tailscaleIPs = tailscaleIPs
        }
    }

    private enum CodingKeys: String, CodingKey {
        case installed, running, backendState, authURL
        case node = "self"
    }

    public init(installed: Bool, running: Bool, backendState: String? = nil, authURL: String? = nil, node: Node? = nil) {
        self.installed = installed
        self.running = running
        self.backendState = backendState
        self.authURL = authURL
        self.node = node
    }
}

/// Tailscale on a JetKVM.
public enum TailscaleState: Equatable {
    case notInstalled
    /// Waiting for someone to log in at the URL.
    case needsLogin(URL?)
    /// Installed but not up (the daemon's backend state).
    case stopped(String)
    /// On the tailnet under this name (MagicDNS, else its address).
    case running(String)

    public init(_ status: TailscaleStatus) {
        if !status.installed {
            self = .notInstalled
        } else if status.running, let name = status.reachableName {
            self = .running(name)
        } else if status.backendState == "NeedsLogin" {
            self = .needsLogin(status.authURL.flatMap { $0.isEmpty ? nil : URL(string: $0) })
        } else {
            self = .stopped(status.backendState ?? "")
        }
    }
}

public extension TailscaleStatus {
    /// The name other devices reach this one under: the MagicDNS name
    /// without its trailing dot, else the first tailnet address.
    var reachableName: String? {
        if let dns = node?.dnsName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")), !dns.isEmpty {
            return dns
        }
        return node?.tailscaleIPs?.first
    }

    /// The tailnet machine name for a device named `name`: lowercase ASCII
    /// letters, digits and dashes (accents dropped), ending in "jetkvm"
    /// unless it names a KVM already ("Mac mini" → "mac-mini-jetkvm").
    static func hostname(forDevice name: String) -> String {
        var slug = ""
        for character in name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased() {
            if character.isASCII && (character.isLetter || character.isNumber) {
                slug.append(character)
            } else if !slug.isEmpty && slug.last != "-" {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty { return "jetkvm" }
        let name = slug.contains("kvm") ? slug : slug + "-jetkvm"
        return String(name.prefix(63))
    }
}

public enum TailscaleCLIStatus {
    /// From this Mac's `tailscale status --json`: the DERP region traffic to
    /// the peer at `address` is relayed through, nil when it goes direct or
    /// no peer has that address.
    public static func relay(statusJSON: Data, to address: String) -> String? {
        struct Status: Decodable { var Peer: [String: Peer]? }
        struct Peer: Decodable {
            var TailscaleIPs: [String]?
            var CurAddr: String?
            var Relay: String?
        }
        guard let status = try? JSONDecoder().decode(Status.self, from: statusJSON),
              let peer = status.Peer?.values.first(where: { $0.TailscaleIPs?.contains(address) == true }) else { return nil }
        guard peer.CurAddr?.isEmpty ?? true, let relay = peer.Relay, !relay.isEmpty else { return nil }
        return relay
    }
}

/// The current stable Tailscale release, from pkgs.tailscale.com/stable/?mode=json.
public struct TailscaleRelease: Decodable, Equatable {
    public var version: String
    /// The 32-bit ARM tarball, e.g. "tailscale_1.104.1_arm.tgz".
    public var tarball: String

    private enum CodingKeys: String, CodingKey {
        case version = "TarballsVersion"
        case tarballs = "Tarballs"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        let tarballs = try c.decode([String: String].self, forKey: .tarballs)
        guard let arm = tarballs["arm"] else {
            throw DecodingError.dataCorruptedError(forKey: .tarballs, in: c, debugDescription: "no arm tarball")
        }
        tarball = arm
    }

    public static let index = URL(string: "https://pkgs.tailscale.com/stable/?mode=json")!

    public var url: URL { URL(string: "https://pkgs.tailscale.com/stable/\(tarball)")! }
    public var checksumURL: URL { URL(string: "https://pkgs.tailscale.com/stable/\(tarball).sha256")! }
}

public enum JetKVMSSH {
    /// ssh(1) arguments for running `command` as root on a JetKVM with this
    /// app's own key and known-hosts file. The host key is filed under the
    /// device's ID, so a new address (DHCP, a VPN name) is the same host.
    public static func arguments(host: String, hostKeyAlias: String, privateKey: String, knownHosts: String,
                                 connectTimeout: Int = 8, command: String) -> [String] {
        [
            "-i", privateKey,
            "-o", "IdentitiesOnly=yes",
            "-o", "IdentityAgent=none",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(knownHosts)",
            "-o", "HostKeyAlias=\(hostKeyAlias)",
            "-o", "ConnectTimeout=\(connectTimeout)",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
            "-o", "LogLevel=ERROR",
            "root@\(host)",
            command,
        ]
    }

    /// The host part of a device address ("https://kvm.example:8443" →
    /// "kvm.example", "192.168.1.5" → itself).
    public static func host(of address: String) -> String {
        let withScheme = address.contains("://") ? address : "http://" + address
        return URLComponents(string: withScheme)?.host ?? address
    }

    /// The hash in sha256sum's output ("<hex>  <file>"), lowercased.
    public static func sha256(fromSumOutput output: String) -> String? {
        guard let first = output.split(whereSeparator: \.isWhitespace).first, first.count == 64,
              first.allSatisfy(\.isHexDigit) else { return nil }
        return first.lowercased()
    }
}

/// The boot guard of a firmware install (`Support/InstallGuard.sh`, a copy of
/// wottpal/kvm's `scripts/fork/install_guard.sh`): armed before the restart
/// that installs a build, it puts `jetkvm_app.backup` back when the new app
/// doesn't answer after a boot, or the JetKVM keeps restarting. An install
/// over Tailscale can't strand the JetKVM that way.
public enum InstallGuard {
    public static let script = "/userdata/init.d/S99install-guard"
    public static let marker = "/userdata/install-guard.armed"
    public static let log = "/userdata/install-guard.log"

    /// Installs the script from standard input (and drops an earlier log).
    /// Stock JetKVMs have no /userdata/init.d until something creates it.
    public static let installCommand = "rm -f \(log) && mkdir -p /userdata/init.d && cat > \(script) && chmod +x \(script)"
    /// Arms it for the next boot.
    public static let armCommand = "echo 0 > \(marker)"
    /// Prints whether it is armed (with its boot count), then its log's last
    /// line.
    public static let statusCommand =
        "if [ -f \(marker) ]; then echo \"armed $(cat \(marker))\"; else echo disarmed; fi; tail -n 1 \(log) 2>/dev/null"
    /// Takes it off the JetKVM, leaving its log.
    public static let disarmCommand = "rm -f \(marker) \(script)"
    /// Takes it off the JetKVM with its log.
    public static let removeCommand = "rm -f \(marker) \(script) \(log)"

    public enum Verdict: Equatable {
        /// Not there, or nothing to act on.
        case none
        /// Armed, and not yet sure of the new build.
        case pending
        /// The new build answered after its restart and again 5 minutes later.
        case healthy
        /// The new build didn't, and the guard put the backup back.
        case rolledBack
        /// The new build didn't, and there was no backup to put back.
        case rollbackFailed
    }

    /// Reads `statusCommand`'s output.
    public static func verdict(statusOutput: String) -> Verdict {
        let lines = statusOutput.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let state = lines.first ?? "", last = lines.count > 1 ? lines[1] : ""
        switch state {
        case "disarmed":
            if last.contains("rollback failed") { return .rollbackFailed }
            return last.contains("rollback:") ? .rolledBack : .none
        case "armed 0":
            return last.hasSuffix("app healthy") ? .healthy : .pending
        case let armed where armed.hasPrefix("armed "):
            return .pending
        default:
            return .none
        }
    }
}

/// How far JetKVM Setup is, as of its last check: kept with the device, so
/// the Devices window shows it without connecting. nil: not checked.
public struct SetupSummary: Codable, Equatable {
    /// The BlitzKVM build this app ships runs.
    public var firmwareUpToDate: Bool?
    /// The JetKVM is on a tailnet.
    public var tailscaleConnected: Bool?
    /// The JetKVM asks for a password.
    public var passwordSet: Bool?

    public init(firmwareUpToDate: Bool? = nil, tailscaleConnected: Bool? = nil, passwordSet: Bool? = nil) {
        self.firmwareUpToDate = firmwareUpToDate
        self.tailscaleConnected = tailscaleConnected
        self.passwordSet = passwordSet
    }

    public static let steps = 3

    public var done: Int { [firmwareUpToDate, tailscaleConnected, passwordSet].filter { $0 == true }.count }

    public var isComplete: Bool { done == Self.steps }

    /// This check, keeping what an earlier one knew where this one couldn't tell.
    public func merged(over earlier: SetupSummary?) -> SetupSummary {
        SetupSummary(firmwareUpToDate: firmwareUpToDate ?? earlier?.firmwareUpToDate,
                     tailscaleConnected: tailscaleConnected ?? earlier?.tailscaleConnected,
                     passwordSet: passwordSet ?? earlier?.passwordSet)
    }
}

public extension Device {
    /// Appends an address the device answers at (e.g. its tailnet name);
    /// false when it is listed already.
    mutating func addAddress(_ address: String) -> Bool {
        guard !addresses.contains(where: { $0.caseInsensitiveCompare(address) == .orderedSame }) else { return false }
        addresses.append(address)
        return true
    }
}
