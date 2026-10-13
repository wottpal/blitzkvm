import AppKit
import SwiftUI

/// BlitzKVM › Settings…: updates and the permissions the app needs.
struct SettingsView: View {
    @ObservedObject var updater: Updater
    @ObservedObject var permissions: PermissionsModel

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(iconSize: 64, title: "BlitzKVM", subtitle: Self.version)
            Form {
                UpdatesSection(updater: updater)
                PermissionsSection(permissions: permissions, showsHeader: true)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 24)
        .padding(.bottom, 4) // the form adds its own bottom margin
        .frame(width: 540)
        .onAppear { permissions.startWatching() }
        .onDisappear { permissions.stopWatching() }
    }

    /// "Version 0.1.0 (268)".
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "–"
        let build = info["CFBundleVersion"] as? String ?? "–"
        return "Version \(short) (\(build))"
    }
}

/// The app icon over a title and a line below it: the top of the welcome
/// screen and of Settings.
struct AppHeader: View {
    let iconSize: CGFloat
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: iconSize, height: iconSize)
                .accessibilityHidden(true)
            Text(title)
                .font(iconSize > 72 ? .title.weight(.semibold) : .title2.weight(.semibold))
                .padding(.top, iconSize > 72 ? 10 : 6)
            Text(subtitle)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.top, 4)
        }
    }
}

/// Whether and how BlitzKVM updates itself, and a check on demand.
struct UpdatesSection: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { updater.checksAutomatically }, set: { updater.checksAutomatically = $0 })) {
                Text("Check for updates automatically")
                Text("Once a day, from BlitzKVM's releases on GitHub.")
            }
            Toggle(isOn: Binding(get: { updater.installsAutomatically }, set: { updater.installsAutomatically = $0 })) {
                Text("Download and install updates automatically")
                Text("They install when you quit BlitzKVM.")
            }
            .disabled(!updater.checksAutomatically || !updater.allowsAutomaticInstalls)
            LabeledContent {
                Button("Check Now") { updater.checkForUpdates(nil) }
                    .disabled(!updater.canCheck)
            } label: {
                Text(lastChecked)
                    .monospacedDigit()
                    .contentTransition(.opacity)
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("Every update is notarized by Apple and verified before it installs.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(.snappy(duration: 0.2), value: updater.lastCheck)
    }

    private var lastChecked: String {
        guard let date = updater.lastCheck else { return "Not checked yet" }
        return "Last checked " + date.formatted(.relative(presentation: .named).locale(.englishInUserRegion))
    }
}

/// The two permissions: each with what it is for and the one action that
/// grants it, or a check once granted.
struct PermissionsSection: View {
    @ObservedObject var permissions: PermissionsModel
    var showsHeader = false

    var body: some View {
        Section {
            localNetworkRow
            accessibilityRow
        } header: {
            if showsHeader { Text("Permissions") }
        } footer: {
            Text("Change these anytime in System Settings › Privacy & Security.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(.snappy(duration: 0.2), value: permissions.localNetwork)
        .animation(.snappy(duration: 0.2), value: permissions.accessibility)
    }

    private var localNetworkRow: some View {
        let state = permissions.localNetwork
        return StatusRow(symbol: "network", tint: .blue, title: "Local Network", tag: "Required",
                         note: state == .denied
                             ? "Turn on BlitzKVM in Privacy & Security › Local Network."
                             : "Reach your JetKVMs on this network.") {
            switch state {
            case .allowed:
                DoneBadge(title: "Allowed")
            case .asking:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Waiting for your answer")
            case .notAsked:
                Button("Allow…", action: permissions.allowLocalNetwork)
            case .denied:
                Button("Open Settings…", action: permissions.allowLocalNetwork)
            }
        }
    }

    private var accessibilityRow: some View {
        StatusRow(symbol: "keyboard", tint: .purple, title: "Accessibility", tag: "Recommended",
                  note: "Send ⌘Tab and ⌘Space to the remote computer.") {
            if permissions.accessibility {
                DoneBadge(title: "Allowed")
            } else {
                Button("Allow…", action: permissions.allowAccessibility)
            }
        }
    }
}

final class SettingsWindowController: NSWindowController {
    init(updater: Updater, permissions: PermissionsModel) {
        // The window takes the view's size (and follows it as it changes).
        let host = NSHostingController(rootView: SettingsView(updater: updater, permissions: permissions))
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
