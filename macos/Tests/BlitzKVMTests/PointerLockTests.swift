import CoreGraphics
import XCTest
@testable import BlitzKVM

/// Records every call so tests assert the order and balance of cursor changes.
final class FakePointerLockSystem: PointerLockSystem {
    enum Call: Equatable {
        case associate(Bool), hide, unhide, warp(CGPoint), install, remove
    }
    var calls: [Call] = []
    var hasGCMouse = false
    var handler: ((Double, Double) -> Void)?

    func associateMouse(_ on: Bool) { calls.append(.associate(on)) }
    func hideCursor() { calls.append(.hide) }
    func unhideCursor() { calls.append(.unhide) }
    func warp(to point: CGPoint) { calls.append(.warp(point)) }
    func installMouseHandler(_ handler: @escaping (Double, Double) -> Void) -> Bool {
        calls.append(.install)
        guard hasGCMouse else { return false }
        self.handler = handler
        return true
    }
    func removeMouseHandler() { calls.append(.remove); handler = nil }
}

final class PointerLockTests: XCTestCase {
    private func make(gcMouse: Bool = false) -> (PointerLock, FakePointerLockSystem, () -> [(Double, Double)]) {
        let system = FakePointerLockSystem()
        system.hasGCMouse = gcMouse
        let lock = PointerLock(system: system)
        var motions: [(Double, Double)] = []
        lock.onMotion = { motions.append(($0, $1)) }
        return (lock, system, { motions })
    }

    func testEngageDissociatesHidesAndWarps() {
        let (lock, system, _) = make()
        lock.engage(centeredOn: CGPoint(x: 100, y: 200))
        XCTAssertEqual(system.calls.filter { $0 != .install },
                       [.warp(CGPoint(x: 100, y: 200)), .associate(false), .hide])
        XCTAssertTrue(lock.engaged)
    }

    func testReleaseIsBalancedAndIdempotent() {
        let (lock, system, _) = make()
        lock.engage(centeredOn: .zero)
        lock.engage(centeredOn: .zero)
        lock.release()
        lock.release()
        lock.release()
        XCTAssertEqual(system.calls.filter { $0 == .hide }.count, 1)
        XCTAssertEqual(system.calls.filter { $0 == .unhide }.count, 1)
        XCTAssertEqual(system.calls.last, .associate(true))
        XCTAssertFalse(lock.engaged)
    }

    func testReleaseWithoutEngageTouchesNothing() {
        let (lock, system, _) = make()
        lock.release()
        XCTAssertEqual(system.calls, [])
    }

    func testFallsBackToEventDeltasWithoutGCMouse() {
        let (lock, _, motions) = make(gcMouse: false)
        lock.engage(centeredOn: .zero)
        lock.eventDelta(dx: 3, dy: 4)
        XCTAssertEqual(motions().count, 1)
        XCTAssertEqual(motions().first?.0, 3)
        XCTAssertEqual(motions().first?.1, 4)
    }

    func testEventDeltasIgnoredWhileGCMouseDrives() {
        let (lock, system, motions) = make(gcMouse: true)
        lock.engage(centeredOn: .zero)
        lock.eventDelta(dx: 3, dy: 4)
        XCTAssertTrue(motions().isEmpty)
        system.handler?(2, -1)
        XCTAssertEqual(motions().count, 1)
        XCTAssertEqual(motions().first?.0, 2)
        XCTAssertEqual(motions().first?.1, -1)
    }

    func testLateGCMouseCallbackAfterReleaseIsIgnored() {
        let (lock, system, motions) = make(gcMouse: true)
        lock.engage(centeredOn: .zero)
        let stale = system.handler
        lock.release()
        stale?(2, -1)
        XCTAssertTrue(motions().isEmpty)
    }

    func testNothingWhileNotEngaged() {
        let (lock, _, motions) = make()
        lock.eventDelta(dx: 3, dy: 4)
        XCTAssertTrue(motions().isEmpty)
    }

    func testMouseChangeSwitchesSource() {
        let (lock, system, motions) = make(gcMouse: false)
        lock.engage(centeredOn: .zero)
        // A mouse becomes current while engaged: the handler takes over.
        system.hasGCMouse = true
        lock.mouseChanged()
        lock.eventDelta(dx: 3, dy: 4)
        XCTAssertTrue(motions().isEmpty)
        // It goes away: events drive again.
        system.hasGCMouse = false
        lock.mouseChanged()
        lock.eventDelta(dx: 5, dy: 6)
        XCTAssertEqual(motions().count, 1)
        XCTAssertEqual(motions().first?.0, 5)
    }

    func testMouseChangeWhileReleasedDoesNothing() {
        let (lock, system, _) = make(gcMouse: true)
        lock.mouseChanged()
        XCTAssertEqual(system.calls, [])
    }

    func testEachEngageReportsItsMotionSource() {
        let (lock, system, _) = make(gcMouse: true)
        var sources: [Bool] = []
        lock.onSource = { sources.append($0) }
        lock.engage(centeredOn: .zero)
        XCTAssertTrue(lock.gcDriving)
        system.hasGCMouse = false
        lock.mouseChanged()
        lock.release()
        lock.engage(centeredOn: .zero)
        XCTAssertEqual(sources, [true, false, false])
        lock.release()
        lock.mouseChanged() // released: no source
        XCTAssertEqual(sources.count, 3)
    }
}
