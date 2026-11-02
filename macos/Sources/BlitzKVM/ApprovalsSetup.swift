import AppKit
import ApprovalKit
import JetKVMCore
import LocalAuthentication
import SwiftUI

/// JetKVM Setup's Approvals row (BlitzKVM firmware D20): turns approvals on
/// with this Mac as their owner, installs the remote side on the computer
/// (remote/install) over clipboard sync's login, removes it, and turns
/// approvals off. Owned by the setup model, so an install goes on with the
/// sheet closed.
@MainActor
final class ApprovalsSetupModel: ObservableObject {
    @Published private(set) var row = JetKVMSetupModel.Row<ApprovalsSetupState>()
    /// The last install left sudo out: /usr/local isn't root's on the
    /// remote Mac (Homebrew on Intel), so PAM can't be installed safely.
    @Published private(set) var withoutSudo = false
    private weak var controller: DeviceWindowController?
    private var service: ApprovalService { .shared }

    init(controller: DeviceWindowController) {
        self.controller = controller
    }

    var isWorking: Bool { row.isWorking }

    /// The remote Mac, as clipboard sync knows it.
    var computerName: String { controller?.device.clipboardSync?.computerName ?? controller?.device.name ?? "the computer" }

    private var on: ApprovalsSetupState.On? {
        if case .on(let on)? = row.value { return on }
        return nil
    }

    /// The installed remote side has a Mac password stored here.
    var hasMacPassword: Bool {
        on?.target.map { service.hasPassword(target: $0.id, kind: SecretKind.mac) } ?? false
    }

    var isInstalled: Bool { on?.target != nil }

    /// Installed and its daemon connected: it updates and removes the remote
    /// side on this owner's order, without the password.
    var daemonMaintains: Bool { on?.target != nil && on?.connected == true }

    /// Targets whose agent keeps 1Password running, as this Mac set them.
    private static let keepKey = "approvalsKeepOnePasswordRunning"
    private static var keeping: Set<String> { Set(UserDefaults.standard.stringArray(forKey: keepKey) ?? []) }
    private static func setKeeping(_ id: String, _ keep: Bool) {
        var ids = keeping
        if keep { ids.insert(id) } else { ids.remove(id) }
        UserDefaults.standard.set(ids.sorted(), forKey: keepKey)
    }

    var keepsOnePasswordRunning: Bool { on?.target.map { Self.keeping.contains($0.id) } ?? false }

    func refresh() { Task { await check() } }

    /// Reads the JetKVM's approvals and this Mac's part in them.
    func check() async {
        guard let controller else { return }
        do {
            let state = try await controller.engine.call("getApprovalsState", as: DeviceApprovals.self)
            service.deviceState(state, address: controller.address)
            let center = service.center
            row.value = ApprovalsSetupState.evaluate(device: state, hasClipboardSync: controller.device.clipboardSync != nil,
                                                     roster: center?.roster(state.broker.id), me: center?.keys.id ?? "")
            row.error = nil
        } catch {
            row.error = JetKVMSetupModel.describe(error)
        }
    }

    /// Runs an action with the row's progress, and its error unless Touch
    /// ID was cancelled.
    private func perform(_ first: String, _ action: @escaping (DeviceWindowController) async throws -> Void) {
        guard let controller, !row.isWorking else { return }
        Task {
            row.error = nil
            row.progress = first
            do {
                try await action(controller)
                row.progress = nil
                await check()
            } catch {
                row.progress = nil
                await check()
                if !ApprovalService.isCancellation(error) { row.error = JetKVMSetupModel.describe(error) }
            }
        }
    }

    // MARK: On and off

    /// Makes this Mac the owner: a first roster with this Mac as its only
    /// approver, sent over the window's identity-pinned session.
    func turnOn() {
        perform("Turning on approvals…") { [self] controller in
            guard controller.device.clipboardSync != nil else {
                throw SetupError("Set up clipboard sync first: approvals use its USB link.")
            }
            let center = try service.prepare()
            let state = try await controller.engine.call("getApprovalsState", as: DeviceApprovals.self)
            if state.enabled, center.roster(state.broker.id)?.isOwner(center.keys.id) != true {
                throw SetupError("Approvals are on already, under other owners. Turn them off first to take them over.")
            }
            let relay = UserDefaults.standard.string(forKey: ApprovalService.relayKey).flatMap(ApprovalAddress.relay)
            row.progress = "Waiting for Touch ID…"
            let genesis = try await service.signAsOwner(reason: "turn on approvals for \(controller.device.name)") { presence in
                try center.genesis(broker: state.broker, name: controller.device.name,
                                   direct: ApprovalAddress.base(controller.address), relay: relay, presence: presence)
            }
            row.progress = "Turning on approvals…"
            do {
                try await controller.engine.call("setApprovalsEnabled", params: .object([
                    "enabled": .bool(true), "roster": try JSONValue(encoding: genesis),
                ]))
            } catch {
                center.remove(brokerID: state.broker.id)
                throw error
            }
            AppLog.log("approvals: on for \(controller.device.name), broker \(state.broker.id)")
            service.notifications.requestAuthorization()
        }
    }

    /// Turns approvals off on the JetKVM and forgets them here. The remote
    /// side stays installed (sudo there asks for the password again).
    func turnOff() {
        perform("Turning off approvals…") { [self] controller in
            let state = try? await controller.engine.call("getApprovalsState", as: DeviceApprovals.self)
            try await controller.engine.call("setApprovalsEnabled", params: .object(["enabled": .bool(false)]))
            if let id = state?.broker.id { service.center?.remove(brokerID: id) }
            AppLog.log("approvals: off for \(controller.device.name)")
        }
    }

    // MARK: The remote side

    /// Installs the remote side on the computer and adds it to the roster:
    /// one Touch ID covers the stored password and the owner's signature.
    /// `typed` is the remote Mac's password when none is stored, kept when
    /// `remember`.
    func install(password typed: String?, remember: Bool) {
        perform("Waiting for Touch ID…") { [self] controller in
            guard let on, let sync = controller.device.clipboardSync, let center = service.center, let keys = service.keys else {
                throw SetupError("Set up clipboard sync and turn approvals on first.")
            }
            let payload = try RemoteApprovalsPayload.load()
            let computer = computerName
            let wasInstalled = on.target != nil
            let context = LAContext()
            defer { context.invalidate() }
            try await ApprovalService.authenticate(context, reason: wasInstalled ? "update approvals on \(computer)" : "install approvals on \(computer)")
            let installer = RemoteApprovalsInstaller(engine: controller.engine, sync: sync, computer: computer)
            // Installed and connected: its daemon updates it on this owner's
            // signed order, with no password through the user's login.
            if typed == nil, let target = on.target, on.connected,
               try await installer.maintain(MaintainOrder.update, brokerID: on.brokerID, target: target, payload: payload,
                                            presence: keys.presence(with: context), progress: { row.progress = $0 }) {
                await waitForTarget(target.id, engine: controller.engine)
                AppLog.log("approvals: updated on \(computer) through its daemon")
                return
            }
            let password = try typed ?? on.target.flatMap { try service.vault.secret(target: $0.id, kind: SecretKind.mac, context: context) }
            guard let password, !password.isEmpty else { throw SetupError(Self.needsPassword(sync.user, computer, daemon: on.connected)) }
            row.progress = "Uploading to \(computer)…"
            let staged = try await installer.stage(payload)
            do {
                // With approvals running there, its own sudo asks for one.
                row.progress = wasInstalled ? "Installing on \(computer): approve its sudo request…" : "Installing on \(computer)…"
                let target = try await installer.identity(staged, payload: payload, password: password)
                row.progress = "Adding \(computer) to the approvals…"
                // One computer per JetKVM: a new one replaces the last.
                let roster = try center.update(on.brokerID, presence: keys.presence(with: context)) { $0.targets = [target] }
                try await pushRoster(roster, engine: controller.engine)
                row.progress = "Installing on \(computer)…"
                withoutSudo = try await installer.install(staged, payload: payload, roster: roster, password: password)
                if typed == nil || remember { try service.storePassword(password, target: target.id, kind: SecretKind.mac) }
                await installer.cleanUp(staged)
                row.progress = "Waiting for \(computer) to connect…"
                await waitForTarget(target.id, engine: controller.engine)
                AppLog.log("approvals: installed on \(computer) as target \(target.id)\(withoutSudo ? " (without sudo)" : "")")
            } catch {
                await installer.cleanUp(staged)
                throw error
            }
        }
    }

    /// Takes the remote side off the computer and out of the roster; its
    /// stored passwords go too.
    func remove(password typed: String?) {
        perform("Waiting for Touch ID…") { [self] controller in
            guard let on, let target = on.target, let sync = controller.device.clipboardSync,
                  let center = service.center, let keys = service.keys else { return }
            let payload = try RemoteApprovalsPayload.load()
            let computer = computerName
            let context = LAContext()
            defer { context.invalidate() }
            try await ApprovalService.authenticate(context, reason: "remove approvals from \(computer)")
            let installer = RemoteApprovalsInstaller(engine: controller.engine, sync: sync, computer: computer)
            // Its daemon removes it on this owner's order when it can; else
            // the password path.
            var removed = false
            if typed == nil, on.connected {
                removed = try await installer.maintain(MaintainOrder.remove, brokerID: on.brokerID, target: target, payload: payload,
                                                       presence: keys.presence(with: context), progress: { row.progress = $0 })
            }
            if !removed {
                let password = try typed ?? service.vault.secret(target: target.id, kind: SecretKind.mac, context: context)
                guard let password, !password.isEmpty else { throw SetupError(Self.needsPassword(sync.user, computer, daemon: on.connected)) }
                row.progress = "Removing from \(computer): approve its sudo request…"
                try await installer.uninstall(payload, password: password)
            }
            row.progress = "Removing \(computer) from the approvals…"
            let roster = try center.update(on.brokerID, presence: keys.presence(with: context)) { r in
                r.targets.removeAll { $0.id == target.id }
            }
            try await pushRoster(roster, engine: controller.engine)
            for kind in ApprovalSummary.passwordKinds { service.removePassword(target: target.id, kind: kind) }
            try? await installer.keepOnePasswordRunning(false)
            Self.setKeeping(target.id, false)
            withoutSudo = false
            AppLog.log("approvals: removed from \(computer)")
        }
    }

    /// Has the agent on the computer keep 1Password running, or not: a user
    /// default there, set over clipboard sync's login (no sudo).
    func setKeepOnePasswordRunning(_ keep: Bool) {
        perform(keep ? "Keeping 1Password running…" : "Letting 1Password quit…") { [self] controller in
            guard let target = on?.target, let sync = controller.device.clipboardSync else { return }
            let installer = RemoteApprovalsInstaller(engine: controller.engine, sync: sync, computer: computerName)
            try await installer.keepOnePasswordRunning(keep)
            Self.setKeeping(target.id, keep)
            AppLog.log("approvals: \(keep ? "keeping" : "not keeping") 1Password running on \(computerName)")
        }
    }

    /// Sends an owner's new roster over the session too: the box may wait
    /// for a channel, the session is there now. Fine when the box got there
    /// first (the JetKVM then refuses the same roster again).
    private func pushRoster(_ roster: Envelope, engine: EngineProcess) async throws {
        do {
            try await engine.call("setApprovalsEnabled", params: .object(["enabled": .bool(true), "roster": try JSONValue(encoding: roster)]))
        } catch {
            let state = try await engine.call("getApprovalsState", as: DeviceApprovals.self)
            guard let seq = try? roster.peek(Roster.self).seq, (state.seq ?? 0) >= seq else { throw error }
        }
    }

    /// No password for the password path: after a daemon that takes no
    /// orders (installed before them), store it in Settings first.
    private static func needsPassword(_ user: String, _ computer: String, daemon: Bool) -> String {
        daemon ? "The approvals daemon on \(computer) is from an older BlitzKVM and takes no orders: store the password of "
            + "\(user) for \(computer) in Settings › Approvals, then try again (once; later updates need none)."
            : "Enter the password of \(user) on \(computer)."
    }

    /// The daemon connects to the JetKVM within seconds of its start.
    private func waitForTarget(_ id: String, engine: EngineProcess) async {
        for _ in 0..<20 {
            if (try? await engine.call("getApprovalsState", as: DeviceApprovals.self))?.target == id { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

/// The remote side as the app bundles it (Contents/Resources/Remote, from
/// remote/build): the files install.sh takes, their hashes and a tar.gz of
/// them.
struct RemoteApprovalsPayload {
    let folder: URL
    /// File name → SHA-256 hex.
    let files: [String: String]

    @MainActor
    static func load() throws -> RemoteApprovalsPayload {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Remote", isDirectory: true),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
              names.contains("install.sh"), names.contains("blitzkvm-remote") else {
            throw SetupError("This build of BlitzKVM doesn't include the remote side of approvals.")
        }
        var files: [String: String] = [:]
        for name in names where !name.hasPrefix(".") {
            files[name] = try JetKVMSetupModel.sha256(of: folder.appendingPathComponent(name))
        }
        return RemoteApprovalsPayload(folder: folder, files: files)
    }

    /// The files as a tar.gz, without macOS metadata (no ._ files).
    func tarball() async throws -> Data {
        let folder = folder, names = files.keys.sorted()
        return try await Task.detached {
            let tar = Foundation.Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-czf", "-", "-C", folder.path] + names
            tar.environment = ["COPYFILE_DISABLE": "1"]
            let out = Pipe()
            tar.standardOutput = out
            tar.standardError = FileHandle.nullDevice
            try tar.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            tar.waitUntilExit()
            guard tar.terminationStatus == 0 else { throw SetupError("Couldn't pack the remote side.") }
            return data
        }.value
    }

    var uninstallScript: String {
        get throws { try String(contentsOf: folder.appendingPathComponent("uninstall.sh"), encoding: .utf8) }
    }
}

/// RemoteInstall's steps over the window's engine (hostLinkRun).
@MainActor
struct RemoteApprovalsInstaller {
    let engine: EngineProcess
    let sync: ClipboardSync
    let computer: String

    private func run(_ command: String, stdin: Data? = nil, timeout: Int = 150) async throws -> HostLinkRun.Result {
        let params = HostLinkRun.params(sync: sync, privateKeyPath: ClipboardKey.privateKey.path, command: command,
                                        stdin: stdin, timeout: timeout)
        guard let data = try await engine.run(EngineCommand(cmd: HostLinkRun.command, params: params)),
              let result = try? JSONDecoder().decode(HostLinkRun.Result.self, from: data) else {
            throw SetupError("The engine didn't say how the command on \(computer) went.")
        }
        return result
    }

    private func checked(_ command: String, stdin: Data? = nil) async throws -> String {
        let result = try await run(command, stdin: stdin)
        guard result.exitCode == 0 else { throw SetupError(RemoteInstall.explain(result, user: sync.user, computer: computer)) }
        return result.stdout
    }

    /// Uploads the files as the user; returns where they are.
    func stage(_ payload: RemoteApprovalsPayload) async throws -> RemoteInstall.Staged {
        let output = try await checked(RemoteInstall.stageCommand, stdin: try await payload.tarball())
        guard let staged = RemoteInstall.staged(output: output) else {
            throw SetupError("\(computer) didn't say where the upload went, or isn't on the JetKVM's USB link.")
        }
        return staged
    }

    /// Installs the binary as root and reads the target's identity.
    func identity(_ staged: RemoteInstall.Staged, payload: RemoteApprovalsPayload, password: String) async throws -> Target {
        guard let command = RemoteInstall.identityCommand(staging: staged.directory, files: payload.files) else {
            throw SetupError("The remote side's files have unexpected names.")
        }
        let output = try await checked(command, stdin: RemoteInstall.sudoInput(password: password))
        guard let target = RemoteInstall.identity(output: output, name: computer) else {
            throw SetupError("\(computer) didn't report its approval key.")
        }
        return target
    }

    /// Installs the rest with the roster that names the target; true when
    /// it had to leave sudo out.
    func install(_ staged: RemoteInstall.Staged, payload: RemoteApprovalsPayload, roster: Envelope,
                 password: String) async throws -> Bool {
        for sudoApprovals in [true, false] {
            guard let command = RemoteInstall.installCommand(staging: staged.directory, files: payload.files, roster: roster,
                                                             linkAddress: staged.linkAddress, sudoApprovals: sudoApprovals) else {
                throw SetupError("The remote side's files have unexpected names.")
            }
            let result = try await run(command, stdin: RemoteInstall.sudoInput(password: password))
            if result.exitCode == 0 { return !sudoApprovals }
            guard sudoApprovals, RemoteInstall.needsNoSudo(stderr: result.stderr) else {
                throw SetupError(RemoteInstall.explain(result, user: sync.user, computer: computer))
            }
        }
        return true
    }

    /// Updates or removes the remote side through its daemon: stages the
    /// files, hands it the order signed with `presence`, and waits for the
    /// job. False when that daemon takes no orders (from before them, or
    /// without a Developer ID): the password path is left.
    func maintain(_ action: String, brokerID: String, target: Target, payload: RemoteApprovalsPayload, presence: EnvelopeSigner,
                  progress: (String) -> Void) async throws -> Bool {
        progress("Uploading to \(computer)…")
        let staged = try await stage(payload)
        defer { Task { await cleanUp(staged) } }
        guard let order = RemoteInstall.order(action, broker: brokerID, target: target.id, staged: staged, files: payload.files,
                                              issued: Int64(Date().timeIntervalSince1970)) else { return false }
        let signed = try Envelope.sign(order, type: "maintain", with: presence)
        switch RemoteInstall.maintainResult(try await run(RemoteInstall.maintainCommand, stdin: try Wire.encoder.encode(signed))) {
        case .unsupported:
            return false
        case .refused(let why):
            throw SetupError(why)
        case .started:
            break
        }
        progress(action == MaintainOrder.update ? "Updating on \(computer)…" : "Removing from \(computer)…")
        for _ in 0..<60 {
            try await Task.sleep(for: .seconds(2))
            let status = RemoteInstall.maintainStatus((try? await run(RemoteInstall.statusCommand, timeout: 20))?.stdout ?? "")
            switch (status, action) {
            case (.done, MaintainOrder.update), (.gone, MaintainOrder.remove): return true
            case (.failed(let why), _): throw SetupError(why)
            default: continue
            }
        }
        throw SetupError("\(computer) didn't say how the \(action == MaintainOrder.update ? "update" : "removal") went.")
    }

    func uninstall(_ payload: RemoteApprovalsPayload, password: String) async throws {
        _ = try await checked(RemoteInstall.uninstallCommand(script: try payload.uninstallScript),
                              stdin: RemoteInstall.sudoInput(password: password))
    }

    func keepOnePasswordRunning(_ keep: Bool) async throws {
        _ = try await checked(RemoteInstall.keepOnePasswordCommand(keep))
    }

    func cleanUp(_ staged: RemoteInstall.Staged) async {
        if let command = RemoteInstall.cleanupCommand(staging: staged.directory) { _ = try? await run(command, timeout: 30) }
    }
}

// MARK: - Row

/// The Approvals row: off, on with its approvers and computer, and the one
/// action that moves it forward.
struct ApprovalsSetupRow: View {
    @ObservedObject var model: ApprovalsSetupModel
    /// Opens clipboard sync's setup (approvals need its link and login).
    let setUpClipboard: () -> Void
    @State private var confirming: Confirmation?
    @State private var asking: PasswordPrompt.Purpose?

    var body: some View {
        SetupRow(symbol: "checkmark.shield.fill", tint: .pink, title: "Approvals", row: model.row, content: content,
                 retry: model.refresh)
            .alert(confirming?.title(computer: model.computerName) ?? "",
                   isPresented: Binding { confirming != nil } set: { if !$0 { confirming = nil } },
                   presenting: confirming) { confirmation in
                Button(confirmation.action) { perform(confirmation) }
                Button("Cancel", role: .cancel) {}
            } message: { confirmation in
                Text(confirmation.message(computer: model.computerName, installed: model.isInstalled, daemon: model.daemonMaintains))
            }
            .sheet(item: $asking) { purpose in
                PasswordPrompt(purpose: purpose, computer: model.computerName) { password, remember in
                    switch purpose {
                    case .install: model.install(password: password, remember: remember)
                    case .remove: model.remove(password: password)
                    }
                }
            }
    }

    private var content: RowContent {
        let computer = model.computerName
        let turnOff = RowAction(title: "Turn Off…") { confirming = .turnOff }
        let settings = RowAction(title: "Approvals Settings…") {
            NotificationCenter.default.post(name: ApprovalService.showSettings, object: nil)
        }
        let relayNote = UserDefaults.standard.string(forKey: ApprovalService.relayKey)?.isEmpty == false ? ""
            : " Without a relay (Settings › Approvals) only Macs on the JetKVM's network or tailnet get requests."
        switch model.row.value {
        case .needsClipboardSync?:
            return RowContent(detail: "Off", note: "Uses clipboard sync's USB link: set that up first.",
                              action: .init(title: "Set Up Clipboard Sync…", perform: setUpClipboard))
        case .off?:
            return RowContent(detail: "Off", note: "Approve sudo and password prompts with Touch ID." + relayNote,
                              action: .init(title: "Turn On…") { confirming = .turnOn }, menu: [settings])
        case .managedElsewhere(let approvers, _)?:
            return RowContent(detail: "On, set up elsewhere", note: approvers.isEmpty ? nil : "Approvers: \(ApproverLine.names(approvers)).",
                              action: turnOff)
        case .on(let on)?:
            let approvers = ApproverLine.names(on.approvers)
            guard let target = on.target else {
                let first = on.canInstall ? RowAction(title: "Install on \(computer)…") { install() }
                    : RowAction(title: "Set Up Clipboard Sync…", perform: setUpClipboard)
                return RowContent(detail: "On · \(approvers)", note: "Install on \(computer) to approve its prompts.",
                                  action: first, menu: [settings, turnOff])
            }
            let keep = model.keepsOnePasswordRunning
            let note = (model.withoutSudo ? "Installed without sudo: /usr/local isn't root's there."
                : on.connected ? "sudo stays approved 5 minutes after each approval." : "Waiting for \(target.name) to connect.")
                + (keep ? " 1Password is kept running there." : "")
            let keepRunning = RowAction(title: "Keep 1Password Running", checked: keep) { model.setKeepOnePasswordRunning(!keep) }
            return RowContent(detail: "\(target.name) · \(approvers)", note: note, badge: "On",
                              menu: [settings, keepRunning, RowAction(title: "Reinstall on \(target.name)…") { install() },
                                     RowAction(title: "Remove from \(target.name)…") { remove() }, turnOff])
        case nil:
            return RowContent(detail: "Checking…")
        }
    }

    private func install() {
        if model.hasMacPassword || model.daemonMaintains { confirming = .install } else { asking = .install }
    }

    private func remove() {
        if model.hasMacPassword || model.daemonMaintains { confirming = .remove } else { asking = .remove }
    }

    private enum Confirmation: Identifiable {
        case turnOn, turnOff, install, remove

        var id: Self { self }

        func title(computer: String) -> String {
            switch self {
            case .turnOn: "Turn on approvals?"
            case .turnOff: "Turn off approvals?"
            case .install: "Install approvals on \(computer)?"
            case .remove: "Remove approvals from \(computer)?"
            }
        }

        func message(computer: String, installed: Bool, daemon: Bool) -> String {
            switch self {
            case .turnOn:
                return "This Mac becomes the owner of the JetKVM's approvals: it approves with Touch ID, and pairs your "
                    + "iPhone in Settings › Approvals. Then install them on \(computer) from this row."
            case .turnOff:
                return installed
                    ? "Your approvers are forgotten, and sudo on \(computer) asks for the password again. The remote side "
                        + "stays installed; remove it first to take it off \(computer)."
                    : "Your approvers are forgotten; turning approvals on again starts over."
            case .install where daemon:
                return "The approvals daemon on \(computer) installs this version on your signed order: one Touch ID here, "
                    + "no password. It checks that the files are the ones you signed and are signed by BlitzKVM."
            case .install:
                return "BlitzKVM installs a daemon and, for sudo, a PAM module on \(computer), over clipboard sync's login "
                    + "and with the stored password. sudo, password dialogs and 1Password there then ask your approvers."
            case .remove where daemon:
                return "The approvals daemon on \(computer) removes itself and the PAM module on your signed order, without "
                    + "a password; sudo there asks for the password again. The passwords stored for it on this Mac go too."
            case .remove:
                return "BlitzKVM takes the daemon and the PAM module off \(computer), with the stored password; sudo there "
                    + "asks for the password again. The passwords stored for it on this Mac go too."
            }
        }

        var action: String {
            switch self {
            case .turnOn: "Turn On"
            case .turnOff: "Turn Off"
            case .install: "Install"
            case .remove: "Remove"
            }
        }
    }

    private func perform(_ confirmation: Confirmation) {
        switch confirmation {
        case .turnOn: model.turnOn()
        case .turnOff: model.turnOff()
        case .install: model.install(password: nil, remember: false)
        case .remove: model.remove(password: nil)
        }
    }
}

/// Asks for the remote Mac's password when none is stored: sudo needs it
/// to install or remove the remote side.
private struct PasswordPrompt: View {
    enum Purpose: String, Identifiable {
        case install, remove
        var id: String { rawValue }
    }

    let purpose: Purpose
    let computer: String
    let done: (_ password: String, _ remember: Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var remember = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(purpose == .install ? "Install on \(computer)" : "Remove from \(computer)")
                .font(.title3.weight(.semibold))
                .padding([.horizontal, .top], 20)
            Text("sudo there needs the password of your account on \(computer).")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.top, 4)
            Form {
                SecureField("Password", text: $password)
                if purpose == .install {
                    Toggle(isOn: $remember) {
                        Text("Remember on this Mac")
                        Text("Behind Touch ID. When you approve a password dialog on \(computer), the JetKVM can type it there.")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(purpose == .install ? "Install" : "Remove") {
                    done(password, remember)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
