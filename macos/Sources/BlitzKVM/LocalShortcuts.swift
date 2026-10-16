import AppKit
import Combine
import JetKVMCore

/// Settings › Shortcuts: key combinations that stay on this Mac
/// while a window controls the remote computer, and whether what another
/// app pastes into the window (dictation) goes to the remote computer.
@MainActor
final class LocalShortcuts: ObservableObject {
    static let shared = LocalShortcuts()

    private static let shortcutsKey = "localShortcuts"
    private static let pastesFromAppsKey = "pastesFromAppsToRemote"

    @Published private(set) var shortcuts: [LocalShortcut]
    @Published var pastesFromApps: Bool {
        didSet { UserDefaults.standard.set(pastesFromApps, forKey: Self.pastesFromAppsKey) }
    }

    private init() {
        let data = UserDefaults.standard.data(forKey: Self.shortcutsKey)
        shortcuts = data.flatMap { try? JSONDecoder().decode([LocalShortcut].self, from: $0) } ?? []
        pastesFromApps = UserDefaults.standard.object(forKey: Self.pastesFromAppsKey) as? Bool ?? true
    }

    func add(_ shortcut: LocalShortcut) {
        guard !shortcuts.contains(where: { $0.id == shortcut.id }) else { return }
        shortcuts.append(shortcut)
        save()
    }

    func remove(_ shortcut: LocalShortcut) {
        shortcuts.removeAll { $0.id == shortcut.id }
        save()
    }

    func setKeepsControl(_ on: Bool, for shortcut: LocalShortcut) {
        guard let index = shortcuts.firstIndex(where: { $0.id == shortcut.id }) else { return }
        shortcuts[index].keepsControl = on
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(shortcuts), forKey: Self.shortcutsKey)
    }
}
