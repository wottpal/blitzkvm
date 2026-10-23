import AppKit
import GameController

/// What PointerLock does to the system; a protocol so tests can record the
/// calls and check that cursor changes stay balanced.
protocol PointerLockSystem {
    /// CGAssociateMouseAndMouseCursorPosition.
    func associateMouse(_ on: Bool)
    /// NSCursor.hide(); reference counted, so every hide needs one unhide.
    func hideCursor()
    func unhideCursor()
    /// CGWarpMouseCursorPosition (global display coordinates, origin top-left).
    func warp(to point: CGPoint)
    /// Installs a raw-delta handler on GCMouse.current (dx, dy with +y down);
    /// false when there is no GCMouse.
    func installMouseHandler(_ handler: @escaping (Double, Double) -> Void) -> Bool
    func removeMouseHandler()
}

/// Game Mode's mouse: freezes and hides the Mac cursor and delivers raw,
/// unaccelerated deltas for the remote's relative mouse.
///
/// GCMouse gives the HID deltas before the pointer acceleration curve, which
/// is what a shooter wants. Without one (some Bluetooth or virtual mice), the
/// NSEvent deltas of the dissociated cursor are the fallback; the two never
/// run together, or every move would count twice.
///
/// The cursor must always come back: hide is reference counted, so engage
/// hides once and release unhides once, however often either is called.
final class PointerLock {
    private let system: PointerLockSystem
    /// Raw dx, dy; +y is down on the remote.
    var onMotion: (Double, Double) -> Void = { _, _ in }
    private(set) var engaged = false
    /// A GCMouse handler delivers the motion (events are ignored then).
    private var gcDriving = false
    private var observers: [NSObjectProtocol] = []

    init(system: PointerLockSystem = LivePointerLockSystem()) {
        self.system = system
    }

    deinit { release() }

    /// Freezes the cursor at `point` (global display coordinates) and hides it.
    func engage(centeredOn point: CGPoint) {
        guard !engaged else { return }
        engaged = true
        system.warp(to: point)
        system.associateMouse(false)
        system.hideCursor()
        installHandler()
        // A mouse plugged in or switched to while playing changes the source.
        let center = NotificationCenter.default
        for name in [Notification.Name.GCMouseDidBecomeCurrent, .GCMouseDidStopBeingCurrent] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.mouseChanged()
            })
        }
    }

    /// Gives the cursor back. Safe to call at any time, any number of times.
    func release() {
        guard engaged else { return }
        engaged = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        system.removeMouseHandler()
        gcDriving = false
        system.unhideCursor()
        system.associateMouse(true)
    }

    /// The current GCMouse changed while engaged: take it up or fall back.
    func mouseChanged() {
        guard engaged else { return }
        system.removeMouseHandler()
        installHandler()
    }

    private func installHandler() {
        gcDriving = system.installMouseHandler { [weak self] dx, dy in
            self?.onMotion(dx, dy)
        }
    }

    /// Fallback path: called for every mouse move and drag event.
    func eventDelta(_ event: NSEvent) {
        eventDelta(dx: Double(event.deltaX), dy: Double(event.deltaY))
    }

    func eventDelta(dx: Double, dy: Double) {
        guard engaged, !gcDriving else { return }
        onMotion(dx, dy)
    }
}

struct LivePointerLockSystem: PointerLockSystem {
    func associateMouse(_ on: Bool) {
        CGAssociateMouseAndMouseCursorPosition(on ? 1 : 0)
    }
    func hideCursor() { NSCursor.hide() }
    func unhideCursor() { NSCursor.unhide() }
    func warp(to point: CGPoint) { CGWarpMouseCursorPosition(point) }

    func installMouseHandler(_ handler: @escaping (Double, Double) -> Void) -> Bool {
        guard let input = GCMouse.current?.mouseInput else { return false }
        // GCMouse's y is up-positive; the remote's is down-positive.
        input.mouseMovedHandler = { _, dx, dy in handler(Double(dx), Double(-dy)) }
        return true
    }

    func removeMouseHandler() {
        GCMouse.current?.mouseInput?.mouseMovedHandler = nil
    }
}
