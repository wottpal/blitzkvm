import Foundation

/// A saved JetKVM. Addresses are tried in order (e.g. LAN IP, mDNS name,
/// VPN/MagicDNS name); the JetKVM `deviceId` pins the identity so a stored
/// password is only ever sent to the device it belongs to.
public struct Device: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var addresses: [String]
    /// The device's own ID (GET /device), learned on first connect.
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

    /// Key under which the password is stored: the device ID when known,
    /// so the secret follows the device across address changes.
    public var credentialAccount: String { deviceID ?? addresses.first ?? id }

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
        devices = (try? decoder.decode([Device].self, from: data)) ?? []
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

/// Response of GET /device (needs no login on JetKVM).
public struct DeviceIdentity: Decodable, Equatable {
    public var deviceId: String
    public var authMode: String?

    public init(deviceId: String, authMode: String?) {
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
/// an address whose device ID differs from the saved one is rejected.
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
            var answers: [Int: DeviceIdentity] = [:]
            var mismatch: ProbeError?
            var timerStarted = false
            while let (index, identity) = await group.next() {
                if index == timerIndex { break } // preference window over
                guard let identity else { continue }
                if let expected = expectedDeviceID, expected != identity.deviceId {
                    mismatch = .identityMismatch(expected: expected, found: identity.deviceId)
                    continue
                }
                answers[index] = identity
                if index == 0 { break } // the most preferred address answered
                if !timerStarted {
                    timerStarted = true
                    group.addTask {
                        try? await Task.sleep(for: preferenceWindow)
                        return (timerIndex, nil)
                    }
                }
            }
            group.cancelAll()
            if let best = answers.keys.min(), let identity = answers[best] {
                return .success((addresses[best], identity))
            }
            return .failure(mismatch ?? .unreachable)
        }
    }

    /// GET http(s)://address/device with a short timeout.
    public static func httpFetch(timeout: TimeInterval = 2) -> Fetch {
        return { address in
            let base = address.contains("://") ? address : "http://" + address
            guard let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/device") else { return nil }
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try? JSONDecoder().decode(DeviceIdentity.self, from: data)
        }
    }
}
