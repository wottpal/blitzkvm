import AppKit
import XCTest
@testable import BlitzKVM

final class LicensesWindowTests: XCTestCase {
    func testHeadingsAreBoldAndLinksClickable() throws {
        let text = "# BlitzKVM\nMIT License\n\n## libopus\nsource: https://github.com/wottpal/kvm/tree/release/0.5.9-fork.6\n"
        let rendered = LicensesWindowController.render(text)
        let string = rendered.string as NSString

        func font(of substring: String) throws -> NSFont {
            let range = string.range(of: substring)
            XCTAssertNotEqual(range.location, NSNotFound, substring)
            return try XCTUnwrap(rendered.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
        }
        XCTAssertFalse(rendered.string.contains("# "), "heading markers are stripped")
        XCTAssertTrue(try font(of: "BlitzKVM").fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(try font(of: "libopus").fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(try font(of: "MIT License").fontDescriptor.symbolicTraits.contains(.monoSpace))

        let url = string.range(of: "https://github.com/wottpal/kvm")
        let link = rendered.attribute(.link, at: url.location, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.absoluteString, "https://github.com/wottpal/kvm/tree/release/0.5.9-fork.6")
    }
}
