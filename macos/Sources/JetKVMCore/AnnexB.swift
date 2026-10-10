import Foundation

/// Annex-B (start-code delimited) H.264/H.265 handling for VideoToolbox, which
/// wants parameter sets separately and slices as length-prefixed (AVCC/HVCC)
/// NAL units.
public enum AnnexB {
    /// Splits an Annex-B buffer into NAL units (without start codes).
    public static func nalUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var start = -1
        var i = 0
        while i + 3 <= bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    if end > start && bytes[end - 1] == 0 { end -= 1 }
                    if end > start { units.append(Data(bytes[start..<end])) }
                }
                i += 3
                start = i
                continue
            }
            i += 1
        }
        if start >= 0 && start < bytes.count {
            units.append(Data(bytes[start..<bytes.count]))
        }
        return units
    }

    public enum Codec { case h264, h265 }

    public static func nalType(_ nal: Data, codec: Codec) -> UInt8 {
        guard let first = nal.first else { return 0xff }
        switch codec {
        case .h264: return first & 0x1f
        case .h265: return (first >> 1) & 0x3f
        }
    }

    public struct Split {
        /// H.264: [SPS, PPS]; H.265: [VPS, SPS, PPS] — only when present.
        public var parameterSets: [Data]
        /// Slices and SEI as 4-byte length-prefixed NAL units.
        public var lengthPrefixed: Data
        public var isKeyframe: Bool
    }

    /// Separates parameter sets from the rest and converts the remainder to
    /// length-prefixed NAL units. Access-unit delimiters are dropped.
    public static func split(_ data: Data, codec: Codec) -> Split {
        var vps: Data?, sps: Data?, pps: Data?
        var out = Data()
        var keyframe = false
        for nal in nalUnits(data) {
            let type = nalType(nal, codec: codec)
            switch codec {
            case .h264:
                switch type {
                case 7: sps = nal; continue
                case 8: pps = nal; continue
                case 9: continue // AUD
                case 5: keyframe = true
                default: break
                }
            case .h265:
                switch type {
                case 32: vps = nal; continue
                case 33: sps = nal; continue
                case 34: pps = nal; continue
                case 35: continue // AUD
                case 16...21: keyframe = true
                default: break
                }
            }
            out.appendBigEndian(UInt32(nal.count))
            out.append(nal)
        }
        var params: [Data] = []
        switch codec {
        case .h264:
            if let sps, let pps { params = [sps, pps] }
        case .h265:
            if let vps, let sps, let pps { params = [vps, sps, pps] }
        }
        return Split(parameterSets: params, lengthPrefixed: out, isKeyframe: keyframe)
    }
}
