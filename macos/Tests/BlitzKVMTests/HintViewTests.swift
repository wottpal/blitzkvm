import AppKit
import XCTest
@testable import BlitzKVM

@MainActor
final class HintViewTests: XCTestCase {
    /// hitTest receives points in the superview's coordinates; the HUD sits
    /// above the status bar, so its origin is not (0, 0).
    func testActionButtonTakesClicksOnlyOnItself() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let hud = HintView()
        hud.frame = NSRect(x: 0, y: 24, width: 800, height: 576) // status bar below
        container.addSubview(hud)
        hud.show("Game Mode needs relative mouse", for: 60, action: ("Turn On", {}))
        hud.layoutSubtreeIfNeeded()
        // Skip the fade-in: hitTest wants the panel visible.
        hud.subviews.forEach { $0.alphaValue = 1; $0.isHidden = false }
        guard let frame = hud.actionButtonFrameInSuperview else { return XCTFail("no action button") }
        let button = hud.hitTest(NSPoint(x: frame.midX, y: frame.midY))
        XCTAssertTrue(button is NSButton)
        XCTAssertNil(hud.hitTest(NSPoint(x: frame.midX, y: frame.minY - 24 - 1))) // where the bug put it, below the button
        XCTAssertNil(hud.hitTest(NSPoint(x: frame.maxX + 30, y: frame.midY)))
    }
}
