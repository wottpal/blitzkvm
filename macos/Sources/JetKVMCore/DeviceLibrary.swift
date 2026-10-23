import Foundation

/// A saved JetKVM. Addresses are tried in order (e.g. LAN IP, mDNS name,
/// VPN/MagicDNS name); the JetKVM `deviceId` pins the identity so a stored
/// password is only ever sent to the device it belongs to.
public struct Device: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var addresses: [String]
    /// The device's own ID, learned on first connect (GET /device, or over
    /// RPC after login on password-protected devices).
    public var deviceID: String?
    /// For https addresses: the pinned device certificate authority
    /// (SHA-256 hex), learned on first connect.
    public var certificateSHA256: String?
    public var modifierProfile: String
    /// ScalingMode; nil means the default. (Replaces the earlier
    /// "scalingMode" key, whose default was a fit that made text small.)
    public var viewMode: String?
    /// Nearest-neighbor at whole-number scales instead of FSR upscaling.
    public var exactPixelScaling: Bool?
    /// Match Window: window points per remote pixel; nil means 1.
    public var matchWindowScale: Double?
    /// Match Window: the remote display's refresh rate (Hz); nil picks the
    /// largest picture and then the highest rate (RemoteDisplay.mode).
    public var matchWindowRefresh: Int?
    /// Stream quality follows the network; nil means on.
    public var autoQuality: Bool?
    /// The fixed quality level used while automatic quality is off.
    public var qualityLevel: String?
    public var invertScroll: Bool
    /// Game Mode: the mouse goes out as raw relative moves under a pointer
    /// lock while captured; nil means off.
    public var gameMode: Bool?
    public var lastConnected: Date?
    /// The last JetKVM Setup check, shown in the Devices window.
    public var setup: SetupSummary?
    /// Clipboard sync with the remote Mac, once set up (JetKVM Setup).
    public var clipboardSync: ClipboardSync?

    public init(id: String = UUID().uuidString, name: String, addresses: [String], deviceID: String? = nil,
                modifierProfile: ModifierProfile = .mac, scaling: ScalingMode = .actualSize,
                invertScroll: Bool = false, lastConnected: Date? = nil) {
        self.id = id
        self.name = name
        self.addresses = addresses
        self.deviceID = deviceID
        self.modifierProfile = modifierProfile.rawValue
        self.viewMode = scaling.rawValue
        self.invertScroll = invertScroll
        self.lastConnected = lastConnected
    }

    public var profile: ModifierProfile { ModifierProfile(rawValue: modifierProfile) ?? .mac }

    public var scaling: ScalingMode {
        get { viewMode.flatMap(ScalingMode.init(rawValue:)) ?? .actualSize }
        set { viewMode = newValue.rawValue }
    }

    public var exactPixels: Bool {
        get { exactPixelScaling ?? false }
        set { exactPixelScaling = newValue }
    }

    /// Match Window: how large the remote desktop looks, as window points
    /// per remote pixel. 1 matches a local window; 2 doubles everything (half
    /// the remote resolution); 0.5 halves it (twice the resolution, up to the
    /// device's limits).
    public var matchScale: Double {
        get { matchWindowScale.flatMap { $0 > 0 ? $0 : nil } ?? 1 }
        set { matchWindowScale = newValue == 1 ? nil : newValue }
    }

    /// The Match Window scales offered in menus, largest text first.
    public static let matchScales: [Double] = [2, 1.5, 1.25, 1, 0.8, 0.67, 0.5]

    public var isGameMode: Bool {
        get { gameMode ?? false }
        set { gameMode = newValue ? true : nil }
    }

    public var adaptiveQuality: Bool {
        get { autoQuality ?? true }
        set { autoQuality = newValue }
    }

    /// Key under which the password is stored: the device ID when known
    /// (the secret follows the device across address changes), otherwise
    /// this entry's stable local ID.
    public var credentialAccount: String { deviceID ?? id }

    /// Splits "a, b c" into a clean address list.
    public static func parseAddresses(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Persists the device list as JSON (Application Support).
public final class DeviceStore {
    public let url: URL
    public private(set) var devices: [Device] = []

    public init(url: URL) {
        self.url = url
        load()
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("BlitzKVM", isDirectory: true).appendingPathComponent("devices.json")
    }

    public func load() {
        guard let data = try? Data(contentsOf: url) else { devices = []; return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            devices = try decoder.decode([Device].self, from: data)
        } catch {
            // Never let the next save() overwrite a file we could not read:
            // keep it aside for recovery.
            let backup = url.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: backup)
            devices = []
        }
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(devices).write(to: url, options: .atomic)
    }

    public func upsert(_ device: Device) {
        if let i = devices.firstIndex(where: { $0.id == device.id }) {
            devices[i] = device
        } else {
            devices.append(device)
        }
    }

    public func remove(id: String) {
        devices.removeAll { $0.id == id }
    }

    public func device(id: String) -> Device? {
        devices.first { $0.id == id }
    }

    /// Finds a saved device for an address typed ad hoc.
    public func device(matchingAddress address: String) -> Device? {
        let needle = address.lowercased()
        return devices.first { $0.addresses.contains { $0.lowercased() == needle } }
    }
}

/// What an address answered. Firmware requires a login for GET /device on
/// password-protected devices, so `deviceId` is nil there ("a JetKVM, identity
/// unknown"): the engine then verifies the pinned ID after login, before any
/// input is sent.
public struct DeviceIdentity: Decodable, Equatable {
    public var deviceId: String?
    public var authMode: String?

    public init(deviceId: String?, authMode: String?) {
        self.deviceId = deviceId
        self.authMode = authMode
    }
}

public enum ProbeError: Error, Equatable {
    case unreachable
    case identityMismatch(expected: String, found: String)
}

/// Picks the address to connect to. All addresses are probed in parallel over
/// HTTP — never by opening WebRTC sessions, because a new JetKVM session takes
/// over the current one immediately. The earliest address in the list wins
/// among those answering within `preferenceWindow` of the first answer, and
/// an address reporting a device ID other than the saved one is rejected. An
/// address confirming the saved ID beats one whose identity is unknown
/// (password-protected): the probe sends no cookies, so when one address
/// answers as the device, a 401 elsewhere is another device.
public enum AddressProbe {
    public typealias Fetch = (_ address: String) async -> DeviceIdentity?

    public static func choose(addresses: [String], expectedDeviceID: String?, preferenceWindow: Duration = .milliseconds(250),
                              fetch: @escaping Fetch) async -> Result<(address: String, identity: DeviceIdentity), ProbeError> {
        guard !addresses.isEmpty else { return .failure(.unreachable) }
        let timerIndex = -1
        return await withTaskGroup(of: (Int, DeviceIdentity?).self) { group in
            for (index, address) in addresses.enumerated() {
                group.addTask { (index, await fetch(address)) }
            }
            var confirmed: [Int: DeviceIdentity] = [:]
            var unknown: [Int: DeviceIdentity] = [:]
            var mismatch: ProbeError?
            var timerStarted = false
            while let (index, identity) = await group.next() {
                if index == timerIndex { break } // preference window over
                guard let identity else { continue }
                if let expected = expectedDeviceID, let found = identity.deviceId, expected != found {
                    mismatch = .identityMismatch(expected: expected, found: found)
                    continue
                }
                if expectedDeviceID != nil && identity.deviceId == nil {
                    unknown[index] = identity
                } else {
                    confirmed[index] = identity
                    if index == 0 { break } // the most preferred address answered
                }
                if !timerStarted {
                    timerStarted = true
                    group.addTask {
                        try? await Task.sleep(for: preferenceWindow)
                        return (timerIndex, nil)
                    }
                }
            }
            group.cancelAll()
            let answers = confirmed.isEmpty ? unknown : confirmed
            if let best = answers.keys.min(), let identity = answers[best] {
                return .success((addresses[best], identity))
            }
            return .failure(mismatch ?? .unreachable)
        }
    }

    /// GET http(s)://address/device with a short timeout. A 401 counts as
    /// reachable with unknown identity when the public /device/status
    /// endpoint confirms a JetKVM answers there. https devices must present
    /// the pinned certificate authority (any, before the first connect).
    public static func httpFetch(timeout: TimeInterval = 2, certSHA256: String? = nil, log: ((String) -> Void)? = nil) -> Fetch {
        return { address in
            let base = (address.contains("://") ? address : "http://" + address).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let session = URLSession(configuration: .ephemeral, delegate: PinningDelegate(pin: certSHA256), delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            guard let (data, status) = await get(base + "/device", timeout: timeout, session: session, log: log) else { return nil }
            if status == 200 {
                return try? JSONDecoder().decode(DeviceIdentity.self, from: data)
            }
            guard status == 401, let (statusData, code) = await get(base + "/device/status", timeout: timeout, session: session, log: log), code == 200,
                  (try? JSONDecoder().decode(DeviceStatus.self, from: statusData)) != nil else { return nil }
            return DeviceIdentity(deviceId: nil, authMode: "password")
        }
    }

    private struct DeviceStatus: Decodable {
        var isSetup: Bool
    }

    private static func get(_ string: String, timeout: TimeInterval, session: URLSession, log: ((String) -> Void)?) async -> (Data, Int)? {
        guard let url = URL(string: string) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            return (data, http.statusCode)
        } catch {
            log?("probe \(string): \(error.localizedDescription) (\((error as NSError).domain) \((error as NSError).code))")
            return nil
        }
    }
}
