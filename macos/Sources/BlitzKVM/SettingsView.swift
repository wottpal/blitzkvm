import AppKit
import SwiftUI

/// BlitzKVM › Settings…: a toolbar tab each for updates and the connection,
/// shortcuts that stay on this Mac, and the permissions the app needs.
enum SettingsTab: String, CaseIterable {
    case general = "General"
    case shortcuts = "Shortcuts"
    case permissions = "Permissions"

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "keyboard"
        case .permissions: "hand.raised"
        }
    }

    @MainActor
    func view(updater: Updater, permissions: PermissionsModel) -> AnyView {
        switch self {
        case .general:
            AnyView(SettingsPane {
                UpdatesSection(updater: updater)
                ConnectionSection()
                GameModeSection()
            } header: {
                AppHeader(iconSize: 64, title: "BlitzKVM", subtitle: Self.version)
            })
        case .shortcuts:
            AnyView(SettingsPane { ShortcutsSettings(store: LocalShortcuts.shared) })
        case .permissions:
            AnyView(SettingsPane { PermissionsSection(permissions: permissions) }
                .onAppear { permissions.startWatching() }
                .onDisappear { permissions.stopWatching() })
        }
    }

    /// "Version 0.1.0 (268)".
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "–"
        let build = info["CFBundleVersion"] as? String ?? "–"
        return "Version \(short) (\(build))"
    }
}

/// One Settings tab: grouped sections at the window's width and their own
/// height, under an optional header.
struct SettingsPane<Content: View, Header: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var header: Header

    var body: some View {
        VStack(spacing: 0) {
            header
            Form { content }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Header.self == EmptyView.self ? 0 : 20)
        .padding(.bottom, 4) // the form adds its own bottom margin
        .frame(width: 540)
    }
}

extension SettingsPane where Header == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.init(content: content, header: { EmptyView() })
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

/// A section's note below it, wrapped to the form's width.
struct SettingsFooter: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            SettingsFooter("Every update is notarized by Apple and verified before it installs.")
        }
        .animation(.snappy(duration: 0.2), value: updater.lastCheck)
    }

    private var lastChecked: String {
        guard let date = updater.lastCheck else { return "Not checked yet" }
        return "Last checked " + date.formatted(.relative(presentation: .named).locale(.englishInUserRegion))
    }
}

/// How BlitzKVM reaches a device away from home.
struct ConnectionSection: View {
    @AppStorage(EngineProcess.directPathKey) private var directPath = true

    var body: some View {
        Section {
            Toggle(isOn: $directPath) {
                Text("Connect directly over the internet")
                Text("For a JetKVM you reach over the Tailscale it runs itself. Public STUN servers (Cloudflare, Google) learn both ends' internet addresses; the stream goes direct, faster and easier on the JetKVM, or stays on Tailscale where no direct path works.")
            }
        } header: {
            Text("Connection")
        } footer: {
            SettingsFooter("Applies from the next connection.")
        }
    }
}

/// How fast Game Mode's locked mouse turns (Device › Game Mode).
struct GameModeSection: View {
    @AppStorage(DeviceWindowController.gameModeSensitivityKey) private var sensitivity = 1.0

    var body: some View {
        Section {
            LabeledContent {
                HStack {
                    Slider(value: $sensitivity, in: 0.25...4)
                    Text(String(format: "%.2f×", sensitivity))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            } label: {
                Text("Mouse sensitivity")
                Text("Scales the raw mouse moves sent while the mouse is locked.")
            }
        } header: {
            Text("Game Mode")
        } footer: {
            SettingsFooter("Applies the next time you click into a window.")
        }
    }
}

/// The two permissions: each with what it is for and the one action that
/// grants it, or a check once granted.
struct PermissionsSection: View {
    @ObservedObject var permissions: PermissionsModel

    var body: some View {
        Section {
            localNetworkRow
            accessibilityRow
        } footer: {
            SettingsFooter("Change these anytime in System Settings › Privacy & Security.")
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

/// The Settings window: toolbar tabs, each tab's height (the window follows
/// it), titled after the tab.
final class SettingsWindowController: NSWindowController {
    private let tabs = NSTabViewController()

    init(updater: Updater, permissions: PermissionsModel) {
        tabs.tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            let host = NSHostingController(rootView: tab.view(updater: updater, permissions: permissions))
            host.sizingOptions = [.preferredContentSize]
            host.title = tab.rawValue
            let item = NSTabViewItem(viewController: host)
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil)
            item.identifier = tab.rawValue
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func select(_ tab: SettingsTab) {
        tabs.selectedTabViewItemIndex = SettingsTab.allCases.firstIndex(of: tab) ?? 0
    }
}
