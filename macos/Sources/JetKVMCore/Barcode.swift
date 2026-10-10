import Foundation

/// Decodes the timestamp barcode the emulator burns into its test pattern
/// (pkg/emulator/media.go): a white/black start marker followed by 48 bits of
/// Unix milliseconds, MSB first, as 8×8 luma cells in the top-left corner.
public enum TimestampBarcode {
    public static let cell = 8
    public static let bits = 48

    /// - Parameters:
    ///   - luma: pointer to the first byte of the luma (Y) plane.
    ///   - stride: bytes per luma row.
    ///   - lumaMax: 255 for full range; video-range white (235) still decodes.
    /// - Returns: milliseconds since 1970, or nil if no barcode is present.
    public static func decode(luma: UnsafePointer<UInt8>, stride: Int, width: Int, height: Int) -> Int64? {
        let needed = (bits + 2) * cell
        guard width >= needed, height >= cell else { return nil }
        func sample(_ index: Int) -> UInt8 {
            let x = index * cell + cell / 2
            let y = cell / 2
            return luma[y * stride + x]
        }
        guard sample(0) >= 128, sample(1) < 128 else { return nil }
        var ms: Int64 = 0
        for i in 0..<bits {
            ms <<= 1
            if sample(i + 2) >= 128 { ms |= 1 }
        }
        return ms
    }
}
