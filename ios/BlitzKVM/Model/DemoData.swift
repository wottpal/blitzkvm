#if targetEnvironment(simulator) && DEBUG
import ApprovalKit
import CryptoKit
import Foundation
import UIKit

/// `-demo` (Simulator, Debug): a paired JetKVM with two open requests, made
/// with software keys in memory, to look at the screens without hardware.
/// Its relay is unroutable (.invalid), so nothing leaves the Simulator.
enum DemoData {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("-demo") }

    /// `-demo-open <n>` opens the n-th request's review.
    static var openIndex: Int? { argument("-demo-open").flatMap(Int.init) }

    /// `-demo-screen devices|settings` starts on that tab.
    static var screen: AppModel.Screen? {
        switch argument("-demo-screen") {
        case "devices": .devices
        case "settings": .settings
        default: nil
        }
    }

    private static func argument(_ name: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @MainActor
    static func session() throws -> ApproverSession {
        let store = MemoryBlobStore()
        let keys = try ApproverKeys.loadOrCreate(in: store)
        let session = ApproverSession(keys: keys, store: store, name: "iPhone", file: nil)
        let broker = SoftwareSigner(), brokerSeal = SealKey(), target = SoftwareSigner()
        let owner = SoftwareSigner()
        let relay = "https://relay.example.invalid"
        let info = BrokerInfo(id: broker.id, key: B64Data(broker.publicKey), seal: B64Data(brokerSeal.publicKey))
        let ownerApprover = Approver(name: "Studio MacBook", platform: "macos", presence: owner.publicKey,
                                     transport: SoftwareSigner().publicKey, seal: SealKey().publicKey)

        func json(_ env: Envelope) throws -> Any { try JSONSerialization.jsonObject(with: Wire.encoder.encode(env)) }
        func box(_ message: [String: Any]) throws -> Data {
            try Box.seal(JSONSerialization.data(withJSONObject: message), to: keys.seal.publicKey)
        }

        let invite: [String: Any] = [
            "v": 1, "name": "Desk JetKVM", "relay": relay, "owner": ownerApprover.id, "token": B64.encode(Wire.randomBytes(32)),
            "broker": ["id": info.id, "key": B64.encode(info.key.data), "seal": B64.encode(info.seal.data)],
        ]
        guard let parsed = PairingInvite(qrString: PairingInvite.scheme + B64.encode(try JSONSerialization.data(withJSONObject: invite))) else {
            throw UserError("demo invite")
        }
        _ = try session.center.join(parsed)
        let now = Int64(Date().timeIntervalSince1970)
        let roster = Roster(seq: 2, issued: now, broker: info, relay: relay, owners: [ownerApprover.id],
                            approvers: [ownerApprover, keys.approver(name: "iPhone", platform: "ios")],
                            targets: [Target(name: "Mac mini", key: target.publicKey)])
        session.center.receive(box: try box(["op": "roster", "roster": try json(try Envelope.sign(roster, type: "roster", with: owner))]),
                               from: info.id)

        let asks = [
            Ask(target: target.id, kind: Kind.sudo, title: "sudo shutdown -r now", detail: "Restart the Mac mini",
                requester: Requester(uid: 501, user: "alex", tty: "ttys003", chain: [
                    ApprovalKit.Process(pid: 4242, name: "sudo", path: "/usr/bin/sudo", args: ["sudo", "shutdown", "-r", "now"], signer: "apple"),
                    ApprovalKit.Process(pid: 4180, name: "zsh", path: "/bin/zsh", args: ["-zsh"], signer: "apple"),
                    ApprovalKit.Process(pid: 3990, name: "Ghostty", path: "/Applications/Ghostty.app/Contents/MacOS/ghostty",
                                        signer: "developer:ABCDE12345"),
                ]), grantable: true, issued: now, lifetime: 110),
            Ask(target: target.id, kind: Kind.securityAgent, title: "System Settings wants to make changes",
                requester: Requester(uid: 501, user: "alex", chain: [
                    ApprovalKit.Process(pid: 812, name: "SecurityAgent", path: "/System/Library/Frameworks/Security.framework/Versions/A/MachServices/SecurityAgent.bundle/Contents/MacOS/SecurityAgent", signer: "apple"),
                ]),
                evidence: Evidence(locked: false, secureInput: SecureInput(pid: 812, bundle: "com.apple.SecurityAgent", team: nil),
                                   window: Rect(x: 552, y: 219, w: 400, h: 346), display: Size(w: 1504, h: 948)),
                secret: SecretKind.mac, issued: now, lifetime: 90),
        ]
        for ask in asks {
            let askEnv = try Envelope.sign(ask, type: "ask", with: target)
            let payload: [String: Any] = ["v": 1, "ask": try json(askEnv), "seal": B64.encode(SealKey().publicKey),
                                          "issued": ask.issued, "expires": ask.expires]
            let request = try Envelope.sign(bytes: JSONSerialization.data(withJSONObject: payload), type: "request", with: broker)
            session.center.receive(box: try box(["op": "request", "request": try json(request)]), from: info.id)
            // The JetKVM's picture of the screen, as the broker sends it.
            let jpeg = screen(showing: ask)
            let shot = ScreenShot(v: 1, request: ask.id, taken: now, sha256: B64Data(Data(SHA256.hash(data: jpeg))))
            session.center.receive(box: try box(["op": "screen", "screen": try json(try Envelope.sign(shot, type: "screen", with: broker)),
                                                 "jpeg": B64.encode(jpeg)]), from: info.id)
        }
        return session
    }

    /// A made-up remote desktop: a terminal with the command, or a password dialog.
    private static func screen(showing ask: Ask) -> Data {
        let size = CGSize(width: 640, height: 400)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.7) { ctx in
            let cg = ctx.cgContext
            let colors = [UIColor(red: 0.16, green: 0.22, blue: 0.42, alpha: 1).cgColor, UIColor(red: 0.42, green: 0.25, blue: 0.48, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            UIColor(white: 0.12, alpha: 0.85).setFill()
            UIBezierPath(rect: CGRect(x: 0, y: 0, width: size.width, height: 14)).fill()
            let mono = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            if ask.kind == Kind.securityAgent {
                let dialog = CGRect(x: 200, y: 110, width: 240, height: 180)
                UIColor(white: 0.93, alpha: 1).setFill()
                UIBezierPath(roundedRect: dialog, cornerRadius: 10).fill()
                (ask.title as NSString).draw(in: dialog.insetBy(dx: 16, dy: 20),
                                             withAttributes: [.font: UIFont.boldSystemFont(ofSize: 12), .foregroundColor: UIColor.black])
                UIColor.white.setFill()
                UIBezierPath(roundedRect: CGRect(x: 216, y: 200, width: 208, height: 22), cornerRadius: 5).fill()
                return
            }
            let window = CGRect(x: 60, y: 50, width: 520, height: 300)
            UIColor(white: 0.08, alpha: 0.96).setFill()
            UIBezierPath(roundedRect: window, cornerRadius: 10).fill()
            let lines = ["alex@mac-mini ~ % \(ask.title)", "BlitzKVM: approve on your iPhone or Mac…", "Password:"]
            for (i, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: window.minX + 14, y: window.minY + 30 + CGFloat(i) * 16),
                                        withAttributes: [.font: mono, .foregroundColor: UIColor(white: 0.9, alpha: 1)])
            }
        }
    }
}
#endif
