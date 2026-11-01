import Darwin
import Foundation

/// The USB network link from the JetKVM (firmware D17): this Mac's end has a
/// fixed MAC address, and the broker listens on the JetKVM's link-local
/// address, which only means something with the interface as its scope.
public enum HostLink {
    /// The Mac's side of the link (pkg/hostlink HostMAC).
    public static let hostMAC: [UInt8] = [0x02, 0x4a, 0x4b, 0x00, 0x00, 0x02]
    public static let brokerPort: UInt16 = 4023

    /// The name of the interface with `mac`, from getifaddrs' AF_LINK entries.
    public static func interface(mac: [UInt8] = hostMAC) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            p = ifa.pointee.ifa_next
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let found = sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl -> Bool in
                guard Int(dl.pointee.sdl_alen) == mac.count else { return false }
                // LLADDR: sdl_data holds the name, then the address, and may
                // run past the struct's declared array.
                let lladdr = UnsafeRawPointer(dl).advanced(by: MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)!)
                    .advanced(by: Int(dl.pointee.sdl_nlen))
                return (0..<mac.count).allSatisfy { lladdr.load(fromByteOffset: $0, as: UInt8.self) == mac[$0] }
            }
            if found { return String(cString: ifa.pointee.ifa_name) }
        }
        return nil
    }

    /// link.json, written by the installer: the JetKVM's link-local address.
    public struct Config: Codable, Equatable {
        public var address: String
        public init(address: String) { self.address = address }

        public var isLinkLocal: Bool {
            address.range(of: #"^fe80::[0-9a-f:]+$"#, options: .regularExpression) != nil
        }
    }

    /// Where to reach the broker: an explicit host:port (tests, the
    /// emulator), else the configured address scoped to the link interface.
    public enum Endpoint: Equatable {
        case fixed(host: String, port: UInt16)
        case link(Config)

        /// Parses `host:port` or `[v6]:port`.
        public static func parse(_ s: String) -> Endpoint? {
            if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
                let host = String(s[s.index(after: s.startIndex)..<close])
                let rest = s[s.index(after: close)...]
                guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()) else { return nil }
                return .fixed(host: host, port: port)
            }
            guard let colon = s.lastIndex(of: ":"), let port = UInt16(s[s.index(after: colon)...]) else { return nil }
            return .fixed(host: String(s[..<colon]), port: port)
        }

        /// The host and port to dial now; nil while the link is down.
        public func resolve(interface: () -> String? = { HostLink.interface() }) -> (host: String, port: UInt16)? {
            switch self {
            case .fixed(let host, let port):
                return (host, port)
            case .link(let config):
                guard config.isLinkLocal, let iface = interface() else { return nil }
                return ("\(config.address)%\(iface)", HostLink.brokerPort)
            }
        }
    }
}
