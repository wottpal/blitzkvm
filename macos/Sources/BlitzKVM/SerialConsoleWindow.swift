import AppKit
import JetKVMCore

/// Serial console output of one device, kept while its window is closed so
/// reopening shows the history. Capped at about 1 MB.
final class SerialConsoleLog {
    private(set) var text = ""
    private var filter = SerialTextFilter()
    private let limit = 1 << 20
    var onAppend: ((String) -> Void)?
    var onReset: (() -> Void)?

    func append(_ raw: String) {
        let clean = filter.feed(raw)
        guard !clean.isEmpty else { return }
        text += clean
        if text.utf8.count > limit {
            text = String(text.suffix(limit * 3 / 4))
            onReset?()
        } else {
            onAppend?(clean)
        }
    }

    func clear() {
        text = ""
        onReset?()
    }
}

/// A line-oriented terminal for the device's serial console extension: the
/// output, an input line sent with the device's line terminator, and quick
/// keys for interrupting the remote side.
final class SerialConsoleWindowController: NSWindowController, NSWindowDelegate {
    private let log: SerialConsoleLog
    private let engine: EngineProcess
    private let input = NSTextField()
    private let baud = NSPopUpButton()
    private let notice = NSTextField(labelWithString: "")
    private let enableButton = NSButton(title: "Turn On Serial Console", target: nil, action: nil)
    private var settings: JSONValue?
    static let baudRates = [1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600]

    init(log: SerialConsoleLog, engine: EngineProcess, deviceName: String) {
        self.log = log
        self.engine = engine
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Serial Console — \(deviceName)"
        window.minSize = NSSize(width: 480, height: 280)
        super.init(window: window)
        window.delegate = self
        build()
        scrollToEnd()
        log.onAppend = { [weak self] text in self?.appendOutput(text) }
        log.onReset = { [weak self] in self?.scrollToEnd() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        guard let window else { return }
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return }
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        outputView = textView

        input.placeholderString = "Type a line and press Return"
        input.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        input.target = self
        input.action = #selector(sendLine)
        let ctrlC = NSButton(title: "⌃C", target: self, action: #selector(sendControlC))
        ctrlC.toolTip = "Send Ctrl-C (interrupt)"
        let ctrlD = NSButton(title: "⌃D", target: self, action: #selector(sendControlD))
        ctrlD.toolTip = "Send Ctrl-D (end of input)"
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearOutput))
        baud.addItems(withTitles: Self.baudRates.map { "\($0) baud" })
        baud.target = self
        baud.action = #selector(changeBaud)
        notice.textColor = .secondaryLabelColor
        enableButton.target = self
        enableButton.action = #selector(enableConsole)

        let inputRow = NSStackView(views: [input, ctrlC, ctrlD])
        inputRow.orientation = .horizontal
        let toolbar = NSStackView(views: [notice, enableButton, NSView(), baud, clear])
        toolbar.orientation = .horizontal
        let stack = NSStackView(views: [toolbar, scroll, inputRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        for view in [toolbar, scroll, inputRow] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = stack
        window.initialFirstResponder = input
    }

    private var outputView: NSTextView?

    private func appendOutput(_ text: String) {
        guard let view = outputView, let storage = view.textStorage else { return }
        let atEnd = view.visibleRect.maxY >= view.bounds.maxY - 20
        storage.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ]))
        if atEnd { scrollToEnd() }
    }

    private func scrollToEnd() {
        guard let view = outputView else { return }
        if view.string != log.text {
            view.string = log.text
            view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        }
        view.scrollToEndOfDocument(nil)
    }

    /// Reflects the session: whether the extension is on, the baud rate.
    func update(snapshot: SessionSnapshot) {
        let active = snapshot.ActiveExtension == "serial-console"
        let connected = snapshot.Phase == "connected"
        input.isEnabled = active && connected
        baud.isEnabled = active && connected && snapshot.SerialSettings != nil
        enableButton.isHidden = active || !connected
        notice.stringValue = !connected ? "Not connected" : active ? "" : "The serial console extension is off on this device."
        notice.isHidden = notice.stringValue.isEmpty
        settings = snapshot.SerialSettings
        if let rate = settings?["BaudRate"]?.numberValue, let index = Self.baudRates.firstIndex(of: Int(rate)) {
            baud.selectItem(at: index)
        }
    }

    private var terminator: String {
        settings?["Terminator"]?["Value"]?.stringValue ?? "\n"
    }

    private func send(_ text: String) {
        Task { @MainActor in
            do {
                try await engine.run(EngineCommand(cmd: "serialSend", text: text))
            } catch {
                self.notice.stringValue = error.localizedDescription
                self.notice.isHidden = false
            }
        }
    }

    @objc private func sendLine() {
        send(input.stringValue + terminator)
        input.stringValue = ""
    }

    @objc private func sendControlC() { send(SerialKeys.controlC) }
    @objc private func sendControlD() { send(SerialKeys.controlD) }
    @objc private func clearOutput() { log.clear() }

    @objc private func enableConsole() {
        Task { @MainActor in
            do {
                try await engine.run(EngineCommand(cmd: "setExtension", text: "serial-console"))
            } catch {
                self.notice.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func changeBaud() {
        guard var settings, baud.indexOfSelectedItem >= 0 else { return }
        settings["BaudRate"] = .number(Double(Self.baudRates[baud.indexOfSelectedItem]))
        Task { @MainActor in
            do {
                try await engine.run(EngineCommand(cmd: "setSerialSettings", params: settings))
            } catch {
                self.notice.stringValue = error.localizedDescription
                self.notice.isHidden = false
            }
        }
    }
}
