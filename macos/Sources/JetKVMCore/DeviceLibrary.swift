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
    public var modifierProfile: String
    public var scalingMode: String
    public var offerH265: Bool
    public var invertScroll: Bool
    public var lastConnected: Date?

    public init(id: String = UUID().uuidString, name: String, addresses: [String], deviceID: String? = nil,
                modifierProfile: ModifierProfile = .mac, scalingMode: ScalingMode = .fit, offerH265: Bool = false,
                invertScroll: Bool = false, lastConnected: Date? = nil) {
        self.id = id
        self.name = name
        self.addresses = addresses
        self.deviceID = deviceID
        self.modifierProfile = modifierProfile.rawValue
        self.scalingMode = scalingMode.rawValue
        self.offerH265 = offerH265
        self.invertScroll = invertScroll
        self.lastConnected = lastConnected
    }

    public var profile: ModifierProfile { ModifierProfile(rawValue: modifierProfile) ?? .mac }
    public var scaling: ScalingMode { ScalingMode(rawValue: scalingMode) ?? .fit }

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
        return base.appendingPathComponent("JetKVM Desktop", isDirectory: true).appendingPathComponent("devices.json")
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
    /// endpoint confirms a JetKVM answers there.
    public static func httpFetch(timeout: TimeInterval = 2) -> Fetch {
        return { address in
            let base = (address.contains("://") ? address : "http://" + address).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let (data, status) = await get(base + "/device", timeout: timeout) else { return nil }
            if status == 200 {
                return try? JSONDecoder().decode(DeviceIdentity.self, from: data)
            }
            guard status == 401, let (statusData, code) = await get(base + "/device/status", timeout: timeout), code == 200,
                  (try? JSONDecoder().decode(DeviceStatus.self, from: statusData)) != nil else { return nil }
            return DeviceIdentity(deviceId: nil, authMode: "password")
        }
    }

    private struct DeviceStatus: Decodable {
        var isSetup: Bool
    }

    private static func get(_ string: String, timeout: TimeInterval) async -> (Data, Int)? {
        guard let url = URL(string: string) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (data, http.statusCode)
    }
}
