import Foundation

public enum ScalingMode: String, CaseIterable {
    /// One remote pixel per point: the remote desktop looks the same size as
    /// on a monitor of its own resolution (2 physical pixels on Retina). Pans
    /// with the pointer when the window is smaller than the remote screen.
    case actualSize
    /// Largest aspect-preserving size that fits the view.
    case fit
    /// One remote pixel per physical display pixel (tiny on Retina, but every
    /// pixel exact). Pans like actualSize.
    case pixelExact
    /// Largest whole multiple of physical pixels that fits, always drawn
    /// with exact (nearest-neighbor) pixels.
    case integer
    /// The remote display takes the window's size (RemoteDisplay): one remote
    /// pixel per point like actualSize (or per `matchScale` points), filling
    /// the window. Scaled to fit until the remote has followed a resize, and
    /// beyond the device's limits.
    /// Opt-in: every new size is a new display to a Mac target, which then
    /// is no longer its main display (plan section 22).
    case matchWindow
}

/// How the picture is resampled to the window (View › Scaling Filter).
/// Shrinking always averages (antialiased); the choice matters for
/// enlarging.
public enum ScalingFilter: String, CaseIterable {
    /// The learned text upscaler at exactly 2×, FSR 1 at other enlargements.
    case automatic
    /// AMD FSR 1: edge-adaptive upscaling (EASU) plus light sharpening (RCAS).
    case fsr
    /// FSR 1 with full sharpening.
    case fsrSharp
    /// FSR 1's edge-adaptive upscaling alone.
    case easu
    /// Lanczos-3: the sharpest classic filter, faint ringing at hard edges.
    case lanczos
    /// Catmull-Rom bicubic: sharp, little ringing.
    case catmullRom
    /// Each pixel stays a crisp square; only pixels straddling two blend them
    /// (area-weighted nearest neighbor).
    case sharpBilinear
    /// Bilinear: smooth, soft.
    case bilinear
    /// Nearest neighbor: exact pixels, uneven at fractional scales.
    case nearest

    public var menuTitle: String {
        switch self {
        case .automatic: return "Automatic (Text Upscaler at 2×, FSR 1 Otherwise)"
        case .fsr: return "FSR 1 (Edge-Adaptive, Light Sharpening)"
        case .fsrSharp: return "FSR 1, Strong Sharpening"
        case .easu: return "FSR 1, No Sharpening"
        case .lanczos: return "Lanczos-3 (Sharpest Classic)"
        case .catmullRom: return "Catmull-Rom Bicubic"
        case .sharpBilinear: return "Sharp Bilinear (Crisp Pixels, Smooth Seams)"
        case .bilinear: return "Bilinear (Soft)"
        case .nearest: return "Nearest Neighbor (Exact Pixels)"
        }
    }
}

public struct VideoLayout: Equatable {
    /// Destination rectangle in physical pixels (origin top-left). It may
    /// extend beyond the drawable when the video is larger (panning).
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// Whole-number scale: nearest-neighbor sampling keeps edges exact.
    public var nearest: Bool

    public init(x: Double, y: Double, width: Double, height: Double, nearest: Bool) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.nearest = nearest
    }

    /// Physical pixels per remote pixel.
    public func scale(videoWidth: Int) -> Double {
        videoWidth > 0 ? width / Double(videoWidth) : 0
    }

    /// Computes where the video goes inside a drawable of the given pixel
    /// size. `pointScale` is the display's backing scale factor; `pan` (0...1
    /// per axis) positions a video larger than the drawable. Edges are snapped
    /// to whole pixels. `matchScale` is Device.matchScale (Match Window).
    public static func compute(videoWidth: Int, videoHeight: Int, drawableWidth: Double, drawableHeight: Double,
                               mode: ScalingMode, pointScale: Double = 1, matchScale: Double = 1,
                               pan: (x: Double, y: Double) = (0.5, 0.5)) -> VideoLayout {
        guard videoWidth > 0, videoHeight > 0, drawableWidth > 0, drawableHeight > 0 else {
            return VideoLayout(x: 0, y: 0, width: 0, height: 0, nearest: false)
        }
        let vw = Double(videoWidth), vh = Double(videoHeight)
        let fitScale = min(drawableWidth / vw, drawableHeight / vh)
        let scale: Double
        switch mode {
        case .fit:
            scale = fitScale
        case .actualSize:
            scale = max(pointScale, 0.25)
        case .matchWindow:
            // Matched: the view is the remote size plus less than one size
            // step (RemoteDisplay rounds down to whole steps).
            let natural = max(pointScale * matchScale, 0.25)
            let slackW = drawableWidth - vw * natural, slackH = drawableHeight - vh * natural
            let matched = slackW >= 0 && slackH >= 0 && slackW < Double(RemoteDisplay.widthStep) * natural
                && slackH < Double(RemoteDisplay.heightStep) * natural
            scale = matched ? natural : fitScale
        case .pixelExact:
            scale = 1
        case .integer:
            scale = fitScale >= 1 ? floor(fitScale) : fitScale
        }
        let w = (vw * scale).rounded()
        let h = (vh * scale).rounded()
        func place(_ size: Double, in space: Double, pan: Double) -> Double {
            // Centered when it fits; otherwise the pan fraction picks which
            // part is visible (0 = leading edge, 1 = trailing edge).
            size <= space ? ((space - size) / 2).rounded(.down) : ((space - size) * min(max(pan, 0), 1)).rounded()
        }
        let nearest = scale >= 1 && abs(scale - scale.rounded()) < 0.0001
        return VideoLayout(x: place(w, in: drawableWidth, pan: pan.x), y: place(h, in: drawableHeight, pan: pan.y),
                           width: w, height: h, nearest: nearest)
    }

    /// Maps a point (physical pixels, origin top-left) to the device's
    /// absolute pointer range 0...32767, clamped to the video area.
    public func absolutePosition(px: Double, py: Double) -> (Int32, Int32)? {
        guard width > 0, height > 0 else { return nil }
        let nx = min(max((px - x) / width, 0), 1)
        let ny = min(max((py - y) / height, 0), 1)
        return (Int32((nx * 32767).rounded()), Int32((ny * 32767).rounded()))
    }

    public func contains(px: Double, py: Double) -> Bool {
        px >= x && px < x + width && py >= y && py < y + height
    }

    /// The whole drawable pixels the video covers, clipped to a drawable of
    /// the given size (layout edges are whole pixels).
    public func visibleRect(drawableWidth: Double, drawableHeight: Double) -> PixelRect {
        PixelRect(x0: Int(max(x, 0)), y0: Int(max(y, 0)),
                  x1: Int(min(x + width, drawableWidth)), y1: Int(min(y + height, drawableHeight))).intersection(
            PixelRect(width: Int(drawableWidth), height: Int(drawableHeight)))
    }

    /// The destination pixels a filter draws from video pixels `rect` of a
    /// `videoWidth`×`videoHeight` video, when each output pixel's taps reach
    /// up to `reach` video pixels from its center.
    public func destinationRect(of rect: PixelRect, videoWidth: Int, videoHeight: Int, reach: Double) -> PixelRect {
        guard !rect.isEmpty, videoWidth > 0, videoHeight > 0 else { return .empty }
        let sx = width / Double(videoWidth), sy = height / Double(videoHeight)
        return PixelRect(x0: Int((x + (Double(rect.x0) - reach) * sx).rounded(.down)),
                         y0: Int((y + (Double(rect.y0) - reach) * sy).rounded(.down)),
                         x1: Int((x + (Double(rect.x1) + reach) * sx).rounded(.up)),
                         y1: Int((y + (Double(rect.y1) + reach) * sy).rounded(.up)))
    }
}

/// Whole pixels [x0, x1) × [y0, y1), origin top-left.
public struct PixelRect: Equatable {
    public var x0: Int
    public var y0: Int
    public var x1: Int
    public var y1: Int

    public init(x0: Int, y0: Int, x1: Int, y1: Int) {
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
    }

    /// [0, width) × [0, height).
    public init(width: Int, height: Int) {
        self.init(x0: 0, y0: 0, x1: width, y1: height)
    }

    public static let empty = PixelRect(x0: 0, y0: 0, x1: 0, y1: 0)

    public var isEmpty: Bool { x1 <= x0 || y1 <= y0 }
    public var width: Int { isEmpty ? 0 : x1 - x0 }
    public var height: Int { isEmpty ? 0 : y1 - y0 }

    /// The smallest rectangle holding both.
    public func union(_ other: PixelRect) -> PixelRect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        return PixelRect(x0: min(x0, other.x0), y0: min(y0, other.y0), x1: max(x1, other.x1), y1: max(y1, other.y1))
    }

    public func intersection(_ other: PixelRect) -> PixelRect {
        let r = PixelRect(x0: max(x0, other.x0), y0: max(y0, other.y0), x1: min(x1, other.x1), y1: min(y1, other.y1))
        return r.isEmpty ? .empty : r
    }

    /// Grown by `margin` on every side (empty stays empty).
    public func outset(by margin: Int) -> PixelRect {
        isEmpty ? self : PixelRect(x0: x0 - margin, y0: y0 - margin, x1: x1 + margin, y1: y1 + margin)
    }

    public func offsetBy(dx: Int, dy: Int) -> PixelRect {
        isEmpty ? self : PixelRect(x0: x0 + dx, y0: y0 + dy, x1: x1 + dx, y1: y1 + dy)
    }

    /// The cells of a grid of `size`×`size` pixels that the rectangle
    /// touches (rounded outward), e.g. 4:2:0 chroma sites for size 2.
    public func cells(of size: Int) -> PixelRect {
        isEmpty ? self : PixelRect(x0: x0 / size, y0: y0 / size, x1: (x1 + size - 1) / size, y1: (y1 + size - 1) / size)
    }
}

/// Converts precise trackpad scrolling into wheel ticks without losing
/// fractions or depending on the event rate.
public struct ScrollAccumulator {
    public var pointsPerTick: Double
    private var pendingY: Double = 0
    private var pendingX: Double = 0

    public init(pointsPerTick: Double = 24) {
        self.pointsPerTick = pointsPerTick
    }

    /// Adds a scroll delta; returns whole ticks to send (each clamped to Int8).
    public mutating func add(deltaX: Double, deltaY: Double, precise: Bool) -> (y: Int8, x: Int8) {
        if !precise {
            // Line-based mouse wheels: one notch is one tick.
            return (Self.clampTick(deltaY.rounded()), Self.clampTick(deltaX.rounded()))
        }
        pendingY += deltaY / pointsPerTick
        pendingX += deltaX / pointsPerTick
        // A tiny epsilon keeps accumulated float error (10 × 0.1 = 0.999…)
        // from swallowing a tick.
        let y = (pendingY + (pendingY < 0 ? -1e-9 : 1e-9)).rounded(.towardZero)
        let x = (pendingX + (pendingX < 0 ? -1e-9 : 1e-9)).rounded(.towardZero)
        pendingY -= y
        pendingX -= x
        return (Self.clampTick(y), Self.clampTick(x))
    }

    public mutating func reset() {
        pendingX = 0
        pendingY = 0
    }

    static func clampTick(_ v: Double) -> Int8 {
        Int8(max(-127, min(127, v)))
    }
}

/// Window content size (points) that shows a remote screen at `mode`'s
/// natural size, shrunk to fit `available` keeping the aspect ratio.
public func preferredContentSize(videoWidth: Int, videoHeight: Int, pointScale: Double, mode: ScalingMode, matchScale: Double = 1,
                                 available: (width: Double, height: Double), extraHeight: Double) -> (width: Double, height: Double)? {
    guard videoWidth > 0, videoHeight > 0, pointScale > 0 else { return nil }
    let perPixel: Double // points per remote pixel
    switch mode {
    case .pixelExact: perPixel = 1 / pointScale
    case .matchWindow: perPixel = matchScale
    default: perPixel = 1
    }
    let w = Double(videoWidth) * perPixel
    let h = Double(videoHeight) * perPixel
    let shrink = min(1, available.width / w, (available.height - extraHeight) / h)
    return ((w * shrink).rounded(), (h * shrink).rounded() + extraHeight)
}
