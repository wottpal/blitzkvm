import Foundation

/// Virtual media as the firmware reports it (usb_mass_storage.go).
public struct VirtualMediaState: Decodable, Equatable {
    public var source: String
    public var mode: String
    public var filename: String?
    public var url: String?
    public var size: Int64

    public var title: String { filename ?? url ?? "image" }
}

public struct StorageFile: Decodable, Equatable, Identifiable {
    public var filename: String
    public var size: Int64
    public var createdAt: Date?

    public var id: String { filename }
    /// An upload that stopped before the end; uploading the same file again
    /// resumes it.
    public var isIncomplete: Bool { filename.hasSuffix(".incomplete") }

    public init(filename: String, size: Int64, createdAt: Date?) {
        self.filename = filename
        self.size = size
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey { case filename, size, createdAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filename = try c.decode(String.self, forKey: .filename)
        size = try c.decode(Int64.self, forKey: .size)
        createdAt = (try? c.decode(String.self, forKey: .createdAt)).flatMap(Self.parseDate)
    }

    /// Go's time.Time JSON (RFC 3339, optional fractional seconds).
    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

public struct StorageFiles: Decodable {
    public var files: [StorageFile]
}

public struct StorageSpace: Decodable, Equatable {
    public var bytesUsed: Int64
    public var bytesFree: Int64
}

public enum VirtualMediaMode: String, CaseIterable {
    case cdrom = "CDROM"
    case disk = "Disk"

    public var label: String { self == .cdrom ? "CD/DVD" : "USB disk" }
}
