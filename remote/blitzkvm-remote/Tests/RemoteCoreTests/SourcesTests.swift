import XCTest

/// The remote must never make the target ask for a permission: no
/// Accessibility, no event posting, no Apple Events, no screen capture.
/// Input only ever comes from the JetKVM's USB keyboard and pointer.
final class SourcesTests: XCTestCase {
    static let forbidden = ["AXUIElement", "AXIsProcessTrusted", "CGEventPost", "CGEvent(keyboardEventSource",
                            "CGEvent(mouseEventSource", "NSAppleScript", "OSAScript", "NSAppleEventDescriptor",
                            "AEDeterminePermission", "AESendMessage", "CGWindowListCreateImage", "CGDisplayCreateImage",
                            "SCShareableContent", "SCStream", "SCScreenshotManager", "kCGWindowName",
                            "CGRequestScreenCaptureAccess", "IOHIDRequestAccess"]

    func testNoPermissionPromptingAPIs() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources").standardized
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 10)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for api in Self.forbidden {
                XCTAssertFalse(text.contains(api), "\(file.lastPathComponent) uses \(api)")
            }
        }
    }
}
