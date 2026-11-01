import ApprovalKit
import Foundation

/// Installing remote approvals on the Mac a JetKVM controls (remote/install)
/// over clipboard sync's login. The files go up as the user, into a new
/// private directory; each root step (sudo -S, the Mac's password on
/// standard input) first copies them into a directory only root can change
/// and checks every one against the hash the app computed, so no process of
/// the user's can swap one in between, then runs install.sh from that copy:
///
/// 1. `install.sh --identity`: installs the binary, which makes the target
///    key, and prints the target's identity.
/// 2. The owner signs a roster that names the target (this Mac's job).
/// 3. `install.sh` with that roster and link.json (the JetKVM's end of the
///    USB link) installs the rest.
public enum RemoteInstall {
    /// As the remote Mac's user: unpacks the tar.gz on standard input into a
    /// new private directory, prints it, then where the SSH session comes
    /// from (the JetKVM's end of the USB link).
    public static let stageCommand =
        #"/bin/sh -c 'd=$(mktemp -d /tmp/blitzkvm-remote.XXXXXX) && tar -xzf - -C "$d" && printf "%s\n%s\n" "$d" "$SSH_CONNECTION"'"#

    public struct Staged: Equatable {
        public var directory: String
        /// The JetKVM's link-local address (link.json).
        public var linkAddress: String

        public init(directory: String, linkAddress: String) {
            self.directory = directory; self.linkAddress = linkAddress
        }
    }

    /// Reads stageCommand's output; nil unless it names a staging directory
    /// and a link-local address.
    public static func staged(output: String) -> Staged? {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2, isStagingDirectory(lines[0]),
              let address = linkAddress(sshConnection: lines[1]) else { return nil }
        return Staged(directory: lines[0], linkAddress: address)
    }

    /// The client address of `$SSH_CONNECTION` ("fe80::1%en7 51234 fe80::2%en7 22")
    /// without its zone, when it is link-local.
    public static func linkAddress(sshConnection: String) -> String? {
        guard let client = sshConnection.split(separator: " ").first else { return nil }
        let address = client.split(separator: "%").first.map(String.init)?.lowercased() ?? ""
        return address.range(of: #"^fe80::[0-9a-f:]+$"#, options: .regularExpression) != nil ? address : nil
    }

    static func isStagingDirectory(_ path: String) -> Bool {
        path.range(of: #"^(/private)?/tmp/blitzkvm-remote\.[A-Za-z0-9]{6,}$"#, options: .regularExpression) != nil
    }

    static func isFileName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    /// A root step: copies `files` (name → SHA-256 hex) from the staging
    /// directory into a new root-only one, checks them, writes `extra` (name →
    /// content) there and runs `run` in it. The copy goes at the end.
    static func rootScript(staging: String, files: [String: String], extra: [String: Data], run: String) -> String? {
        guard isStagingDirectory(staging), files.keys.allSatisfy(isFileName), extra.keys.allSatisfy(isFileName),
              files.values.allSatisfy({ $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }) else { return nil }
        let names = files.keys.sorted()
        var lines = [
            "set -eu",
            "umask 077",
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            "r=$(mktemp -d /private/var/tmp/blitzkvm-install.XXXXXX)",
            #"trap 'rm -rf "$r"' EXIT"#,
            "for f in \(names.joined(separator: " ")); do cp \(quote(staging))/\"$f\" \"$r/$f\"; done",
            #"cd "$r""#,
            "printf '%s\\n' \(names.map { quote("\(files[$0]!)  \($0)") }.joined(separator: " ")) | shasum -a 256 -c -s - "
                + "|| { echo 'install: the uploaded files changed on the remote Mac' >&2; exit 1; }",
        ]
        for name in extra.keys.sorted() {
            lines.append("printf '%s' \(quote(extra[name]!.base64EncodedString())) | base64 -D > \(name)")
        }
        lines.append(run)
        return lines.joined(separator: "\n")
    }

    /// Step 1: installs the binary and prints the target identity.
    public static func identityCommand(staging: String, files: [String: String]) -> String? {
        rootScript(staging: staging, files: files, extra: [:], run: #"/bin/sh install.sh --identity "$r""#).map(sudo)
    }

    /// Step 3: installs the rest with the roster that names the target;
    /// `sudoApprovals` false leaves the PAM module out (--no-sudo).
    public static func installCommand(staging: String, files: [String: String], roster: Envelope, linkAddress: String,
                                      sudoApprovals: Bool) -> String? {
        guard let rosterJSON = try? Wire.encoder.encode(roster),
              let link = try? JSONEncoder().encode(["address": linkAddress]) else { return nil }
        return rootScript(staging: staging, files: files, extra: ["roster.json": rosterJSON, "link.json": link],
                          run: "/bin/sh install.sh \(sudoApprovals ? "" : "--no-sudo ")\"$r\"").map(sudo)
    }

    /// Removes the installation (uninstall.sh, sent inline: nothing to stage).
    public static func uninstallCommand(script: String) -> String { sudo(script) }

    /// Removes the staging directory (as the user).
    public static func cleanupCommand(staging: String) -> String? {
        isStagingDirectory(staging) ? "rm -rf \(quote(staging))" : nil
    }

    /// `sudo -S` with the password on standard input, asking every time
    /// (-k: a cached sudo would hand the password line to the script).
    public static func sudo(_ script: String) -> String {
        "sudo -k -S -p '' /bin/sh -c \(quote(script))"
    }

    /// The standard input of a sudo step.
    public static func sudoInput(password: String) -> Data { Data((password + "\n").utf8) }

    /// The target in `install.sh --identity`'s output (its last line), named
    /// `name`; nil unless its id is its key's.
    public static func identity(output: String, name: String) -> Target? {
        struct Identity: Decodable {
            var id: String
            var key: B64Data
        }
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
              let identity = try? Wire.decoder.decode(Identity.self, from: Data(line.utf8)),
              identity.id == Wire.kid(identity.key.data) else { return nil }
        return Target(name: name, key: identity.key.data)
    }

    /// What install.sh says when PAM can't be installed safely.
    public static func needsNoSudo(stderr: String) -> Bool { stderr.contains("install with --no-sudo") }

    /// A failed step, in a sentence.
    public static func explain(_ result: HostLinkRun.Result, user: String, computer: String) -> String {
        let err = result.stderr
        if err.contains("incorrect password") || err.contains("Sorry, try again") || err.contains("no password was provided") {
            return "The password of \(user) on \(computer) isn't right."
        }
        if err.contains("not in the sudoers") || err.contains("not allowed to run sudo") {
            return "\(user) isn't an administrator on \(computer)."
        }
        if err.contains("Bad CPU type") {
            return "\(computer) has an Intel processor: approvals need Apple silicon there."
        }
        let last = err.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let text = last.hasPrefix("install: ") ? String(last.dropFirst(9)) : last.hasPrefix("uninstall: ") ? String(last.dropFirst(11)) : last
        guard !text.isEmpty else { return "A command on \(computer) failed (exit \(result.exitCode))." }
        return text.prefix(1).uppercased() + text.dropFirst() + (text.hasSuffix(".") ? "" : ".")
    }

    /// POSIX single quotes.
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
