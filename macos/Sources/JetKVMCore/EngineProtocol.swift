import Foundation

/// Wire protocol shared with the Go helper (pkg/engineipc). Every frame is a
/// 4-byte big-endian length (type + payload), a 1-byte type, then the payload.
public enum FrameType: UInt8 {
    // engine → app
    case event = 0x01
    case accessUnit = 0x02
    case rpcResult = 0x03
    case commandDone = 0x04
    case audio = 0x05
    // app → engine
    case command = 0x10
    case key = 0x11
    case absPointer = 0x12
    case relPointer = 0x13
    case wheel = 0x14
}

public enum EngineProtocol {
    public static let maxFrameSize = 16 << 20

    public static func encode(_ type: FrameType, _ payload: Data) -> Data {
        var out = Data(capacity: 5 + payload.count)
        let length = UInt32(payload.count + 1)
        out.append(UInt8(truncatingIfNeeded: length >> 24))
        out.append(UInt8(truncatingIfNeeded: length >> 16))
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length))
        out.append(type.rawValue)
        out.append(payload)
        return out
    }

    public static func key(hid: UInt8, pressed: Bool) -> Data {
        encode(.key, Data([hid, pressed ? 1 : 0]))
    }

    /// x, y are in the device's absolute range 0...32767.
    public static func absolutePointer(x: Int32, y: Int32, buttons: UInt8) -> Data {
        var p = Data(capacity: 9)
        p.appendBigEndian(UInt32(bitPattern: x))
        p.appendBigEndian(UInt32(bitPattern: y))
        p.append(buttons)
        return encode(.absPointer, p)
    }

    /// A relative move (the device's relative mouse).
    public static func relativePointer(dx: Int16, dy: Int16, buttons: UInt8) -> Data {
        var p = Data(capacity: 5)
        p.append(contentsOf: [UInt8(UInt16(bitPattern: dx) >> 8), UInt8(UInt16(bitPattern: dx) & 0xff),
                              UInt8(UInt16(bitPattern: dy) >> 8), UInt8(UInt16(bitPattern: dy) & 0xff), buttons])
        return encode(.relPointer, p)
    }

    public static func wheel(y: Int8, x: Int8) -> Data {
        encode(.wheel, Data([UInt8(bitPattern: y), UInt8(bitPattern: x)]))
    }

    public static func command(_ command: EngineCommand) throws -> Data {
        encode(.command, try JSONEncoder().encode(command))
    }
}

extension Data {
    mutating func appendBigEndian(_ v: UInt32) {
        append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)])
    }

    mutating func appendBigEndian(_ v: UInt16) {
        append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xff)])
    }
}

/// Incremental frame parser: feed it bytes as they arrive from the pipe.
public struct FrameParser {
    private var buffer = Data()

    public init() {}

    public enum ParseError: Error { case frameTooLarge(Int), emptyFrame }

    /// Appends data and returns every complete frame.
    public mutating func feed(_ data: Data) throws -> [(FrameType?, Data)] {
        buffer.append(data)
        var frames: [(FrameType?, Data)] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = Int(buffer[start]) << 24 | Int(buffer[start + 1]) << 16 | Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
            if length == 0 { throw ParseError.emptyFrame }
            if length > EngineProtocol.maxFrameSize { throw ParseError.frameTooLarge(length) }
            guard buffer.count >= 4 + length else { break }
            let typeByte = buffer[start + 4]
            let payload = buffer.subdata(in: (start + 5)..<(start + 4 + length))
            frames.append((FrameType(rawValue: typeByte), payload))
            buffer.removeSubrange(start..<(start + 4 + length))
        }
        if buffer.isEmpty { buffer = Data() } // reset indices
        return frames
    }
}

public struct EngineCommand: Codable, Equatable {
    public var id: Int64?
    public var cmd: String
    public var baseURL: String?
    public var password: String?
    /// The current password (cmd "changePassword").
    public var oldPassword: String?
    /// The engine verifies this ID before any input: before login when the
    /// device answers GET /device without one, else over RPC after login.
    public var deviceID: String?
    /// Pins an https device's certificate authority (SHA-256 hex).
    public var certSHA256: String?
    public var offerH265: Bool?
    /// Adapt the stream quality to the link (connect, setAutoQuality).
    public var autoQuality: Bool?
    /// A fixed quality ladder level (connect, setQualityLevel).
    public var qualityLevel: String?
    public var method: String?
    public var params: JSONValue?
    public var text: String?
    public var delay: Int?
    /// A local file to upload (cmd "upload").
    public var path: String?
    /// The upload command to cancel (cmd "cancelUpload").
    public var target: Int64?
    /// Stop sending video while the app shows none (cmd "setVideoPaused").
    public var paused: Bool?
    /// Game Mode video quality (connect, cmd "setGameMode").
    public var gameMode: Bool?
    /// The app refreshes still pictures itself (refreshRegions) where the
    /// firmware offers it (connect).
    public var clientRefresh: Bool?
    /// Forward the device's audio (connect, setAudio).
    public var audio: Bool?
    /// Turn the device's audio on if it is off, once (connect; sessions that
    /// may change device settings).
    public var enableDeviceAudio: Bool?
    /// Keep a device reached over its own Tailscale on the tunnel: no public
    /// STUN servers, no direct path (connect).
    public var noDirectPath: Bool?

    public init(id: Int64? = nil, cmd: String, baseURL: String? = nil, password: String? = nil,
                deviceID: String? = nil, certSHA256: String? = nil, offerH265: Bool? = nil, autoQuality: Bool? = nil,
                qualityLevel: String? = nil, method: String? = nil,
                params: JSONValue? = nil, text: String? = nil, delay: Int? = nil, path: String? = nil, target: Int64? = nil,
                paused: Bool? = nil, oldPassword: String? = nil, clientRefresh: Bool? = nil,
                audio: Bool? = nil, enableDeviceAudio: Bool? = nil, noDirectPath: Bool? = nil, gameMode: Bool? = nil) {
        self.id = id
        self.oldPassword = oldPassword
        self.cmd = cmd
        self.baseURL = baseURL
        self.password = password
        self.deviceID = deviceID
        self.certSHA256 = certSHA256
        self.offerH265 = offerH265
        self.autoQuality = autoQuality
        self.qualityLevel = qualityLevel
        self.method = method
        self.params = params
        self.text = text
        self.delay = delay
        self.path = path
        self.target = target
        self.paused = paused
        self.gameMode = gameMode
        self.clientRefresh = clientRefresh
        self.audio = audio
        self.enableDeviceAudio = enableDeviceAudio
        self.noDirectPath = noDirectPath
    }
}

public struct CommandResult: Decodable {
    public var id: Int64
    public var error: String?
    public var invalid: String?
}

/// Subset of the Go session.Snapshot the app displays.
public struct SessionSnapshot: Decodable, Equatable {
    public var Phase: String
    public var Status: String
    public var BaseURL: String?
    public var DeviceID: String?
    public var Hostname: String?
    public var HIDReady: Bool?
    public var VideoReady: Bool?
    public var LastError: String?
    public var KeyboardLayout: String?
    public var VideoSignal: String?
    public var VideoWidth: Int?
    public var VideoHeight: Int?
    public var VideoFPS: Double?
    public var PasteInProgress: Bool?
    public var KeyboardLEDs: Int?
    public var ActiveExtension: String?
    /// Whether the engine adapts quality to the link, and its current level.
    public var AutoQuality: Bool?
    public var QualityLevel: String?
    /// Game Mode's quality applies (QualityLevel is then "game").
    public var GameMode: Bool?
    /// Game Mode is on while the JetKVM's relative mouse is off.
    public var RelativeMouseOff: Bool?
    /// The device leaves still refreshes to the app (RefreshPlanner), with
    /// the current level's P-frame QP floor and still refresh QP.
    public var ClientRefresh: Bool?
    public var MinQP: Int?
    public var StillQP: Int?
    /// The pinned certificate authority of an https device.
    public var CertSHA256: String?
    /// Go session.SerialSettings (field names as in Go), kept as JSON so a
    /// change round-trips every field.
    public var SerialSettings: JSONValue?
    public var SerialConsoleError: String?

    public init(Phase: String, Status: String) {
        self.Phase = Phase
        self.Status = Status
    }
}

public struct EngineEvent: Decodable {
    public var type: String
    public var message: String?

    private enum CodingKeys: String, CodingKey { case type, message }
}

public struct AccessUnitHeader: Equatable {
    public static let size = 14
    public enum Codec: UInt8 { case h264 = 1, h265 = 2 }

    public var codec: Codec
    public var keyframe: Bool
    public var rtpTimestamp: UInt32
    public var receivedUnixNano: Int64

    /// Splits an access-unit frame payload into header and Annex-B data.
    public static func parse(_ payload: Data) -> (AccessUnitHeader, Data)? {
        guard payload.count >= size else { return nil }
        let b = [UInt8](payload.prefix(size))
        guard let codec = Codec(rawValue: b[0]) else { return nil }
        let ts = UInt32(b[2]) << 24 | UInt32(b[3]) << 16 | UInt32(b[4]) << 8 | UInt32(b[5])
        var nanos: UInt64 = 0
        for i in 6..<14 { nanos = nanos << 8 | UInt64(b[i]) }
        let header = AccessUnitHeader(codec: codec, keyframe: b[1] & 1 != 0, rtpTimestamp: ts, receivedUnixNano: Int64(bitPattern: nanos))
        return (header, payload.subdata(in: (payload.startIndex + size)..<payload.endIndex))
    }
}

/// Precedes each audio packet's payload (pkg/engineipc AudioHeader).
public struct AudioPacketHeader: Equatable {
    public static let size = 16
    public enum Codec: UInt8 {
        case opus = 1, pcmu = 2

        /// RTP clock rate and the codec's name for the status bar.
        public var clockRate: Int { self == .opus ? 48000 : 8000 }
        public var name: String { self == .opus ? "Opus" : "PCMU" }
    }

    public var codec: Codec
    /// The RTP marker bit: the first packet after silence (fork firmware;
    /// stock firmware marks every packet).
    public var marker: Bool
    public var sequenceNumber: UInt16
    public var rtpTimestamp: UInt32
    public var receivedUnixNano: Int64

    public init(codec: Codec, marker: Bool, sequenceNumber: UInt16, rtpTimestamp: UInt32, receivedUnixNano: Int64) {
        self.codec = codec
        self.marker = marker
        self.sequenceNumber = sequenceNumber
        self.rtpTimestamp = rtpTimestamp
        self.receivedUnixNano = receivedUnixNano
    }

    /// Splits an audio frame payload into header and codec payload.
    public static func parse(_ payload: Data) -> (AudioPacketHeader, Data)? {
        guard payload.count >= size else { return nil }
        let b = [UInt8](payload.prefix(size))
        guard let codec = Codec(rawValue: b[0]) else { return nil }
        let ts = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
        var nanos: UInt64 = 0
        for i in 8..<16 { nanos = nanos << 8 | UInt64(b[i]) }
        let header = AudioPacketHeader(codec: codec, marker: b[1] & 1 != 0, sequenceNumber: UInt16(b[2]) << 8 | UInt16(b[3]),
                                       rtpTimestamp: ts, receivedUnixNano: Int64(bitPattern: nanos))
        return (header, payload.subdata(in: (payload.startIndex + size)..<payload.endIndex))
    }
}

/// Progress of an "upload" command.
public struct UploadProgress: Decodable, Equatable {
    public var id: Int64
    public var sent: Int64
    public var total: Int64
    public var bytesPerSecond: Double

    public init(id: Int64, sent: Int64, total: Int64, bytesPerSecond: Double) {
        self.id = id
        self.sent = sent
        self.total = total
        self.bytesPerSecond = bytesPerSecond
    }
}

/// Minimal JSON value for RPC parameters.
public enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }
}

public extension JSONValue {
    subscript(key: String) -> JSONValue? {
        get {
            if case .object(let o) = self { return o[key] }
            return nil
        }
        set {
            guard case .object(var o) = self else { return }
            o[key] = newValue
            self = .object(o)
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }
}

/// The engine reports "game" as the quality level while Game Mode's top
/// level applies; it is not a ladder level and is never saved or sent back.
public enum QualityLevelName {
    public static func ladderLevel(_ reported: String?) -> String? {
        guard let reported, !reported.isEmpty else { return nil }
        return reported == "game" ? "maximum" : reported
    }
}
