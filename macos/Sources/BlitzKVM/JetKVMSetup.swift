import AppKit
import CryptoKit
import JetKVMCore

/// The JetKVM Setup sheet's state and actions: which firmware the JetKVM
/// runs, whether it is on Tailscale and has a password, and installing each.
/// Owned by the device window, so an install goes on with the sheet closed.
@MainActor
final class JetKVMSetupModel: ObservableObject {
    /// One row of the sheet: the last known state, the step an action is on,
    /// and why the last check or action failed.
    struct Row<Value: Equatable>: Equatable {
        var value: Value?
        var progress: String?
        var error: String?

        var isWorking: Bool { progress != nil }
    }

    @Published private(set) var firmware = Row<FirmwareState>()
    @Published private(set) var tailscale = Row<TailscaleState>()
    /// Whether the device asks for a password.
    @Published private(set) var password = Row<Bool>()
    /// The firmware builds this app ships, the recommended BlitzKVM
    /// build first.
    let builds: [(build: FirmwareBuild, binary: URL)] = JetKVMSetupModel.bundledFirmware()

    var recommended: FirmwareBuild? { builds.first { $0.build.kind == .blitzkvm }?.build }

    private weak var controller: DeviceWindowController?
    private var tailscaleWatch: Task<Void, Never>?
    /// The login page was opened for this URL already.
    private var openedLogin: URL?

    init(controller: DeviceWindowController) {
        self.controller = controller
    }

    var isWorking: Bool { firmware.isWorking || tailscale.isWorking || password.isWorking }

    func cancel() {
        tailscaleWatch?.cancel()
    }

    // MARK: Checking

    /// Reads all three states (rows with an action under way keep theirs).
    func refresh() {
        Task {
            async let canSSH = shellWorks()
            if !tailscale.isWorking { await checkTailscale() }
            if !password.isWorking { await checkPassword() }
            let ssh = await canSSH
            if !firmware.isWorking { await checkFirmware(ssh: ssh) }
            record()
        }
    }

    /// The states as a summary for the device library (unknowns left out).
    var summary: SetupSummary {
        var firmwareUpToDate: Bool?
        switch firmware.value {
        case .bundled(let build)?: firmwareUpToDate = build == recommended
        case .otherBlitzKVM?, .stock?: firmwareUpToDate = false
        case .unverified?, nil: firmwareUpToDate = nil
        }
        var tailscaleConnected: Bool?
        if let state = tailscale.value {
            if case .running = state { tailscaleConnected = true } else { tailscaleConnected = false }
        }
        return SetupSummary(firmwareUpToDate: firmwareUpToDate, tailscaleConnected: tailscaleConnected, passwordSet: password.value)
    }

    private func record() {
        controller?.recordSetup(summary)
    }

    private func checkFirmware(ssh: Bool) async {
        guard let engine = controller?.engine else { return }
        do {
            let version = try await engine.call("getLocalVersion", as: LocalVersion.self)
            // Only the BlitzKVM firmware answers this.
            let hasEncoderControl = (try? await engine.call("getVideoEncoderParams", as: JSONValue.self)) != nil
            var installed: String?
            if ssh, let shell {
                installed = JetKVMSSH.sha256(fromSumOutput: try await shell.run("sha256sum /userdata/jetkvm/bin/jetkvm_app"))
            }
            firmware.value = FirmwareState.evaluate(hasEncoderControl: hasEncoderControl, appVersion: version.appVersion,
                                                    installedSHA256: installed, bundled: builds.map(\.build))
            firmware.error = nil
        } catch {
            firmware.error = Self.describe(error)
        }
    }

    private func checkTailscale() async {
        guard let engine = controller?.engine else { return }
        do {
            let state = TailscaleState(try await engine.call("getTailscaleStatus", as: TailscaleStatus.self))
            tailscale.value = state
            tailscale.error = nil
            if case .running(let name) = state {
                controller?.addAddress(name)
                record()
            }
        } catch {
            tailscale.error = Self.describe(error)
        }
    }

    private func checkPassword() async {
        guard let controller else { return }
        let fetch = AddressProbe.httpFetch(certSHA256: controller.device.certificateSHA256)
        if let identity = await fetch(controller.address) {
            password.value = identity.authMode != "noPassword"
            password.error = nil
        } else {
            password.error = "The JetKVM didn't answer."
        }
    }

    // MARK: Firmware

    /// Turns on SSH to tell which BlitzKVM build runs.
    func verifyFirmware() {
        guard !firmware.isWorking else { return }
        Task {
            do {
                firmware.error = nil
                firmware.progress = "Turning on SSH…"
                _ = try await ensureShell()
                firmware.progress = nil
                await checkFirmware(ssh: true)
            } catch {
                firmware.progress = nil
                firmware.error = Self.describe(error)
            }
        }
    }

    /// Uploads a bundled build next to the installed one, checks it, and
    /// restarts the JetKVM, which moves it into place as it does an update.
    /// The installed build is kept as `jetkvm_app.backup`.
    func installFirmware(_ build: FirmwareBuild) {
        guard let bundled = builds.first(where: { $0.build == build }), !firmware.isWorking else { return }
        Task {
            do {
                firmware.error = nil
                firmware.progress = "Turning on SSH…"
                let shell = try await ensureShell()
                firmware.progress = "Uploading the firmware…"
                let part = "/userdata/jetkvm/jetkvm_app.update.part"
                let sum = try await shell.run("gunzip -c > \(part) && sha256sum \(part)", input: bundled.binary, timeout: 600)
                guard JetKVMSSH.sha256(fromSumOutput: sum) == bundled.build.sha256.lowercased() else {
                    _ = try? await shell.run("rm -f \(part)")
                    throw SetupError("The upload arrived damaged. Nothing was installed.")
                }
                firmware.progress = "Restarting the JetKVM…"
                _ = try await shell.run("cp -f /userdata/jetkvm/bin/jetkvm_app /userdata/jetkvm/jetkvm_app.backup && "
                    + "mv -f \(part) /userdata/jetkvm/jetkvm_app.update && sync && "
                    + "(sleep 1; reboot) > /dev/null 2>&1 &")
                try await waitForRestart()
                firmware.progress = nil
                refresh()
            } catch {
                firmware.progress = nil
                firmware.error = Self.describe(error)
            }
        }
    }

    /// Restarts the JetKVM and waits until the session is back.
    func restartJetKVM() {
        guard let controller, !firmware.isWorking else { return }
        Task {
            do {
                firmware.error = nil
                firmware.progress = "Restarting the JetKVM…"
                try await controller.restartJetKVM()
                try await waitForRestart()
                firmware.progress = nil
                refresh()
            } catch {
                firmware.progress = nil
                firmware.error = Self.describe(error)
            }
        }
    }

    /// The session drops when the JetKVM goes down and comes back once it is
    /// up again (the window reconnects by itself).
    private func waitForRestart() async throws {
        let down = Date().addingTimeInterval(60)
        while controller?.snapshot.Phase == "connected" && Date() < down {
            try await Task.sleep(for: .seconds(1))
        }
        let up = Date().addingTimeInterval(240)
        while controller?.snapshot.Phase != "connected" {
            guard Date() < up else { throw SetupError("The JetKVM hasn't come back after restarting.") }
            try await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: Tailscale

    /// Downloads the current Tailscale for 32-bit ARM, installs it the way
    /// `tailscale configure jetkvm` expects (it then starts at boot), starts
    /// it and asks it to join a tailnet; the login page opens in the browser.
    /// The JetKVM keeps running: no restart.
    func installTailscale() {
        guard let controller, !tailscale.isWorking else { return }
        let hostname = TailscaleStatus.hostname(forDevice: controller.device.name)
        Task {
            do {
                tailscale.error = nil
                tailscale.progress = "Turning on SSH…"
                let shell = try await ensureShell()
                tailscale.progress = "Downloading Tailscale…"
                let (release, tarball) = try await Self.downloadTailscale()
                defer { try? FileManager.default.removeItem(at: tarball) }
                tailscale.progress = "Installing Tailscale \(release.version)…"
                _ = try await shell.run("cat > /userdata/tailscale.tgz", input: tarball, timeout: 600)
                _ = try await shell.run(Self.tailscaleInstallScript, timeout: 120)
                tailscale.progress = "Starting Tailscale…"
                try await startLogin(shell, hostname: hostname)
                tailscale.progress = nil
                watchTailscale()
            } catch {
                tailscale.progress = nil
                tailscale.error = Self.describe(error)
            }
        }
    }

    /// Replaces the binaries, keeping the node's state (`var/`), registers
    /// the boot script and starts the daemon, which loads the kernel's TUN
    /// module itself; waits until it answers.
    private static let tailscaleInstallScript = """
        set -e
        cd /userdata
        rm -rf tailscale.new && mkdir tailscale.new
        tar -xzf tailscale.tgz -C tailscale.new && rm -f tailscale.tgz
        mkdir -p tailscale
        [ -x /userdata/init.d/S22tailscale ] && /userdata/init.d/S22tailscale stop > /dev/null 2>&1 || true
        cp -f tailscale.new/*/tailscale tailscale.new/*/tailscaled tailscale/
        rm -rf tailscale.new
        cd tailscale && ./tailscale configure jetkvm > /dev/null
        (trap '' HUP; /userdata/init.d/S22tailscale start)
        i=0; until tailscale status --json > /dev/null 2>&1 || [ $i -ge 30 ]; do sleep 1; i=$((i+1)); done
        tailscale version | head -n 1
        """

    private static func downloadTailscale() async throws -> (TailscaleRelease, URL) {
        let (index, _) = try await URLSession.shared.data(from: TailscaleRelease.index)
        let release = try JSONDecoder().decode(TailscaleRelease.self, from: index)
        let (checksum, _) = try await URLSession.shared.data(from: release.checksumURL)
        let (download, _) = try await URLSession.shared.download(from: release.url)
        let tarball = FileManager.default.temporaryDirectory.appendingPathComponent(release.tarball)
        try? FileManager.default.removeItem(at: tarball)
        try FileManager.default.moveItem(at: download, to: tarball)
        guard let expected = JetKVMSSH.sha256(fromSumOutput: String(decoding: checksum, as: UTF8.self)),
              try sha256(of: tarball) == expected else {
            try? FileManager.default.removeItem(at: tarball)
            throw SetupError("The Tailscale download didn't match its checksum.")
        }
        return (release, tarball)
    }

    /// Follows Tailscale until the JetKVM is on the tailnet: opens the login
    /// page once, then adds the JetKVM's tailnet name to its addresses.
    func watchTailscale() {
        tailscaleWatch?.cancel()
        tailscaleWatch = Task {
            let end = Date().addingTimeInterval(20 * 60)
            while !Task.isCancelled && Date() < end {
                await checkTailscale()
                switch tailscale.value {
                case .running?:
                    return
                case .needsLogin(let url?)? where url != openedLogin:
                    openedLogin = url
                    NSWorkspace.shared.open(url)
                default:
                    break
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Asks Tailscale on the JetKVM to join a tailnet under `hostname`; it
    /// then waits for someone to log in at the URL it reports. A login still
    /// waiting is replaced (one waiting `tailscale up` at a time), and the
    /// re-authentication gives the new name a login page of its own.
    private func startLogin(_ shell: JetKVMShell, hostname: String) async throws {
        _ = try await shell.run("killall tailscale 2> /dev/null; "
            + "(trap '' HUP; tailscale up --hostname=\(hostname) --force-reauth > /tmp/tailscale-up.log 2>&1 &)")
    }

    /// The name Tailscale on the JetKVM logs in under.
    private func loginHostname(_ shell: JetKVMShell) async throws -> String? {
        struct Prefs: Decodable { var Hostname: String? }
        return try? JSONDecoder().decode(Prefs.self, from: Data(try await shell.run("tailscale debug prefs").utf8)).Hostname
    }

    /// Opens the Tailscale login page for the device's current name: the
    /// waiting one when it has that name, else a new one (after a rename, or
    /// a restart that dropped the page).
    func logIn() {
        guard let controller, !tailscale.isWorking else { return }
        let hostname = TailscaleStatus.hostname(forDevice: controller.device.name)
        var waiting: URL?
        if case .needsLogin(let url?)? = tailscale.value { waiting = url }
        Task {
            do {
                tailscale.error = nil
                tailscale.progress = "Starting the login…"
                let shell = try await ensureShell()
                if let waiting, try await loginHostname(shell) == hostname {
                    NSWorkspace.shared.open(waiting)
                    openedLogin = waiting
                } else {
                    try await startLogin(shell, hostname: hostname)
                    openedLogin = waiting // the old page: wait for the new one
                }
                tailscale.progress = nil
                watchTailscale()
            } catch {
                tailscale.progress = nil
                tailscale.error = Self.describe(error)
            }
        }
    }

    // MARK: Password

    /// Sets the JetKVM's first password and keeps it in the Keychain (not in
    /// self-tests); the session stays connected and uses it from now on.
    func createPassword(_ newPassword: String) {
        guard let controller, !password.isWorking else { return }
        Task {
            do {
                password.error = nil
                password.progress = "Setting the password…"
                try await controller.engine.run(EngineCommand(cmd: "createPassword", password: newPassword))
                controller.passwordChanged(to: newPassword)
                password.progress = nil
                password.value = true
                record()
            } catch {
                password.progress = nil
                password.error = Self.describe(error)
            }
        }
    }

    /// The password the session uses (typed, or from the keychain).
    var knownPassword: String? { controller?.knownPassword }

    /// Changes the JetKVM's password (the device wants the current one) and
    /// keeps the new one in the Keychain.
    func changePassword(current: String, to newPassword: String) {
        guard let controller, !password.isWorking else { return }
        Task {
            do {
                password.error = nil
                password.progress = "Changing the password…"
                try await controller.engine.run(EngineCommand(cmd: "changePassword", password: newPassword, oldPassword: current))
                controller.passwordChanged(to: newPassword)
                password.progress = nil
            } catch {
                password.progress = nil
                password.error = Self.describe(error)
            }
        }
    }

    /// Turns the JetKVM's password off (the device wants the current one)
    /// and removes it from the Keychain.
    func removePassword(current: String) {
        guard let controller, !password.isWorking else { return }
        Task {
            do {
                password.error = nil
                password.progress = "Turning off the password…"
                try await controller.engine.run(EngineCommand(cmd: "removePassword", password: current))
                controller.passwordChanged(to: nil)
                password.progress = nil
                password.value = false
                record()
            } catch {
                password.progress = nil
                password.error = Self.describe(error)
            }
        }
    }

    // MARK: SSH

    private var shell: JetKVMShell? {
        guard let controller else { return nil }
        return JetKVMShell(host: JetKVMSSH.host(of: controller.address),
                           hostKeyAlias: controller.device.deviceID ?? JetKVMSSH.host(of: controller.address))
    }

    private func shellWorks() async -> Bool {
        guard let shell, FileManager.default.fileExists(atPath: JetKVMShell.privateKey.path) else { return false }
        return (try? await shell.run("true", timeout: 10)) != nil
    }

    /// SSH as root with this app's key: turns on Developer Mode and adds the
    /// key (keeping any others) over the session when needed.
    private func ensureShell() async throws -> JetKVMShell {
        guard let shell, let engine = controller?.engine else { throw SetupError("Not connected.") }
        let key = try JetKVMShell.publicKey()
        if await shellWorks() { return shell }
        if try await engine.call("getDevModeState", as: DevModeState.self).enabled == false {
            try await engine.call("setDevModeState", params: .object(["enabled": .bool(true)]))
        }
        let keys = try await engine.call("getSSHKeyState", as: String.self)
        let body = key.split(separator: " ").prefix(2).joined(separator: " ")
        if !keys.contains(body) {
            let merged = [keys.trimmingCharacters(in: .whitespacesAndNewlines), key].filter { !$0.isEmpty }.joined(separator: "\n")
            try await engine.call("setSSHKeyState", params: .object(["sshKey": .string(merged)]))
        }
        // The SSH server starts with Developer Mode.
        for _ in 0..<10 {
            if await shellWorks() { return shell }
            try await Task.sleep(for: .seconds(1))
        }
        _ = try await shell.run("true", timeout: 10) // its error explains
        return shell
    }

    // MARK: Self-test

    /// Every row has a state or an error, and no action runs.
    var isSettled: Bool {
        !isWorking && (firmware.value != nil || firmware.error != nil) && (tailscale.value != nil || tailscale.error != nil)
            && (password.value != nil || password.error != nil)
    }

    var report: [String: Any] {
        func text<Value>(_ row: Row<Value>) -> String {
            row.error.map { "error: \($0)" } ?? row.value.map { "\($0)" } ?? "unknown"
        }
        return ["firmware": text(firmware), "tailscale": text(tailscale), "password": text(password),
                "bundledFirmware": builds.map(\.build.title)]
    }

    // MARK: Helpers

    private struct LocalVersion: Decodable {
        var appVersion: String
    }

    private struct DevModeState: Decodable {
        var enabled: Bool
    }

    private static func bundledFirmware() -> [(build: FirmwareBuild, binary: URL)] {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Firmware", isDirectory: true),
              let data = try? Data(contentsOf: folder.appendingPathComponent("Firmware.json")),
              let builds = try? FirmwareBuild.manifest(data) else { return [] }
        return builds.compactMap { build in
            let binary = folder.appendingPathComponent(build.fileName)
            return FileManager.default.fileExists(atPath: binary.path) ? (build, binary) : nil
        }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? SetupError { return error.message }
        if let error = error as? EngineError { return error.message.prefix(1).uppercased() + error.message.dropFirst() + "." }
        return error.localizedDescription
    }
}

struct SetupError: Error {
    let message: String

    init(_ message: String) { self.message = message }
}

/// SSH to a JetKVM in Developer Mode as root, with a key this app creates
/// and keeps in its Application Support folder.
struct JetKVMShell {
    let host: String
    let hostKeyAlias: String

    static let directory = DeviceStore.defaultURL().deletingLastPathComponent().appendingPathComponent("SSH", isDirectory: true)
    static let privateKey = directory.appendingPathComponent("id_ed25519")
    static let knownHosts = directory.appendingPathComponent("known_hosts")

    /// This app's public key, created on first use.
    static func publicKey() throws -> String {
        if !FileManager.default.fileExists(atPath: privateKey.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let keygen = Process()
            keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            keygen.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", "BlitzKVM (\(Host.current().localizedName ?? "Mac"))",
                                "-f", privateKey.path]
            try keygen.run()
            keygen.waitUntilExit()
            guard keygen.terminationStatus == 0 else { throw SetupError("Couldn't create an SSH key for this Mac.") }
        }
        return try String(contentsOf: privateKey.appendingPathExtension("pub"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs a shell command on the JetKVM and returns its output; `input` is
    /// streamed to the command's standard input.
    func run(_ command: String, input: URL? = nil, timeout: TimeInterval = 30) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = JetKVMSSH.arguments(host: host, hostKeyAlias: hostKeyAlias, privateKey: Self.privateKey.path,
                                                knownHosts: Self.knownHosts.path, command: command)
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = try input.map { try FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { process.terminate() }
                }
                var stderr = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    stderr = errors.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let stdout = output.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: String(decoding: stdout, as: UTF8.self))
                } else {
                    let message = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: SetupError(Self.explain(message, status: process.terminationStatus,
                                                                          timedOut: process.terminationReason == .uncaughtSignal)))
                }
            }
        }
    }

    private static func explain(_ message: String, status: Int32, timedOut: Bool) -> String {
        if timedOut { return "The JetKVM stopped answering over SSH." }
        if message.contains("Connection refused") { return "SSH is off on the JetKVM." }
        if message.contains("Permission denied") { return "The JetKVM doesn't accept this Mac's SSH key." }
        if message.contains("Host key verification failed") || message.contains("IDENTIFICATION HAS CHANGED") {
            return "The JetKVM's SSH identity changed. If it was reset, remove its line from \(knownHosts.path)."
        }
        return message.isEmpty ? "A command on the JetKVM failed (exit \(status))." : message
    }
}

/// This Mac's Tailscale command-line interface (the app's, or a standalone
/// install).
enum TailscaleCLI {
    private static let paths = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/local/bin/tailscale",
                                "/opt/homebrew/bin/tailscale"]

    /// The DERP region the traffic to the tailnet address goes through, nil
    /// when it goes direct (or Tailscale doesn't say).
    static func relay(to address: String) -> String? {
        guard let path = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["status", "--json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? TailscaleCLIStatus.relay(statusJSON: data, to: address) : nil
    }
}
