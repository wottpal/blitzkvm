import Foundation

/// Display modes the JetKVM can advertise so the remote screen takes the
/// window's size ("Match Window"). The device's EDID gets a single detailed
/// timing of that size, and the host adopts it as the display's native mode.
///
/// Limits measured on a JetKVM (TC358749 HDMI bridge, RV1106) with a Mac host
/// (plan section 22):
/// - Two links (plan section 28). Above 33 Hz the bridge sends over CSI at
///   186.25 Mpx/s: up to 2496 wide and 1200 high within its 165 MHz pixel
///   clock (2432×1004 for a 21:9 window at 60 Hz). At 33 Hz or less its driver
///   slows the link to 109.7 Mpx/s, and a pixel clock just under that streams
///   any width up to 3840: 3008×1268 at 25 Hz, limited by the device's
///   capture buffers (`captureMaxBytes`) and its encoder (~160 Mpx/s).
/// - Width a multiple of 16: the device's encoder reads lines at a stride
///   rounded up to 16 pixels, so other widths come out sheared. Height a
///   multiple of 4. An odd height hung the device until it was power-cycled.
/// - The pixel clock stays near 1080p60's. The bridge starts sending each line
///   over CSI once its FIFO holds 300 pixels. A slow HDMI input lets the
///   output overtake it, and the picture breaks into stripes. Reduced
///   blanking at ~100 MHz does exactly that. Lines are padded with blanking
///   instead.
/// - Lines are at most 3.75 widths and 4000 pixels long; longer lines reach
///   the bridge but never stream. Small modes are padded vertically instead.
public enum RemoteDisplay {
    public struct Size: Equatable, CustomStringConvertible {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }

        public var description: String { "\(width)×\(height)" }
    }

    public static let minimum = Size(width: 640, height: 400)
    /// Bounds on each side on the fast link (above 33 Hz); the pixel clock
    /// limits the area within them. 2496 keeps a line's FIFO drift under the
    /// 291 pixels measured clean (2560×960 at 60 Hz).
    public static let maximum = Size(width: 2496, height: 1200)
    /// Bounds on the slow link: lines of at most 4000 pixels stream.
    public static let slowLinkMaximum = Size(width: 3840, height: 2160)
    public static let maxPixelClockKHz = 165_000
    /// The encoder (RV1106 VEPU) takes 12.9 ms per 1080p frame.
    static let maxEncodePixelsPerSecond = 160e6
    /// Capture buffers of stock firmware and fork releases before D10.
    public static let defaultCaptureMaxBytes = 1920 * 1080 * 3
    /// Refresh rates offered, fast link then slow link.
    public static let refreshRates = [60, 50, 40, 30, 25, 24]

    /// A display mode: size and refresh rate.
    public struct Mode: Equatable, CustomStringConvertible {
        public var size: Size
        public var refresh: Int

        public init(_ size: Size, refresh: Int = 60) {
            self.size = size
            self.refresh = refresh
        }

        public var description: String { "\(size) at \(refresh) Hz" }
    }

    /// The mode for a view of `width`×`height` remote pixels: the same size
    /// rounded down to the steps at `refresh` Hz, or the largest of its shape
    /// that the bridge, the capture buffers and the encoder carry at that
    /// rate. `refresh` nil picks the largest size and then the highest rate
    /// that reaches it (60 Hz whenever the view fits at 60 Hz).
    public static func mode(fitting width: Double, _ height: Double, refresh: Int? = nil,
                            captureMaxBytes: Int = defaultCaptureMaxBytes) -> Mode {
        guard let refresh else {
            let modes = refreshRates.map { mode(fitting: width, height, refresh: $0, captureMaxBytes: captureMaxBytes) }
            let largest = modes.map { $0.size.width * $0.size.height }.max() ?? 0
            // The first (highest rate) within 1 % of the largest size.
            return modes.first { $0.size.width * $0.size.height * 100 >= largest * 99 } ?? modes[0]
        }
        guard width > 0, height > 0 else { return Mode(minimum, refresh: refresh) }
        let bounds = refresh <= slowLinkMaxRefresh ? slowLinkMaximum : maximum
        // The view's size within the bounds (keeping its shape), then ever
        // narrower sizes of that shape until one streams.
        let shrink = max(1, width / Double(bounds.width), height / Double(bounds.height))
        var size = clamped(width / shrink, height / shrink, maximum: bounds)
        let aspect = height / width
        while size.width > minimum.width && !fits(size, refresh: refresh, captureMaxBytes: captureMaxBytes) {
            let w = size.width - widthStep
            let h = Int(Double(w) * aspect) / heightStep * heightStep
            size = Size(width: w, height: min(max(h, minimum.height), bounds.height))
        }
        return Mode(size, refresh: refresh)
    }

    /// Whether `size` streams at `refresh` Hz.
    public static func fits(_ size: Size, refresh: Int, captureMaxBytes: Int = defaultCaptureMaxBytes) -> Bool {
        guard size.width * size.height * 2 <= captureMaxBytes,
              Double(size.width * size.height * refresh) <= maxEncodePixelsPerSecond else { return false }
        if refresh <= slowLinkMaxRefresh {
            let t = slowLinkTiming(for: size, refresh: refresh)
            return size.width <= slowLinkMaximum.width && size.height <= slowLinkMaximum.height
                && t.pixelClockKHz <= Int(slowLinkPixelClockMHz * 1000)
        }
        return size.width <= maximum.width && size.height <= maximum.height
            && fastLinkTiming(for: size, refresh: refresh).pixelClockKHz <= maxPixelClockKHz
    }
    public static let widthStep = 16
    public static let heightStep = 4

    /// The 60 Hz display size for a view of `width`×`height` remote pixels
    /// (see mode(fitting:)).
    public static func size(fitting width: Double, _ height: Double) -> Size {
        mode(fitting: width, height, refresh: 60, captureMaxBytes: .max).size
    }

    /// `width`×`height` grown to the minimum (keeping its shape) and snapped
    /// down to the steps within the bounds.
    private static func clamped(_ width: Double, _ height: Double, maximum: Size) -> Size {
        var w = width, h = height
        if w < Double(minimum.width) || h < Double(minimum.height) {
            let grow = max(Double(minimum.width) / w, Double(minimum.height) / h)
            w *= grow
            h *= grow
        }
        func snap(_ v: Double, _ step: Int, _ lo: Int, _ hi: Int) -> Int {
            min(max(Int((v + 1e-6) / Double(step)) * step, lo), hi)
        }
        return Size(width: snap(w, widthStep, minimum.width, maximum.width),
                    height: snap(h, heightStep, minimum.height, maximum.height))
    }

    /// A 60 Hz display timing (pixels, lines, kHz).
    public struct Timing: Equatable {
        public var width, height: Int
        public var hBlank, hFrontPorch, hSync: Int
        public var vBlank, vFrontPorch, vSync: Int
        public var pixelClockKHz: Int

        public var hTotal: Int { width + hBlank }
        public var vTotal: Int { height + vBlank }
    }

    /// The bridge's CSI output in megapixels per second (4 lanes, 16 bit per
    /// pixel). Its driver (tc35874x) runs the link at 745 Mbit/s a lane above
    /// 33 Hz and at 438.75 Mbit/s a lane at 33 Hz or less.
    public static let fastCSIMegapixels = 186.25
    public static let slowCSIMegapixels = 109.6875
    /// Refresh rates up to this use the slow link.
    public static let slowLinkMaxRefresh = 33
    /// Pixel clock for slow-link modes: just under the link's drain rate, so
    /// a line's pixels leave the FIFO about as fast as they arrive and any
    /// width streams (2 % margin for clock tolerance).
    static let slowLinkPixelClockMHz = 107.5

    /// The display timing for `size` at `refresh` Hz (pixels, lines, kHz).
    public static func timing(for size: Size, refresh: Int = 60) -> Timing {
        refresh <= slowLinkMaxRefresh ? slowLinkTiming(for: size, refresh: refresh) : fastLinkTiming(for: size, refresh: refresh)
    }

    /// Slow link: minimal horizontal blanking, lines padded vertically so the
    /// pixel clock sits just under the link rate.
    static func slowLinkTiming(for size: Size, refresh: Int) -> Timing {
        let w = size.width, h = size.height, hz = Double(refresh)
        let vSync = cvtVSync(width: w, height: h)
        let hTotal = w + 160
        let lineMicros = Double(hTotal) / slowLinkPixelClockMHz
        let minVTotal = h + max(Int(460 / lineMicros) + 1, 3 + vSync + 6)
        let vTotal = max(minVTotal, Int(slowLinkPixelClockMHz * 1e6 / (hz * Double(hTotal))))
        let clock10kHz = (hz * Double(vTotal) * Double(hTotal) / 1e4).rounded()
        return Timing(width: w, height: h, hBlank: hTotal - w, hFrontPorch: 48, hSync: 32,
                      vBlank: vTotal - h, vFrontPorch: 3, vSync: vSync, pixelClockKHz: Int(clock10kHz) * 10)
    }

    /// CVT 1.2 reduced-blanking vertical timing; lines padded to keep the
    /// pixel clock where the bridge streams cleanly (see the type comment).
    static func fastLinkTiming(for size: Size, refresh: Int) -> Timing {
        let w = size.width, h = size.height, hz = Double(refresh)
        let vSync = cvtVSync(width: w, height: h)
        let minVBlankMicros = 460.0
        let hPeriod = (1e6 / hz - minVBlankMicros) / Double(h)
        var vTotal = h + max(Int(minVBlankMicros / hPeriod) + 1, 3 + vSync + 6)
        var hTotal = w + 160
        // The CSI output (4 lanes, 2980 Mbit/s, 16 bit/pixel) may lead the
        // input by at most ~250 of the FIFO's 300 pixels per line.
        let targetMHz = min(165, max(hz * Double(vTotal * hTotal) / 1e6, 186.25 * (1 - 250 / Double(w))))
        // Lines in steps of 8 pixels, rounded up for the FIFO; at the clock
        // limit rounded down instead, so the clock stays within it.
        let lineSteps = targetMHz * 1e6 / (hz * Double(vTotal)) / 8
        hTotal = max(hTotal, Int(targetMHz < 165 ? lineSteps.rounded(.up) : lineSteps.rounded(.down)) * 8)
        let maxLine = min(4000, w * 15 / 4 / 8 * 8)
        if hTotal > maxLine {
            hTotal = max(w + 160, maxLine)
            let lines = targetMHz * 1e6 / (hz * Double(hTotal))
            vTotal = max(vTotal, Int(targetMHz < 165 ? lines.rounded(.up) : lines.rounded(.down)))
        }
        let clock10kHz = (hz * Double(vTotal) * Double(hTotal) / 1e4).rounded()
        return Timing(width: w, height: h, hBlank: hTotal - w, hFrontPorch: 48, hSync: 32,
                      vBlank: vTotal - h, vFrontPorch: 3, vSync: vSync, pixelClockKHz: Int(clock10kHz) * 10)
    }

    /// CVT's vertical sync width encodes the aspect ratio (10 for others).
    static func cvtVSync(width: Int, height: Int) -> Int {
        for (aw, ah, lines) in [(4, 3, 4), (16, 9, 5), (16, 10, 6), (5, 4, 7), (15, 9, 7)]
        where abs(Double(width * ah) / Double(aw) - Double(height)) < 1 {
            return lines
        }
        return 10
    }

    public enum EDIDError: Error, Equatable {
        case invalid
    }

    /// `edid` advertising only `size`, as its preferred (native) mode. The
    /// rest is kept, so the host still sees the same display (vendor,
    /// product, serial, name, audio): the first descriptor becomes the new
    /// timing; other timings, the standard and established modes, and the
    /// CTA extension's video modes are removed, so the host has no other
    /// mode to pick (the CTA preference block that ranks them stays). Physical size is set to 96 dpi, which hosts treat as
    /// a standard-density display. Applying it again gives the same bytes.
    public static func edid(_ edid: [UInt8], advertising size: Size, refresh: Int = 60) throws -> [UInt8] {
        let header: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
        guard edid.count >= 128, edid.count % 128 == 0, Array(edid[0..<8]) == header else { throw EDIDError.invalid }
        var out = edid
        let t = timing(for: size, refresh: refresh)
        let mmWidth = Int((Double(size.width) * 25.4 / 96).rounded())
        let mmHeight = Int((Double(size.height) * 25.4 / 96).rounded())
        out[21] = UInt8(min(255, (mmWidth + 5) / 10))
        out[22] = UInt8(min(255, (mmHeight + 5) / 10))
        // Preferred timing is native; no other (GTF/continuous) modes.
        out[24] = (out[24] | 0x02) & ~0x01
        out.replaceSubrange(35..<38, with: [0, 0, 0])
        out.replaceSubrange(38..<54, with: [UInt8](repeating: 0x01, count: 16))
        var descriptors = [detailedTiming(t, mmWidth: mmWidth, mmHeight: mmHeight)]
        for i in 0..<4 {
            var d = Array(out[54 + 18 * i ..< 72 + 18 * i])
            // Keep display descriptors (name, serial, range limits…); drop
            // timings and dummies.
            guard d[0] == 0, d[1] == 0, d[3] != 0x10 else { continue }
            if d[3] == 0xFD { widenRangeLimits(&d, for: t, refresh: refresh) }
            descriptors.append(d)
        }
        while descriptors.count < 4 { descriptors.append([0, 0, 0, 0x10] + [UInt8](repeating: 0, count: 14)) }
        out.replaceSubrange(54..<126, with: descriptors.prefix(4).flatMap { $0 })
        setChecksum(&out, block: 0)
        for block in 1 ..< out.count / 128 where out[block * 128] == 0x02 {
            stripCTAVideoModes(&out, block: block)
        }
        return out
    }

    /// Width and height of the preferred (first detailed) timing.
    public static func preferredSize(_ edid: [UInt8]) -> Size? {
        guard edid.count >= 128, edid[54] != 0 || edid[55] != 0 else { return nil }
        return Size(width: Int(edid[56]) | Int(edid[58] >> 4) << 8, height: Int(edid[59]) | Int(edid[61] >> 4) << 8)
    }

    static func detailedTiming(_ t: Timing, mmWidth: Int, mmHeight: Int) -> [UInt8] {
        let clock = t.pixelClockKHz / 10
        let hBackPorch = t.hBlank - t.hFrontPorch - t.hSync
        precondition(hBackPorch > 0 && t.hBlank < 4096 && t.vBlank < 4096 && clock < 65536)
        func lo(_ v: Int) -> UInt8 { UInt8(v & 0xFF) }
        return [
            lo(clock), UInt8(clock >> 8),
            lo(t.width), lo(t.hBlank), UInt8((t.width >> 8) << 4 | t.hBlank >> 8),
            lo(t.height), lo(t.vBlank), UInt8((t.height >> 8) << 4 | t.vBlank >> 8),
            lo(t.hFrontPorch), lo(t.hSync), UInt8((t.vFrontPorch & 0xF) << 4 | t.vSync & 0xF),
            UInt8((t.hFrontPorch >> 8) << 6 | (t.hSync >> 8) << 4 | (t.vFrontPorch >> 4) << 2 | t.vSync >> 4),
            lo(mmWidth), lo(mmHeight), UInt8((mmWidth >> 8) << 4 | mmHeight >> 8),
            0, 0,
            0x1A, // digital separate sync, hsync +, vsync - (CVT reduced blanking)
        ]
    }

    /// Range limits must admit the new mode (vertical Hz, horizontal kHz,
    /// pixel clock in 10 MHz).
    static func widenRangeLimits(_ d: inout [UInt8], for t: Timing, refresh: Int = 60) {
        let hKHz = t.pixelClockKHz / t.hTotal
        d[5] = min(d[5], UInt8(min(50, refresh - 1)))
        d[6] = max(d[6], 61)
        d[7] = min(d[7], UInt8(max(1, hKHz - 1)))
        d[8] = max(d[8], UInt8(min(255, hKHz + 2)))
        d[9] = max(d[9], UInt8((t.pixelClockKHz + 9999) / 10000 + 1))
    }

    /// Drops the CTA-861 extension's video modes (video data block, 4:2:0
    /// blocks, detailed timings) and keeps its other data blocks (audio,
    /// HDMI, colorimetry…). The video format preference block stays: it only
    /// ranks the removed modes, which hosts then skip (the bytes the device
    /// and a Mac host accepted, see the tests).
    static func stripCTAVideoModes(_ edid: inout [UInt8], block: Int) {
        let base = block * 128
        let dtdOffset = Int(edid[base + 2])
        var kept: [UInt8] = []
        var i = 4
        while i < dtdOffset && i < 127 {
            let tag = edid[base + i] >> 5, length = Int(edid[base + i] & 0x1F)
            guard i + length < 127 else { break }
            let extended = tag == 7 && length > 0 ? edid[base + i + 1] : nil
            // 2: video data block; extended 14/15: YCbCr 4:2:0 video and map.
            if tag != 2 && extended != 14 && extended != 15 {
                kept += edid[base + i ... base + i + length]
            }
            i += 1 + length
        }
        var fresh = [UInt8](repeating: 0, count: 128)
        fresh[0] = 0x02
        fresh[1] = edid[base + 1]
        fresh[2] = UInt8(4 + kept.count)
        fresh[3] = edid[base + 3] & 0xF0 // no native detailed timings
        fresh.replaceSubrange(4 ..< 4 + kept.count, with: kept)
        edid.replaceSubrange(base ..< base + 128, with: fresh)
        setChecksum(&edid, block: block)
    }

    static func setChecksum(_ edid: inout [UInt8], block: Int) {
        let base = block * 128
        let sum = edid[base ..< base + 127].reduce(0) { ($0 + Int($1)) & 0xFF }
        edid[base + 127] = UInt8((256 - sum) & 0xFF)
    }

    // MARK: Hex (the device's getEDID/setEDID use hex strings)

    public static func bytes(hex: String) -> [UInt8]? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let v = UInt8(String(decoding: chars[i ... i + 1], as: UTF8.self), radix: 16) else { return nil }
            out.append(v)
        }
        return out
    }

    public static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }
}
