import JetKVMCore
import SwiftUI

/// Set Up JetKVM: the BlitzKVM firmware, a password and Tailscale,
/// each with its state and the one action that moves it forward.
struct JetKVMSetupView: View {
    @ObservedObject var model: JetKVMSetupModel
    let deviceName: String
    let address: String
    let done: () -> Void
    @State private var confirming: Confirmation?
    @State private var passwordSheet: PasswordSheet.Mode?

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section {
                    firmwareRow
                    passwordRow
                    tailscaleRow
                } footer: {
                    Text("Installs turn on SSH (Developer Mode) with a key kept on this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden) // one surface with the header
            .scrollDisabled(true)
            HStack {
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .alert(confirming?.title ?? "", isPresented: Binding { confirming != nil } set: { if !$0 { confirming = nil } },
               presenting: confirming) { confirmation in
            Button(confirmation.action) { perform(confirmation) }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
        .sheet(item: $passwordSheet) { mode in
            PasswordSheet(mode: mode) { current, new in
                switch (current, new) {
                case let (current?, new?): model.changePassword(current: current, to: new)
                case let (nil, new?): model.createPassword(new)
                case let (current?, nil): model.removePassword(current: current)
                case (nil, nil): break
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Set Up JetKVM")
                    .font(.title2.weight(.semibold))
                Text(deviceName == address ? address : "\(deviceName) · \(address)")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding([.horizontal, .top], 20)
    }

    // MARK: Rows

    /// The firmware row: the build that runs, the BlitzKVM build as
    /// the main action, and every build the app ships in its menu, so
    /// switching between them (or reinstalling one) is one choice away.
    private var firmwareRow: some View {
        let row = model.firmware
        let builds = model.builds.map(\.build)
        guard let recommended = model.recommended ?? builds.first else {
            return SetupRow(symbol: "cpu", tint: .indigo, title: "Firmware", row: row,
                            content: RowContent(detail: "This build of the app doesn't include firmware."), retry: model.refresh)
        }
        func install(_ build: FirmwareBuild) -> () -> Void { { confirming = .firmware(build) } }
        func choices(installed: FirmwareBuild?) -> [RowAction] {
            builds.map { build in
                let verb = build == installed ? "Reinstall" : build.kind == .stock ? "Switch to" : "Install"
                return RowAction(title: "\(verb) \(build.title)…", perform: install(build))
            } + [RowAction(title: "Restart JetKVM…") { confirming = .restart }]
        }
        let benefit = "Upgrade for sharper text and larger modes."
        let newer = "\(recommended.title) is newer."
        var content = RowContent(detail: "Checking…")
        switch row.value {
        case .bundled(let build)? where build == recommended:
            content = RowContent(detail: build.title, badge: "Up to Date", menu: choices(installed: build))
        case .bundled(let build)? where build.kind == .blitzkvm:
            content = RowContent(detail: build.title, note: newer,
                                 action: .init(title: "Update…", perform: install(recommended)), menu: choices(installed: build))
        case .bundled(let build)?:
            content = RowContent(detail: "\(build.title), JetKVM's own firmware", note: benefit,
                                 action: .init(title: "Install…", perform: install(recommended)), menu: choices(installed: build))
        case .otherBlitzKVM?:
            content = RowContent(detail: "An older BlitzKVM build", note: newer,
                                 action: .init(title: "Update…", perform: install(recommended)), menu: choices(installed: nil))
        case .unverified?:
            content = RowContent(detail: "BlitzKVM firmware", note: "Check whether it's \(recommended.version).",
                                 action: .init(title: "Check", perform: model.verifyFirmware), menu: choices(installed: nil))
        case .stock(let version)?:
            content = RowContent(detail: "JetKVM \(version), JetKVM's own firmware", note: benefit,
                                 action: .init(title: "Install…", perform: install(recommended)), menu: choices(installed: nil))
        case nil:
            break
        }
        return SetupRow(symbol: "cpu", tint: .indigo, title: "Firmware", row: row, content: content, retry: model.refresh)
    }

    private var tailscaleRow: some View {
        let row = model.tailscale
        let install = RowAction(title: "Install…") { confirming = .tailscale(passwordOff: model.password.value == false) }
        var content = RowContent(detail: "Checking…")
        switch row.value {
        case .notInstalled?:
            content = RowContent(detail: "Not installed", note: "Reach it from anywhere on your tailnet.", action: install)
        case .needsLogin?:
            content = RowContent(detail: "Installed", note: "Log in to add it to your tailnet.",
                                 action: .init(title: "Log In…", perform: model.logIn))
        case .stopped?:
            content = RowContent(detail: "Installed, but not running", note: "Reinstalling starts it again.",
                                 action: .init(title: "Reinstall…", perform: install.perform))
        case .running(let name)?:
            content = RowContent(detail: name,
                                 note: "Turn off its key expiry in the [admin console](https://login.tailscale.com/admin/machines).",
                                 badge: "Connected")
        case nil:
            break
        }
        return SetupRow(symbol: "network", tint: .blue, title: "Tailscale", row: row, content: content, retry: model.refresh)
    }

    private var passwordRow: some View {
        let row = model.password
        var content = RowContent(detail: "Checking…")
        switch row.value {
        case true?:
            content = RowContent(detail: "Set", note: "Asked for on every new connection.", badge: "On",
                                 menu: [RowAction(title: "Change Password…") { passwordSheet = .change(current: model.knownPassword) },
                                        RowAction(title: "Turn Off Password…") { passwordSheet = .turnOff(current: model.knownPassword) }])
        case false?:
            content = RowContent(detail: "Off", note: "Anyone who can reach it has full control.",
                                 action: .init(title: "Set Password…") { passwordSheet = .set })
        case nil:
            break
        }
        return SetupRow(symbol: "lock.fill", tint: .orange, title: "Password", row: row, content: content, retry: model.refresh)
    }

    // MARK: Confirmations

    private enum Confirmation: Identifiable {
        case firmware(FirmwareBuild)
        case tailscale(passwordOff: Bool)
        case restart

        var id: String { title }

        var title: String {
            switch self {
            case .firmware(let build): return build.kind == .stock ? "Switch to \(build.title)?" : "Install \(build.title)?"
            case .tailscale: return "Install Tailscale on this JetKVM?"
            case .restart: return "Restart the JetKVM?"
            }
        }

        var message: String {
            switch self {
            case .firmware(let build):
                let restart = "The JetKVM restarts, which takes about a minute, and the computer may briefly lose its display. "
                    + "The current firmware is kept as a backup."
                return build.kind == .stock
                    ? "JetKVM's own firmware, as released. " + restart
                        + " Sharper text, near-lossless still screens and the largest Match Window sizes need the BlitzKVM firmware."
                    : restart + " JetKVM's automatic updates replace this build with their next release."
            case .restart:
                return "It takes about a minute and reconnects by itself. The computer keeps running, but may briefly lose its display."
            case .tailscale(let passwordOff):
                let base = "It's downloaded from tailscale.com and installed without restarting the JetKVM. Your browser then opens to log in."
                return passwordOff ? base + "\n\nSet a password too: everyone on your tailnet will be able to reach the JetKVM." : base
            }
        }

        var action: String {
            switch self {
            case .firmware(let build) where build.kind == .stock: return "Switch"
            case .restart: return "Restart"
            default: return "Install"
            }
        }
    }

    private func perform(_ confirmation: Confirmation) {
        switch confirmation {
        case .firmware(let build): model.installFirmware(build)
        case .tailscale: model.installTailscale()
        case .restart: model.restartJetKVM()
        }
    }
}

// MARK: - Row

private struct RowAction {
    var title: String
    var perform: () -> Void
}

/// What a row shows for its state: the state, a paragraph on what it means,
/// then either a badge (done) or the action that moves it forward.
private struct RowContent {
    var detail: String
    /// The second paragraph, Markdown (for a link).
    var note: String?
    var badge: String?
    var action: RowAction?
    /// More actions, in a menu next to the badge or the action.
    var menu: [RowAction] = []
}

private struct SetupRow<Value: Equatable>: View {
    let symbol: String
    let tint: Color
    let title: String
    let row: JetKVMSetupModel.Row<Value>
    let content: RowContent
    let retry: () -> Void

    var body: some View {
        let showsError = row.error != nil && row.progress == nil
        StatusRow(symbol: symbol, tint: tint, title: title, state: row.progress ?? row.error ?? content.detail,
                  isError: showsError, note: row.progress == nil && row.error == nil ? content.note : nil) {
            trailing
        }
        .animation(.snappy(duration: 0.2), value: row)
    }

    @ViewBuilder private var trailing: some View {
        if row.isWorking || (row.value == nil && row.error == nil) {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(row.progress ?? "Checking")
        } else if let action = content.action {
            if content.menu.isEmpty {
                Button(action.title, action: action.perform)
            } else {
                Menu(action.title) {
                    menuItems
                } primaryAction: {
                    action.perform()
                }
                .fixedSize()
            }
        } else if row.error != nil {
            Button("Check Again", action: retry)
        } else if let badge = content.badge {
            HStack(spacing: 8) {
                DoneBadge(title: badge)
                if !content.menu.isEmpty {
                    Menu {
                        menuItems
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("More")
                }
            }
        }
    }

    @ViewBuilder private var menuItems: some View {
        ForEach(content.menu.indices, id: \.self) { index in
            Button(content.menu[index].title, action: content.menu[index].perform)
        }
    }
}

// MARK: - Password

/// Sets the JetKVM's first password, changes it (8 to 72 characters, the
/// firmware's limits) or turns it off. Changing and turning off ask for the
/// current password only when the keychain doesn't have it.
private struct PasswordSheet: View {
    enum Mode: Identifiable {
        case set
        /// The current password, when known.
        case change(current: String?)
        /// The current password, when known.
        case turnOff(current: String?)

        var id: String {
            switch self {
            case .set: return "set"
            case .change: return "change"
            case .turnOff: return "turnOff"
            }
        }
    }

    let mode: Mode
    /// The current password (changing, turning off) and the new one (nil:
    /// turning off).
    let done: (_ current: String?, _ new: String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var password = ""
    @State private var confirmation = ""

    private var changing: Bool { if case .change = mode { return true } else { return false } }

    private var turningOff: Bool { if case .turnOff = mode { return true } else { return false } }

    /// Changing or turning off without the current password in the keychain.
    private var asksCurrent: Bool {
        switch mode {
        case .change(nil), .turnOff(nil): return true
        default: return false
        }
    }

    private var title: String {
        switch mode {
        case .set: return "Set a Password"
        case .change: return "Change the Password"
        case .turnOff: return "Turn Off the Password"
        }
    }

    private var action: String {
        switch mode {
        case .set: return "Set Password"
        case .change: return "Change Password"
        case .turnOff: return "Turn Off"
        }
    }

    private var problem: String? {
        if asksCurrent && current.isEmpty { return " " }
        if turningOff { return nil }
        if password.count < 8 { return "At least 8 characters." }
        if password.count > 72 { return "At most 72 characters." }
        if confirmation != password { return confirmation.isEmpty ? " " : "The passwords don't match." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.title3.weight(.semibold))
                .padding([.horizontal, .top], 20)
            Text(turningOff ? "Anyone who can reach the JetKVM gets full control." : "Asked for on every connection, kept in your keychain.")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 20)
                .padding(.top, 4)
            if turningOff && !asksCurrent {
                Spacer().frame(height: 20)
            } else {
                Form {
                    if asksCurrent {
                        SecureField("Current", text: $current)
                    }
                    if !turningOff {
                        SecureField(changing ? "New" : "Password", text: $password)
                        SecureField("Confirm", text: $confirmation)
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
            }
            HStack {
                Text(password.isEmpty ? " " : problem ?? " ")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(action) {
                    switch mode {
                    case .set: done(nil, password)
                    case .change(let known): done(known ?? current, password)
                    case .turnOff(let known): done(known ?? current, nil)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
