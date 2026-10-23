import XCTest
@testable import JetKVMCore

/// Game Mode feeds raw mouse deltas in and sends whole units out; no motion
/// may be lost in between.
final class RelativeMotionTests: XCTestCase {
    func testFractionsCarry() {
        var motion = RelativeMotion()
        for _ in 0..<3 { motion.add(dx: 0.4, dy: -0.4) }
        let first = motion.take()
        XCTAssertEqual(first?.dx, 1)
        XCTAssertEqual(first?.dy, -1)
        XCTAssertNil(motion.take())
        for _ in 0..<2 { motion.add(dx: 0.4, dy: -0.4) }
        let second = motion.take()
        XCTAssertEqual(second?.dx, 1)
        XCTAssertEqual(second?.dy, -1)
    }

    func testSumIsPreservedOverManySmallMoves() {
        // Simple LCG: SystemRandomNumberGenerator can't be seeded.
        var state: UInt64 = 12345
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53) * 6.0 - 3.0
        }
        var motion = RelativeMotion()
        var sum = 0.0
        var taken = 0
        for i in 1...10_000 {
            let v = next()
            sum += v
            motion.add(dx: v, dy: 0)
            if i % 7 == 0, let t = motion.take() { taken += Int(t.dx) }
        }
        if let t = motion.take() { taken += Int(t.dx) }
        // taken + remainder is the exact sum. (Truncating each side separately
        // can differ by one when the remainder's sign is opposite the taken's.)
        XCTAssertEqual(Double(taken) + motion.pending.dx, sum, accuracy: 1e-6)
        XCTAssertLessThan(abs(motion.pending.dx), 1)
    }

    func testLargeMovesCarryInsteadOfClamping() {
        var motion = RelativeMotion()
        motion.add(dx: 40000, dy: -40000)
        let a = motion.take()
        XCTAssertEqual(a?.dx, 32767)
        XCTAssertEqual(a?.dy, -32767)
        let b = motion.take()
        XCTAssertEqual(b?.dx, 7233)
        XCTAssertEqual(b?.dy, -7233)
        XCTAssertNil(motion.take())
    }

    func testSensitivityScales() {
        var motion = RelativeMotion(sensitivity: 1.5)
        motion.add(dx: 10, dy: -10)
        let t = motion.take()
        XCTAssertEqual(t?.dx, 15)
        XCTAssertEqual(t?.dy, -15)
    }

    func testNothingWholeIsNil() {
        var motion = RelativeMotion()
        motion.add(dx: 0.9, dy: 0)
        XCTAssertFalse(motion.hasPending)
        XCTAssertNil(motion.take())
        motion.reset()
        motion.add(dx: 0.2, dy: 0)
        XCTAssertNil(motion.take())
    }
}
