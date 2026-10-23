import Foundation

/// Game Mode's mouse deltas, turned into whole-unit relative HID moves
/// without losing any: fractions (and anything past the Int16 range) stay
/// pending and ride out with the next `take()`.
public struct RelativeMotion {
    public var sensitivity: Double

    private var x = 0.0
    private var y = 0.0

    public init(sensitivity: Double = 1.0) {
        self.sensitivity = sensitivity
    }

    /// Raw device units; scaled by `sensitivity` as they accumulate.
    public mutating func add(dx: Double, dy: Double) {
        x += dx * sensitivity
        y += dy * sensitivity
    }

    /// A whole unit is waiting on either axis.
    public var hasPending: Bool {
        abs(x) >= 1 || abs(y) >= 1
    }

    /// The whole-unit part, truncated toward zero and clamped to Int16
    /// (symmetric, so -32768 is never sent); the rest stays pending.
    public mutating func take() -> (dx: Int16, dy: Int16)? {
        guard hasPending else { return nil }
        let wholeX = Self.whole(x)
        let wholeY = Self.whole(y)
        x -= wholeX
        y -= wholeY
        return (Int16(wholeX), Int16(wholeY))
    }

    /// Drops pending motion (e.g. when Game Mode is left).
    public mutating func reset() {
        x = 0
        y = 0
    }

    /// What is still pending, for tests.
    var pending: (dx: Double, dy: Double) { (x, y) }

    private static func whole(_ v: Double) -> Double {
        let limit = Double(Int16.max)
        return min(max(v.rounded(.towardZero), -limit), limit)
    }
}
