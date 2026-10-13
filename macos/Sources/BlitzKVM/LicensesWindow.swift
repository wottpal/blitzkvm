import AppKit

/// BlitzKVM › Licenses…: BlitzKVM's license, the open-source code compiled
/// into the app and its helper, and the firmware builds JetKVM Setup installs
/// (GPL-2.0, with where their source is). The text is assembled at build time
/// (scripts/licenses.sh) into Resources/Licenses.txt; lines starting with
/// "# " and "## " are headings.
final class LicensesWindowController: NSWindowController {
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Licenses"
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let scroll = NSTextView.scrollableTextView()
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.textContainerInset = NSSize(width: 16, height: 14)
            textView.textStorage?.setAttributedString(Self.render(Self.text()))
        }
        window.contentView = scroll
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func text() -> String {
        guard let url = Bundle.main.url(forResource: "Licenses", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "# Licenses\n\nThe license list is missing from this build (make -C macos app adds it)."
        }
        return text
    }

    static func render(_ text: String) -> NSAttributedString {
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ]
        func heading(size: CGFloat, before: CGFloat) -> [NSAttributedString.Key: Any] {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = before
            style.paragraphSpacing = 4
            return [.font: NSFont.boldSystemFont(ofSize: size), .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
        }
        let out = NSMutableAttributedString()
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                out.append(NSAttributedString(string: String(line.dropFirst(3)) + "\n", attributes: heading(size: 13, before: 10)))
            } else if line.hasPrefix("# ") {
                out.append(NSAttributedString(string: String(line.dropFirst(2)) + "\n", attributes: heading(size: 18, before: out.length == 0 ? 0 : 22)))
            } else {
                out.append(NSAttributedString(string: line + "\n", attributes: body))
            }
        }
        if let links = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in links.matches(in: out.string, range: NSRange(location: 0, length: out.length)) {
                if let url = match.url { out.addAttribute(.link, value: url, range: match.range) }
            }
        }
        return out
    }
}
