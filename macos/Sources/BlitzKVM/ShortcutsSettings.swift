import AppKit
import Carbon.HIToolbox
import JetKVMCore
import SwiftUI

/// Settings › Shortcuts: the shortcuts that stay on this Mac, a recorder, and
/// whether what apps paste into the window goes to the remote computer.
struct ShortcutsSettings: View {
    @ObservedObject var store: LocalShortcuts
    @State private var recorder = ShortcutRecorder()

    var body: some View {
        Section {
            ForEach(store.shortcuts) { shortcut in
                LabeledContent {
                    Button("Remove") { store.remove(shortcut) }
                } label: {
                    KeyCaps(keys: shortcut.keys)
                        .accessibilityLabel(shortcut.title)
                }
            }
            LabeledContent {
                Button(recorder.isRecording ? "Cancel" : "Record Shortcut") {
                    if recorder.isRecording {
                        recorder.stop()
                    } else {
                        recorder.start { store.add($0) }
                    }
                }
            } label: {
                Text(recorder.isRecording ? recorder.prompt : store.shortcuts.isEmpty ? "No shortcuts yet" : "Add another")
                    .foregroundStyle(recorder.isRecording ? .primary : .secondary)
                    .contentTransition(.opacity)
            }
        } header: {
            Text("Shortcuts for This Mac")
        } footer: {
            SettingsFooter("While a window has the keyboard, these stay on this Mac instead of going to the remote computer, like ⌥ fn for a dictation app.")
        }
        .animation(.snappy(duration: 0.2), value: store.shortcuts)
        .animation(.snappy(duration: 0.2), value: recorder.prompt)
        .onDisappear { recorder.stop() }

        Section {
            Toggle(isOn: $store.pastesFromApps) {
                Text("Send what apps paste to the remote computer")
                Text("A dictation app's text lands there, not the remote's own clipboard.")
            }
        } header: {
            Text("Pasting")
        } footer: {
            SettingsFooter("With clipboard sync on, it arrives exactly as pasted; otherwise BlitzKVM types it.")
        }
    }
}

/// A shortcut's keys as key caps: ⌥ fn.
struct KeyCaps: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.callout.weight(.medium))
                    .frame(minWidth: 16)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
    }
}

/// Records one shortcut: a key with modifiers (or a function key), or
/// modifiers alone (pressed together, then released). Escape cancels.
@Observable
final class ShortcutRecorder {
    private(set) var isRecording = false
    private(set) var prompt = ""
    private var monitor: Any?
    private var held: UInt64 = 0
    private var done: ((LocalShortcut) -> Void)?

    private static let waiting = "Press the shortcut"

    func start(_ done: @escaping (LocalShortcut) -> Void) {
        stop()
        self.done = done
        isRecording = true
        held = 0
        prompt = Self.waiting
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handle(event)
            return nil // nothing else sees keys while recording
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        done = nil
    }

    private func handle(_ event: NSEvent) {
        let flags = UInt64(event.modifierFlags.rawValue) & LocalShortcut.flagsMask
        switch event.type {
        case .keyDown:
            if event.keyCode == UInt16(kVK_Escape) && flags == 0 { return stop() }
            // A key alone would stop typing it on the remote: it needs a
            // modifier (function keys carry fn).
            guard flags != 0 else {
                prompt = "Hold a modifier with the key, like ⌥ or fn"
                return
            }
            finish(LocalShortcut(keyCode: event.keyCode, modifiers: flags, keyLabel: Self.label(event)))
        case .flagsChanged:
            held |= flags
            if flags != 0 {
                prompt = LocalShortcut(keyCode: nil, modifiers: held).title
                return
            }
            // Released: modifiers alone count when they are two or more,
            // or fn (one alone would stay off the remote for good).
            let count = held.nonzeroBitCount
            if count >= 2 || held == LocalShortcut.function {
                finish(LocalShortcut(keyCode: nil, modifiers: held))
            } else if held != 0 {
                prompt = "Two modifiers at least, like ⌥ fn"
            }
            held = 0
        default:
            break
        }
    }

    private func finish(_ shortcut: LocalShortcut) {
        let done = done
        stop()
        done?(shortcut)
    }

    private static let names: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Delete: "Delete", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "Home", kVK_End: "End",
        kVK_PageUp: "Page Up", kVK_PageDown: "Page Down", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11",
        kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static func label(_ event: NSEvent) -> String {
        if let name = names[Int(event.keyCode)] { return name }
        return event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
    }
}
