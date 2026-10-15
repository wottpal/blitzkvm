import AppKit
import JetKVMCore
import SystemConfiguration

/// Clipboard sync's state as the engine reports it: "off", "connecting",
/// "active" or "error" (with the reason).
struct ClipboardLive: Equatable {
    var state = "off"
    var message: String?
}

/// This app's key for clipboard sync, one for every device, next to the
/// JetKVM SSH key. Only the remote Macs it is installed on accept it, and
/// only over their JetKVM's USB link.
enum ClipboardKey {
    static let privateKey = JetKVMShell.directory.appendingPathComponent("clipboard_ed25519")

    /// Creates the key on first use.
    static func ensure() throws {
        guard !FileManager.default.fileExists(atPath: privateKey.path) else { return }
        try FileManager.default.createDirectory(at: JetKVMShell.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", "BlitzKVM clipboard", "-f", privateKey.path]
        try keygen.run()
        keygen.waitUntilExit()
        guard keygen.terminationStatus == 0 else { throw SetupError("Couldn't create a key for clipboard sync.") }
    }

    /// The comment the installed key's line ends with: which Mac it is
    /// (the computer name, read without a network lookup).
    static var comment: String {
        "BlitzKVM on \((SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "a Mac")"
    }
}

extension DeviceWindowController {
    /// Starts or stops the sync to match the device's setting. View-only
    /// sessions don't sync: the clipboard is input.
    func applyClipboardSync() {
        guard let sync = device.clipboardSync, sync.enabled, !input.viewOnly else {
            engine.setClipboardSync(nil)
            ClipboardBridge.shared.unregister(self)
            return
        }
        engine.setClipboardSync(.object([
            "privateKeyPath": .string(ClipboardKey.privateKey.path),
            "user": .string(sync.user),
            "hostKey": .string(sync.hostKey),
        ]))
    }

    /// Follows this Mac's clipboard while the engine's session to the remote
    /// Mac runs.
    func followClipboard(_ active: Bool) {
        guard active, device.clipboardSync?.enabled == true else {
            ClipboardBridge.shared.unregister(self)
            return
        }
        ClipboardBridge.shared.register(self, deviceID: device.id) { [weak self] items in
            self?.engine.send(command: EngineCommand(cmd: "clipboardSet", params: ClipboardPolicy.params(items)))
        }
    }

    /// Installs this app's key on the remote Mac (the engine types the
    /// installer there) and turns sync on.
    func installClipboardSync() async throws {
        try ClipboardKey.ensure()
        var params: [String: JSONValue] = [
            "privateKeyPath": .string(ClipboardKey.privateKey.path),
            "comment": .string(ClipboardKey.comment),
        ]
        if let user = device.clipboardSync?.user { params["user"] = .string(user) }
        let data = try await engine.run(EngineCommand(cmd: "clipboardInstall", params: .object(params)))
        struct Result: Decodable {
            var user: String
            var name: String?
            var hostKey: String
        }
        guard let data, let result = try? JSONDecoder().decode(Result.self, from: data) else {
            throw SetupError("The engine didn't say how setup went.")
        }
        // A key that already worked skips the installer, which reports the name.
        let name = result.name ?? device.clipboardSync?.computerName
        updateClipboardSync(ClipboardSync(user: result.user, computerName: name, hostKey: result.hostKey))
    }

    /// Removes this app's key from the remote Mac and turns the USB link
    /// off; `localOnly` forgets the setup here without reaching the Mac
    /// (the link still goes off).
    func removeClipboardSync(localOnly: Bool) async throws {
        guard let sync = device.clipboardSync else { return }
        if localOnly {
            try? await engine.call("setHostLinkState", params: .object(["enabled": .bool(false)]))
        } else {
            try await engine.run(EngineCommand(cmd: "clipboardUninstall", params: .object([
                "privateKeyPath": .string(ClipboardKey.privateKey.path),
                "user": .string(sync.user),
                "hostKey": .string(sync.hostKey),
            ])))
        }
        updateClipboardSync(nil)
    }
}
