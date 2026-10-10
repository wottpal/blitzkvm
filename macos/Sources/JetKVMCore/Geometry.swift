import Foundation

public enum ScalingMode: String, CaseIterable {
    /// Largest aspect-preserving size that fits the view.
    case fit
    /// One remote pixel per physical display pixel, centered.
    case actualSize
    /// Largest whole-number multiple that fits (crisp, nearest-neighbor).
    case integer
}

public struct VideoLayout: Equatable {
    /// Destination rectangle in physical pixels (origin top-left).
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// Nearest-neighbor sampling keeps text crisp when the scale is a whole
    /// number; linear otherwise.
    public var nearest: Bool

    public init(x: Double, y: Double, width: Double, height: Double, nearest: Bool) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.nearest = nearest
    }

    /// Computes where the video goes inside a drawable of the given pixel
    /// size. Edges are snapped to whole pixels.
    public static func compute(videoWidth: Int, videoHeight: Int, drawableWidth: Double, drawableHeight: Double, mode: ScalingMode) -> VideoLayout {
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
            scale = 1
        case .integer:
            scale = fitScale >= 1 ? floor(fitScale) : fitScale
        }
        let w = (vw * scale).rounded()
        let h = (vh * scale).rounded()
        let x = ((drawableWidth - w) / 2).rounded(.down)
        let y = ((drawableHeight - h) / 2).rounded(.down)
        let nearest = scale >= 1 && abs(scale - scale.rounded()) < 0.0001
        return VideoLayout(x: x, y: y, width: w, height: h, nearest: nearest)
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
