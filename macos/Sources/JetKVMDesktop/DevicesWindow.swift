import AppKit
import JetKVMCore
import SwiftUI

/// The device library: saved JetKVMs with their addresses (LAN, mDNS, VPN)
/// and per-device preferences; passwords live in the Keychain.
final class DevicesModel: ObservableObject {
    @Published private(set) var devices: [Device] = []
    let store: DeviceStore
    var onConnect: (Device) -> Void = { _ in }
    /// A device was edited and saved (open windows take the preferences).
    var onSaved: (Device) -> Void = { _ in }

    init(store: DeviceStore) {
        self.store = store
        reload()
    }

    func reload() {
        devices = store.devices.sorted { ($0.lastConnected ?? .distantPast) > ($1.lastConnected ?? .distantPast) }
    }

    func save(_ device: Device, password: String?) {
        var device = device
        // The editor's copy may predate a device ID learned meanwhile.
        if device.deviceID == nil, let saved = store.device(id: device.id) {
            device.deviceID = saved.deviceID
        }
        store.upsert(device)
        try? store.save()
        onSaved(store.device(id: device.id) ?? device)
        if let password, !password.isEmpty {
            Keychain.setPassword(password, account: device.credentialAccount)
        }
        reload()
    }

    func delete(_ device: Device) {
        store.remove(id: device.id)
        try? store.save()
        // Another entry for the same device shares the Keychain item.
        if !store.devices.contains(where: { $0.credentialAccount == device.credentialAccount }) {
            Keychain.deletePassword(account: device.credentialAccount)
        }
        reload()
    }
}

struct DevicesView: View {
    @ObservedObject var model: DevicesModel
    @State private var selection: String?
    @State private var editing: Device?
    @State private var isNew = false

    var body: some View {
        VStack(spacing: 0) {
            if model.devices.isEmpty {
                VStack(spacing: 8) {
                    Text("No devices yet").font(.headline)
                    Text("Add a JetKVM by its IP address, .local name or VPN hostname.")
                        .foregroundStyle(.secondary)
                    Button("Add Device…") { add() }.keyboardShortcut(.defaultAction)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.devices, selection: $selection) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name).font(.body.weight(.medium))
                            Text(device.addresses.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let last = device.lastConnected {
                            Text(last, style: .relative).font(.caption).foregroundStyle(.tertiary)
                        }
                        Button("Connect") { model.onConnect(device) }
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button("Connect") { model.onConnect(device) }
                        Button("Edit…") { edit(device) }
                        Divider()
                        Button("Remove", role: .destructive) { model.delete(device) }
                    }
                    .tag(device.id)
                }
            }
            Divider()
            HStack {
                Button { add() } label: { Image(systemName: "plus") }
                Button { if let d = selectedDevice { model.delete(d) } } label: { Image(systemName: "minus") }
                    .disabled(selectedDevice == nil)
                Button("Edit…") { if let d = selectedDevice { edit(d) } }.disabled(selectedDevice == nil)
                Spacer()
                Button("Connect") { if let d = selectedDevice { model.onConnect(d) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedDevice == nil)
            }
            .padding(8)
        }
        .frame(minWidth: 460, minHeight: 280)
        .sheet(item: $editing) { device in
            DeviceEditor(device: device, isNew: isNew) { updated, password in
                model.save(updated, password: password)
                editing = nil
            } cancel: {
                editing = nil
            }
        }
    }

    private var selectedDevice: Device? {
        model.devices.first { $0.id == selection }
    }

    private func add() {
        isNew = true
        editing = Device(name: "", addresses: [])
    }

    private func edit(_ device: Device) {
        isNew = false
        editing = device
    }
}

struct DeviceEditor: View {
    @State var device: Device
    let isNew: Bool
    let done: (Device, String?) -> Void
    let cancel: () -> Void
    @State private var addressText = ""
    @State private var password = ""

    init(device: Device, isNew: Bool, done: @escaping (Device, String?) -> Void, cancel: @escaping () -> Void) {
        _device = State(initialValue: device)
        self.isNew = isNew
        self.done = done
        self.cancel = cancel
        _addressText = State(initialValue: device.addresses.joined(separator: ", "))
    }

    var body: some View {
        Form {
            TextField("Name", text: $device.name, prompt: Text("Office server"))
            TextField("Addresses", text: $addressText, prompt: Text("192.168.1.50, jetkvm.local, kvm.tailnet.ts.net"))
            Text("Tried in order. Any address that reaches the device works: LAN, mDNS, Tailscale or any other VPN.")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("Password", text: $password, prompt: Text(isNew ? "Leave empty if none" : "Unchanged"))
            Picker("Remote computer", selection: $device.modifierProfile) {
                Text("Mac (⌘ stays ⌘)").tag(ModifierProfile.mac.rawValue)
                Text("Linux / Windows (⌘ ↔ Ctrl)").tag(ModifierProfile.pc.rawValue)
            }
            Picker("Display", selection: $device.scaling) {
                ForEach(ScalingMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Adapt stream quality to the network", isOn: $device.adaptiveQuality)
            Toggle("Invert scrolling", isOn: $device.invertScroll)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    device.addresses = Device.parseAddresses(addressText)
                    if device.name.isEmpty { device.name = device.addresses.first ?? "JetKVM" }
                    done(device, password.isEmpty ? nil : password)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(Device.parseAddresses(addressText).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

final class DevicesWindowController: NSWindowController {
    let model: DevicesModel

    init(model: DevicesModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "JetKVM Devices"
        window.contentView = NSHostingView(rootView: DevicesView(model: model))
        window.setFrameAutosaveName("JetKVMDevices")
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

extension ScalingMode {
    /// Device library picker.
    var title: String {
        switch self {
        case .matchWindow: return "Match Window (changes the remote's resolution; for single-display computers)"
        case .actualSize: return "Actual Size (same size as on the remote)"
        default: return menuTitle
        }
    }

    /// View menu.
    var menuTitle: String {
        switch self {
        case .matchWindow: return "Match Window"
        case .actualSize: return "Actual Size"
        case .fit: return "Scale to Fit Window"
        case .pixelExact: return "Pixel for Pixel"
        case .integer: return "Largest Whole Multiple"
        }
    }

    /// Status bar popup.
    var shortTitle: String {
        switch self {
        case .fit: return "Fit"
        case .integer: return "Whole Multiple"
        default: return menuTitle
        }
    }
}
