import AppKit
import JetKVMCore
import SwiftUI

/// The device library: saved JetKVMs with their addresses (LAN, mDNS, VPN)
/// and per-device preferences; passwords live in the Keychain.
final class DevicesModel: ObservableObject {
    @Published private(set) var devices: [Device] = []
    /// Devices with an open window (connected, or still connecting there).
    @Published var openDeviceIDs: Set<String> = []
    /// Devices whose address probe is running (no window yet).
    @Published var probingDeviceIDs: Set<String> = []
    let store: DeviceStore
    var onConnect: (Device) -> Void = { _ in }
    /// Connects and opens the JetKVM Setup sheet.
    var onSetUp: (Device) -> Void = { _ in }
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

/// Saved JetKVMs as a gallery of screens. A screen lights up while its device
/// answers on the network, and screens grow to fill the window, so one device
/// is a centered hero and many become a scrolling grid.
struct DevicesView: View {
    @ObservedObject var model: DevicesModel
    @State private var selection: Device.ID?
    @State private var editing: DeviceEdit?
    /// The device last asked about; kept while the dialog animates out.
    @State private var removal: Device?
    @State private var isConfirmingRemoval = false
    /// Probe results; the app's own state (connecting, open) wins over them.
    @State private var reachability: [Device.ID: DeviceState] = [:]
    @State private var isVisible = false

    var body: some View {
        Group {
            if model.devices.isEmpty {
                EmptyLibrary(add: add)
            } else {
                DeviceGallery(devices: model.devices, selection: $selection, status: status(of:),
                              connect: model.onConnect, edit: edit, setUp: model.onSetUp, remove: confirmRemoval)
            }
        }
        .frame(minWidth: 460, minHeight: 340)
        .navigationTitle("Devices")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: add) { Label("Add Device", systemImage: "plus") }
                    .help("Add a JetKVM")
            }
        }
        .sheet(item: $editing) { edit in
            DeviceEditor(device: edit.device, isNew: edit.isNew) { device, password in
                model.save(device, password: password)
                selection = device.id
                editing = nil
            } cancel: {
                editing = nil
            }
        }
        .confirmationDialog("Remove “\(removal?.name ?? "")”?", isPresented: $isConfirmingRemoval, presenting: removal) { device in
            Button("Remove", role: .destructive) { model.delete(device) }
        } message: { _ in
            Text("Its addresses, settings, and saved password are removed from this Mac.")
        }
        .background(WindowVisibility { isVisible = $0 })
        .task(id: isVisible ? model.devices : nil) { await monitorReachability() }
        .environment(\.locale, .englishInUserRegion)
    }

    private func status(of device: Device) -> DeviceState {
        if model.probingDeviceIDs.contains(device.id) { return .connecting }
        if model.openDeviceIDs.contains(device.id) { return .open }
        return reachability[device.id] ?? .checking
    }

    private func add() {
        editing = DeviceEdit(device: Device(name: "", addresses: []), isNew: true)
    }

    private func edit(_ device: Device) {
        editing = DeviceEdit(device: device, isNew: false)
    }

    private func confirmRemoval(_ device: Device) {
        removal = device
        isConfirmingRemoval = true
    }

    /// Probes every device now and every 30 s while the window is on screen.
    /// Devices with a window are skipped: that window shows their state.
    private func monitorReachability() async {
        guard isVisible else { return }
        while !Task.isCancelled {
            let devices = model.devices.filter { !model.openDeviceIDs.contains($0.id) }
            await withTaskGroup(of: (Device.ID, DeviceState).self) { group in
                for device in devices {
                    group.addTask { (device.id, await DeviceState.probe(device)) }
                }
                for await (id, status) in group { reachability[id] = status }
            }
            try? await Task.sleep(for: .seconds(30))
        }
    }
}

// MARK: - State

private struct DeviceEdit: Identifiable {
    var device: Device
    var isNew: Bool
    var id: Device.ID { device.id }
}

private enum DeviceState: Equatable {
    /// No probe answer yet.
    case checking
    case online(address: String)
    case offline
    /// Another JetKVM answers at the device's address.
    case otherDevice
    /// Connect is probing the addresses (no window yet).
    case connecting
    /// The device has a window.
    case open

    /// Who answers at the device's addresses: the HTTP probe Connect uses
    /// (GET /device), which never opens a session that would take over another.
    static func probe(_ device: Device) async -> DeviceState {
        switch await AddressProbe.choose(addresses: device.addresses, expectedDeviceID: device.deviceID,
                                         fetch: AddressProbe.httpFetch(certSHA256: device.certificateSHA256)) {
        case .success(let answer): return .online(address: answer.address)
        case .failure(.identityMismatch): return .otherDevice
        case .failure(.unreachable): return .offline
        }
    }

    var title: String {
        switch self {
        case .checking: return "Checking…"
        case .online: return "Online"
        case .offline: return "Offline"
        case .otherDevice: return "Wrong Device"
        case .connecting: return "Connecting…"
        case .open: return "Open"
        }
    }

    var detail: String {
        switch self {
        case .checking: return "Looking for the device on the network."
        case .online(let address): return "Answering at \(address)."
        case .offline: return "None of its addresses answered. Connect keeps trying in a window."
        case .otherDevice: return "Another JetKVM answers at its address. No password is sent to it."
        case .connecting: return "Finding the address that answers."
        case .open: return "Open in a window."
        }
    }

    var color: Color {
        switch self {
        case .checking, .offline: return .secondary
        case .online: return .green
        case .otherDevice: return .orange
        case .connecting, .open: return .accentColor
        }
    }

    /// The screen glows while the device answers.
    var isLit: Bool {
        switch self {
        case .online, .connecting, .open: return true
        case .checking, .offline, .otherDevice: return false
        }
    }

    /// Connect brings an open device's window to the front.
    var connectTitle: String { self == .open ? "Show" : "Connect" }
}

// MARK: - Gallery

/// Screens as large as the window allows: the column count giving the
/// largest screens wins (then the one leaving the fewest empty cells);
/// below the minimum size the grid scrolls instead.
private struct GalleryMetrics {
    static let spacing: CGFloat = 28
    static let aspect: CGFloat = 16 / 10
    /// Room for the selection ring around a screen.
    static let ringInset: CGFloat = 4
    /// The gap below a screen, plus name, addresses and last use.
    static let captionHeight: CGFloat = 68
    static let screenWidths: ClosedRange<CGFloat> = 160...400

    let columns: Int
    let screenWidth: CGFloat
    var tileWidth: CGFloat { screenWidth + 2 * Self.ringInset }

    init(count: Int, in size: CGSize) {
        let s = Self.spacing, chrome = 2 * Self.ringInset
        func widthLimit(_ columns: Int) -> CGFloat {
            (size.width - s * CGFloat(columns - 1)) / CGFloat(columns) - chrome
        }
        let fits = (1...max(count, 1)).map { columns in
            let rows = (count + columns - 1) / columns
            let heightLimit = ((size.height - s * CGFloat(rows - 1)) / CGFloat(rows) - chrome - Self.captionHeight) * Self.aspect
            return (width: min(widthLimit(columns), heightLimit, Self.screenWidths.upperBound), empty: rows * columns - count, columns: columns)
        }
        let best = fits.max { ($0.width, -$0.empty, $0.columns) < ($1.width, -$1.empty, $1.columns) }!
        if best.width >= Self.screenWidths.lowerBound {
            (columns, screenWidth) = (best.columns, best.width)
        } else {
            columns = max(1, min(count, Int((size.width + s) / (Self.screenWidths.lowerBound + chrome + s))))
            screenWidth = min(max(widthLimit(columns), Self.screenWidths.lowerBound), Self.screenWidths.upperBound)
        }
    }
}

/// Keyboard: arrows move the selection, Return connects, Delete removes.
/// Mouse: a click connects, the context menu has all.
private struct DeviceGallery: View {
    let devices: [Device]
    @Binding var selection: Device.ID?
    let status: (Device) -> DeviceState
    let connect: (Device) -> Void
    let edit: (Device) -> Void
    let setUp: (Device) -> Void
    let remove: (Device) -> Void
    @FocusState private var isFocused: Bool
    @State private var size = CGSize.zero

    private static let padding = EdgeInsets(top: 20, leading: 32, bottom: 28, trailing: 32)

    var body: some View {
        let metrics = GalleryMetrics(count: devices.count, in: CGSize(
            width: size.width - Self.padding.leading - Self.padding.trailing,
            height: size.height - Self.padding.top - Self.padding.bottom))
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(metrics.tileWidth), spacing: GalleryMetrics.spacing, alignment: .top),
                                         count: metrics.columns),
                          spacing: GalleryMetrics.spacing) {
                    ForEach(devices) { device in
                        tile(device, screenWidth: metrics.screenWidth)
                    }
                }
                .padding(Self.padding)
                // Centered while it fits; scrolls from the top once it doesn't.
                .frame(maxWidth: .infinity, minHeight: size.height)
            }
            .onChange(of: selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onMoveCommand { move($0, columns: metrics.columns) }
        .onKeyPress(.return) { perform(connect) }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in perform(remove) }
        .onAppear {
            isFocused = true
            selectFirstIfNeeded()
        }
        .onChange(of: devices) { selectFirstIfNeeded() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Devices")
    }

    private func tile(_ device: Device, screenWidth: CGFloat) -> some View {
        let status = self.status(device)
        return DeviceTile(device: device, status: status, screenWidth: screenWidth,
                          isSelected: selection == device.id, isFocused: isFocused) {
            connect(device)
        } setUp: {
            setUp(device)
        }
        .onTapGesture { connect(device) }
        .contextMenu {
            Button(status.connectTitle) { connect(device) }
            Button("Edit…") { edit(device) }
            Button("Set Up JetKVM…") { setUp(device) }
            Divider()
            Button("Remove…", role: .destructive) { remove(device) }
        }
        .accessibilityAction(named: "Edit") { edit(device) }
        .accessibilityAction(named: "Set Up JetKVM") { setUp(device) }
        .accessibilityAction(named: "Remove") { remove(device) }
    }

    private var selected: Device? { devices.first { $0.id == selection } }

    private func perform(_ action: (Device) -> Void) -> KeyPress.Result {
        guard let selected else { return .ignored }
        action(selected)
        return .handled
    }

    /// The most recently used device starts selected, so Return connects it.
    private func selectFirstIfNeeded() {
        if selected == nil { selection = devices.first?.id }
    }

    private func move(_ direction: MoveCommandDirection, columns: Int) {
        guard let index = devices.firstIndex(where: { $0.id == selection }) else { return selectFirstIfNeeded() }
        let step: Int
        switch direction {
        case .left: step = -1
        case .right: step = 1
        case .up: step = -columns
        case .down: step = columns
        @unknown default: return
        }
        if devices.indices.contains(index + step) { selection = devices[index + step].id }
    }
}

// MARK: - Tile

private struct DeviceTile: View {
    let device: Device
    let status: DeviceState
    let screenWidth: CGFloat
    let isSelected: Bool
    let isFocused: Bool
    let connect: () -> Void
    let setUp: () -> Void
    @State private var isHovered = false
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale

    var body: some View {
        let inset = GalleryMetrics.ringInset
        let radius = (screenWidth * 0.06).rounded()
        VStack(spacing: 12) {
            DeviceScreen(status: status, width: screenWidth, radius: radius)
                .overlay(alignment: .topTrailing) {
                    SetupBadge(summary: device.setup, open: setUp)
                        .padding((screenWidth * 0.045).rounded())
                }
                .overlay(alignment: .bottom) {
                    if (isHovered || isSelected) && status != .connecting {
                        Button(status.connectTitle, action: connect)
                            .prominentButtonStyle()
                            .environment(\.colorScheme, .dark)
                            .padding(.bottom, radius)
                            .transition(.opacity)
                    }
                }
                .padding(inset)
                .overlay {
                    RoundedRectangle(cornerRadius: radius + inset, style: .continuous)
                        .strokeBorder(ringColor, lineWidth: 3)
                        .opacity(isSelected ? 1 : 0)
                }
                .scaleEffect(isHovered && !reduceMotion ? 1.015 : 1)
            VStack(spacing: 3) {
                Text(device.name)
                    .font(.headline)
                AddressSummary(addresses: device.addresses)
                    .foregroundStyle(.secondary)
                TimelineView(.everyMinute) { context in
                    Text(lastUsed(now: context.date))
                }
                .foregroundStyle(.tertiary)
            }
            .font(.callout)
            .lineLimit(1)
            .frame(width: screenWidth)
        }
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .linkPointer()
        .animation(.snappy(duration: 0.2), value: isHovered)
        .animation(.snappy(duration: 0.2), value: isSelected)
        .help(device.addresses.joined(separator: ", "))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(device.name)
        .accessibilityValue("\(status.title), \(lastUsed(now: .now)), \(device.addresses.joined(separator: ", "))")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, connect)
    }

    /// The accent color while the gallery has focus in the key window, gray
    /// otherwise (as in Finder).
    private var ringColor: Color {
        isFocused && activeState == .key ? .accentColor : Color.secondary.opacity(0.5)
    }

    private func lastUsed(now: Date) -> String {
        guard let date = device.lastConnected else { return "Never connected" }
        if now.timeIntervalSince(date) < 60 { return "Connected just now" }
        return "Connected \(date.formatted(.relative(presentation: .named).locale(locale)))"
    }
}

/// All addresses when they fit, else the first and how many more.
private struct AddressSummary: View {
    let addresses: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(addresses.joined(separator: " · "))
            if let first = addresses.first {
                Text(addresses.count > 1 ? "\(first) + \(addresses.count - 1) more" : first)
                    .truncationMode(.middle)
            }
        }
    }
}

/// A display showing the device's state: lit with the app icon's warm glow
/// while the device answers, dark while it doesn't. Dark in both
/// appearances, like a real screen.
private struct DeviceScreen: View {
    let status: DeviceState
    let width: CGFloat
    let radius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    private static let amber = Color(red: 1, green: 0.76, blue: 0.2)
    private static let ember = Color(red: 0.98, green: 0.52, blue: 0.08)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let lit = status.isLit
        ZStack {
            LinearGradient(colors: [Color(white: 0.16), Color(white: 0.05)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Self.ember.opacity(0.42), .clear], center: UnitPoint(x: 0.5, y: 0.6),
                           startRadius: 0, endRadius: width * 0.5)
                .opacity(lit ? 1 : 0)
            // Sheen, as on a glass panel.
            LinearGradient(colors: [.white.opacity(0.07), .clear], startPoint: .topLeading, endPoint: UnitPoint(x: 0.55, y: 0.6))
            ZStack {
                cursor.foregroundStyle(Color(white: 0.3))
                cursor.foregroundStyle(LinearGradient(colors: [Self.amber, Self.ember], startPoint: .top, endPoint: .bottom))
                    .shadow(color: Self.ember.opacity(0.7), radius: width * 0.05)
                    .opacity(lit ? 1 : 0)
            }
            .offset(x: width * 0.01, y: -width * 0.02)
        }
        .overlay(alignment: .topLeading) {
            if status != .checking {
                StatusBadge(status: status)
                    .padding((width * 0.045).rounded())
                    .transition(.opacity)
            }
        }
        .frame(width: width, height: (width / GalleryMetrics.aspect).rounded())
        .clipShape(shape)
        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(edgeOpacity), .white.opacity(edgeOpacity / 4)],
                                                   startPoint: .top, endPoint: .bottom), lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        .animation(.easeOut(duration: 0.5), value: status)
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
    }

    private var edgeOpacity: Double { contrast == .increased ? 0.6 : 0.2 }

    private var cursor: some View {
        Image(systemName: "cursorarrow").font(.system(size: width * 0.17))
    }
}

/// JetKVM Setup's progress on the screen: a dot per step (firmware,
/// password, Tailscale) and "Setup", or "Set Up" before the first check. A click opens
/// the sheet (connecting first).
private struct SetupBadge: View {
    let summary: SetupSummary?
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 5) {
                ring
                Text(summary == nil ? "Set Up" : "Setup")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.white.opacity(isHovered ? 0.18 : 0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .linkPointer()
        .animation(.snappy(duration: 0.15), value: isHovered)
        .help(help)
        .accessibilityLabel(summary.map { "Setup, \($0.done) of \(SetupSummary.steps) done" } ?? "Set up")
    }

    /// One dot per step: filled when done, all green once complete.
    private var ring: some View {
        HStack(spacing: 2) {
            ForEach(0..<SetupSummary.steps, id: \.self) { step in
                let done = step < (summary?.done ?? 0)
                Circle()
                    .fill(done ? (summary?.isComplete == true ? Color.green : .white) : .white.opacity(0.25))
                    .frame(width: 5, height: 5)
            }
        }
        .accessibilityHidden(true)
    }

    private var help: String {
        guard let summary else { return "Check the firmware, password and Tailscale" }
        func state(_ value: Bool?, _ yes: String, _ no: String) -> String { value.map { $0 ? yes : no } ?? "not checked" }
        return ["Firmware: " + state(summary.firmwareUpToDate, "up to date", "not BlitzKVM's latest"),
                "Password: " + state(summary.passwordSet, "set", "off"),
                "Tailscale: " + state(summary.tailscaleConnected, "connected", "not set up")].joined(separator: "\n")
    }
}

private struct StatusBadge: View {
    let status: DeviceState

    var body: some View {
        HStack(spacing: 5) {
            if status == .connecting {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(status.color).frame(width: 7, height: 7)
            }
            Text(status.title)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.white.opacity(0.1), in: Capsule())
        .help(status.detail)
    }
}

// MARK: - Empty state

private struct EmptyLibrary: View {
    let add: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .accessibilityHidden(true)
            Text("Add Your First JetKVM")
                .font(.title2.weight(.semibold))
                .padding(.top, 14)
            Text("Control the computer it’s plugged into, right from this Mac.\nAll you need is its IP address, .local name, or VPN hostname.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
            Button("Add Device…", action: add)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .prominentButtonStyle()
                .padding(.top, 22)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Editor

/// Add or edit a device, as a grouped form.
private struct DeviceEditor: View {
    @State private var device: Device
    @State private var addressText: String
    @State private var password = ""
    private let title: String
    let isNew: Bool
    let done: (Device, String?) -> Void
    let cancel: () -> Void

    init(device: Device, isNew: Bool, done: @escaping (Device, String?) -> Void, cancel: @escaping () -> Void) {
        _device = State(initialValue: device)
        _addressText = State(initialValue: device.addresses.joined(separator: ", "))
        title = isNew ? "Add a JetKVM" : device.name
        self.isNew = isNew
        self.done = done
        self.cancel = cancel
    }

    private var addresses: [String] { Device.parseAddresses(addressText) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(isNew ? "Saved on this Mac, with the password in your Keychain."
                               : "Changes apply to an open window right away.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding([.horizontal, .top], 20)
            Form {
                Section {
                    TextField("Name", text: $device.name, prompt: Text("Office Server"))
                    TextField("Addresses", text: $addressText, prompt: Text("192.168.1.50, jetkvm.local"))
                    SecureField("Password", text: $password, prompt: Text(isNew ? "None" : "Unchanged"))
                } footer: {
                    Footnote("Separate several addresses with commas; they’re tried in order. LAN IPs, .local names, and Tailscale or other VPN hostnames all work.")
                }
                Section {
                    Picker("Operating system", selection: $device.modifierProfile) {
                        Text("macOS").tag(ModifierProfile.mac.rawValue)
                        Text("Windows or Linux").tag(ModifierProfile.pc.rawValue)
                    }
                    Picker("Display", selection: $device.scaling) {
                        ForEach(ScalingMode.allCases, id: \.self) { Text($0.menuTitle).tag($0) }
                    }
                    Toggle("Invert scrolling", isOn: $device.invertScroll)
                    Toggle("Adapt stream quality to the network", isOn: $device.adaptiveQuality)
                } header: {
                    Text("Remote Computer")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if device.profile == .pc {
                            Footnote("⌘ and Control are swapped, so ⌘C sends Ctrl+C.")
                        }
                        if device.scaling == .matchWindow {
                            Footnote("Match Window changes the remote computer’s resolution with every resize. A Mac with another monitor then stops using the JetKVM as its main display, so use it when the JetKVM is the only display.")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    device.addresses = addresses
                    if device.name.isEmpty { device.name = device.addresses.first ?? "JetKVM" }
                    done(device, password.isEmpty ? nil : password)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(addresses.isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Footnote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Helpers

/// Reports whether the window is on screen (not closed, minimized or fully
/// covered), so the reachability probe pauses while nobody sees it.
private struct WindowVisibility: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> Observer { Observer(onChange: onChange) }
    func updateNSView(_ view: Observer, context: Context) {}

    final class Observer: NSView {
        private let onChange: (Bool) -> Void
        private var token: NSObjectProtocol?

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        deinit {
            token.map(NotificationCenter.default.removeObserver)
        }

        override func viewDidMoveToWindow() {
            token.map(NotificationCenter.default.removeObserver)
            token = window.map {
                NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: $0, queue: .main) { [weak self] _ in
                    self?.report()
                }
            }
            report()
        }

        private func report() {
            onChange(window?.occlusionState.contains(.visible) == true)
        }
    }
}

private extension View {
    /// The pointing hand: a click opens what is under it.
    @ViewBuilder func linkPointer() -> some View {
        if #available(macOS 15, *) {
            pointerStyle(.link)
        } else {
            onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
        }
    }

    /// Liquid Glass on macOS 26, the bordered equivalent before.
    @ViewBuilder func prominentButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}

extension Locale {
    /// English, the app's language, in the user's region: "4 hours ago" in
    /// the English UI, while dates keep the local conventions.
    static let englishInUserRegion = Locale(languageCode: .english, languageRegion: Locale.current.region)
}

/// The Devices window's content: the welcome screen while permissions are
/// missing (first launch, Local Network turned off; Settings shows them later),
/// the devices otherwise.
struct DevicesRootView: View {
    @ObservedObject var model: DevicesModel
    @ObservedObject var permissions: PermissionsModel

    var body: some View {
        Group {
            if permissions.showsOnboarding {
                OnboardingView(permissions: permissions)
                    .transition(.opacity)
            } else {
                DevicesView(model: model)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.3), value: permissions.showsOnboarding)
    }
}

final class DevicesWindowController: NSWindowController {
    let model: DevicesModel

    init(model: DevicesModel, permissions: PermissionsModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        let host = NSHostingView(rootView: DevicesRootView(model: model, permissions: permissions))
        // The view's toolbar (Liquid Glass on macOS 26) shares its state; the
        // user sizes the window, the content only sets its minimum.
        host.sceneBridgingOptions = [.toolbars, .title]
        host.sizingOptions = [.minSize]
        window.contentView = host
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.setFrameAutosaveName("DevicesWindow")
        window.setFrameUsingName("DevicesWindow") // none on first launch: the default size
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

extension ScalingMode {
    /// View menu, device editor.
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
