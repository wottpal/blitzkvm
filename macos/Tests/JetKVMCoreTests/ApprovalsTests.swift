import ApprovalKit
import XCTest
@testable import JetKVMCore

/// The app's side of remote approvals: routes, pairing codes, the setup
/// row's states, how requests read, and the remote installer's commands.
@MainActor
final class ApprovalsTests: XCTestCase {
    let brokerKey = SoftwareSigner(), brokerSeal = SealKey(), target = SoftwareSigner()
    var brokerInfo: BrokerInfo { BrokerInfo(id: brokerKey.id, key: B64Data(brokerKey.publicKey), seal: B64Data(brokerSeal.publicKey)) }

    func keys() -> ApproverKeys {
        ApproverKeys(presence: SoftwareSigner(), transport: SoftwareSigner(), seal: SealKey(), hardwareBacked: false)
    }

    /// A center that owns the broker, with the target added when `withTarget`.
    func owner(withTarget: Bool = false) throws -> (ApprovalCenter, ApproverKeys) {
        let k = keys()
        let center = ApprovalCenter(keys: k, name: "Mac", platform: "macos", file: nil)
        _ = try center.genesis(broker: brokerInfo, name: "Mac mini", direct: "http://192.168.1.40",
                               relay: "https://relay.example.workers.dev", presence: k.presence)
        if withTarget {
            try center.update(brokerKey.id, presence: k.presence) { $0.targets = [Target(name: "Mac mini", key: self.target.publicKey)] }
        }
        return (center, k)
    }

    // MARK: Routes

    func testPrefersTheDirectChannelThenTheRelay() {
        XCTAssertEqual(ApprovalOutbox.route(directConnected: true, relayConnected: true), .direct)
        XCTAssertEqual(ApprovalOutbox.route(directConnected: true, relayConnected: false), .direct)
        XCTAssertEqual(ApprovalOutbox.route(directConnected: false, relayConnected: true), .relay)
        XCTAssertNil(ApprovalOutbox.route(directConnected: false, relayConnected: false))
    }

    func testHeldBoxesGoOutInOrderAndExpireAfter30Seconds() {
        var outbox = ApprovalOutbox()
        outbox.hold(Data([1]), for: "a", at: 100)
        outbox.hold(Data([2]), for: "a", at: 110)
        outbox.hold(Data([3]), for: "b", at: 100)
        XCTAssertEqual(outbox.count(for: "a"), 2)
        // 31 s after the first: only the second is still fresh.
        XCTAssertEqual(outbox.take(for: "a", at: 131), [Data([2])])
        XCTAssertEqual(outbox.take(for: "a", at: 131), [], "taken boxes leave the queue")
        outbox.prune(at: 200)
        XCTAssertEqual(outbox.count(for: "b"), 0)
    }

    func testDeviceBaseAndRelayURLs() {
        XCTAssertEqual(ApprovalAddress.base("192.168.1.40"), "http://192.168.1.40")
        XCTAssertEqual(ApprovalAddress.base("mac-mini-jetkvm.example.ts.net"), "http://mac-mini-jetkvm.example.ts.net")
        XCTAssertEqual(ApprovalAddress.base("https://kvm.example:8443/"), "https://kvm.example:8443")
        XCTAssertNil(ApprovalAddress.base(""))
        XCTAssertNil(ApprovalAddress.base("ftp://kvm.example"))
        XCTAssertEqual(BoxChannel.directURL(deviceBase: URL(string: ApprovalAddress.base("192.168.1.40")!)!)?.absoluteString,
                       "ws://192.168.1.40/approvals/v1/ws")
        XCTAssertEqual(ApprovalAddress.relay(" https://relay.example.workers.dev/ "), "https://relay.example.workers.dev")
        XCTAssertNil(ApprovalAddress.relay("relay.example.workers.dev"))
        XCTAssertNil(ApprovalAddress.relay("http://relay.example.workers.dev"), "plain http only to this Mac")
        XCTAssertEqual(ApprovalAddress.relay("http://localhost:8787"), "http://localhost:8787")
        XCTAssertNil(ApprovalAddress.relay(""))
    }

    // MARK: Pairing

    func testInviteSurvivesTheQRCode() throws {
        let (center, k) = try owner()
        let invite = try center.invite(brokerKey.id, presence: k.presence)
        let image = try XCTUnwrap(QRCode.image(invite.qrString, scale: 6))
        let read = try XCTUnwrap(QRCode.read(image), "the code reads back")
        let back = try XCTUnwrap(PairingInvite(qrString: read))
        XCTAssertEqual(back.broker, brokerInfo)
        XCTAssertEqual(back.token, invite.token)
        XCTAssertEqual(back.owner, k.id)
        XCTAssertEqual(back.relay, "https://relay.example.workers.dev")
        XCTAssertEqual(back.direct, "http://192.168.1.40")
        // One module per pixel by default, for crisp scaling in the view.
        XCTAssertEqual(QRCode.image(invite.qrString)?.width, image.width / 6)
    }

    // MARK: JetKVM Setup

    func device(enabled: Bool, target: String? = nil) -> DeviceApprovals {
        DeviceApprovals(enabled: enabled, broker: brokerInfo, seq: 2, target: target,
                        approvers: [.init(id: "phone", name: "Alex's iPhone", platform: "ios", owner: true)])
    }

    func testSetupStateFollowsTheDeviceAndTheRoster() throws {
        XCTAssertEqual(ApprovalsSetupState.evaluate(device: device(enabled: false), hasClipboardSync: false, roster: nil, me: "x"),
                       .needsClipboardSync)
        XCTAssertEqual(ApprovalsSetupState.evaluate(device: device(enabled: false), hasClipboardSync: true, roster: nil, me: "x"), .off)

        // On, but not paired here: the device's approvers, and Turn Off only.
        guard case .managedElsewhere(let approvers, let paired) = ApprovalsSetupState.evaluate(
            device: device(enabled: true), hasClipboardSync: true, roster: nil, me: "x") else { return XCTFail() }
        XCTAssertEqual(approvers.map(\.name), ["Alex's iPhone"])
        XCTAssertFalse(paired)

        // This Mac's roster: an approver that isn't an owner manages nothing.
        let (center, k) = try owner(withTarget: true)
        let roster = try XCTUnwrap(center.roster(brokerKey.id))
        var notOwner = roster
        let other = keys()
        notOwner.approvers.append(other.approver(name: "Alex's iPhone", platform: "ios"))
        notOwner.owners = [other.id]
        guard case .managedElsewhere(_, true) = ApprovalsSetupState.evaluate(
            device: device(enabled: true), hasClipboardSync: true, roster: notOwner, me: k.id) else { return XCTFail() }

        // The owner: the target, connected once its daemon is.
        guard case .on(let on) = ApprovalsSetupState.evaluate(device: device(enabled: true, target: target.id),
                                                             hasClipboardSync: true, roster: roster, me: k.id) else { return XCTFail() }
        XCTAssertEqual(on.target?.id, target.id)
        XCTAssertTrue(on.connected)
        XCTAssertTrue(on.canInstall)
        XCTAssertEqual(ApproverLine.names(on.approvers), "This Mac")
        guard case .on(let waiting) = ApprovalsSetupState.evaluate(device: device(enabled: true, target: "other"),
                                                                  hasClipboardSync: false, roster: roster, me: k.id) else { return XCTFail() }
        XCTAssertFalse(waiting.connected)
        XCTAssertFalse(waiting.canInstall)

        // Before the install: no target.
        let (fresh, fk) = try owner()
        guard case .on(let bare) = ApprovalsSetupState.evaluate(device: device(enabled: true), hasClipboardSync: true,
                                                               roster: fresh.roster(brokerKey.id), me: fk.id) else { return XCTFail() }
        XCTAssertNil(bare.target)

        // A roster for another broker (the JetKVM was reset) isn't this one's.
        var elsewhere = device(enabled: true)
        let otherBroker = SoftwareSigner()
        elsewhere.broker = BrokerInfo(id: otherBroker.id, key: B64Data(otherBroker.publicKey), seal: B64Data(SealKey().publicKey))
        guard case .managedElsewhere = ApprovalsSetupState.evaluate(device: elsewhere, hasClipboardSync: true, roster: roster,
                                                                     me: k.id) else { return XCTFail() }
    }

    func testDeviceStateDecodesTheBrokersAnswer() throws {
        let json = """
            {"enabled":true,"broker":{"id":"\(brokerKey.id)","key":"\(B64.encode(brokerKey.publicKey))",
             "seal":"\(B64.encode(brokerSeal.publicKey))"},"seq":3,"synced":true,"relayConnected":false,
             "target":"\(target.id)","approvers":[{"id":"a","name":"Mac","platform":"macos","owner":true,"direct":true}],
             "pending":0,"recent":[{"at":1,"id":"x","kind":"sudo","title":"t","state":"done"}]}
            """
        let state = try JSONDecoder().decode(DeviceApprovals.self, from: Data(json.utf8))
        XCTAssertEqual(state.broker, brokerInfo)
        XCTAssertEqual(state.seq, 3)
        XCTAssertEqual(state.target, target.id)
        XCTAssertEqual(state.approvers?.first?.owner, true)
        let off = try JSONDecoder().decode(DeviceApprovals.self, from: Data("""
            {"enabled":false,"broker":{"id":"\(brokerKey.id)","key":"\(B64.encode(brokerKey.publicKey))",
             "seal":"\(B64.encode(brokerSeal.publicKey))"},"synced":false,"relayConnected":false,"pending":0}
            """.utf8))
        XCTAssertFalse(off.enabled)
    }

    func testEnvelopeAsAnRPCParameter() throws {
        let (center, _) = try owner()
        let env = try XCTUnwrap(center.broker(brokerKey.id)?.roster)
        let value = try JSONValue(encoding: env)
        let back = try Wire.decoder.decode(Envelope.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(back, env)
        XCTAssertNoThrow(try Roster.accept(back, current: nil))
    }

    // MARK: Requests

    /// The request as the broker would send it, received by `center`.
    func request(_ ask: Ask, center: ApprovalCenter, keys k: ApproverKeys) throws -> OpenRequest {
        let askEnv = try Envelope.sign(ask, type: "ask", with: target)
        let now = Int64(Date().timeIntervalSince1970)
        let env = try Envelope.sign(Request(ask: askEnv, seal: B64Data(SealKey().publicKey), issued: now, expires: now + 60),
                                    type: "request", with: brokerKey)
        let message = try JSONSerialization.data(withJSONObject: [
            "op": "request", "request": JSONSerialization.jsonObject(with: Wire.encoder.encode(env)),
        ])
        center.receive(box: try Box.seal(message, to: k.seal.publicKey), from: brokerKey.id)
        return try XCTUnwrap(center.requests.first { $0.id == ask.id })
    }

    func testHowASudoRequestReads() throws {
        let (center, k) = try owner(withTarget: true)
        let now = Int64(Date().timeIntervalSince1970)
        let chain = [ApprovalKit.Process(pid: 4242, name: "sudo", path: "/usr/bin/sudo", args: ["sudo", "shutdown", "-r", "now"],
                                         signer: "apple"),
                     ApprovalKit.Process(pid: 4100, name: "zsh", path: "/bin/zsh", args: ["-zsh"], signer: "apple"),
                     ApprovalKit.Process(pid: 4000, name: "helper", path: "/tmp/helper", args: nil, signer: "adhoc")]
        let ask = Ask(target: target.id, kind: Kind.sudo, title: "sudo shutdown -r now", detail: "",
                      requester: Requester(uid: 501, user: "alex", tty: "ttys003", chain: chain),
                      evidence: Evidence(locked: false), grantable: true, issued: now)
        let r = try request(ask, center: center, keys: k)
        let s = ApprovalSummary(r, broker: center.broker(brokerKey.id), passwordStored: false)
        XCTAssertEqual(s.kindName, "sudo")
        XCTAssertEqual(s.targetName, "Mac mini")
        XCTAssertEqual(s.brokerName, "Mac mini")
        XCTAssertNil(s.detail, "an empty detail shows nothing")
        XCTAssertEqual(s.code, r.verified.code)
        XCTAssertEqual(s.codeHint, "Check that the remote computer shows code \(s.code).")
        XCTAssertTrue(s.canGrant)
        XCTAssertNil(s.password)
        XCTAssertEqual(s.requester, "alex (uid 501) · ttys003")
        XCTAssertEqual(s.chain.map(\.arguments), ["sudo shutdown -r now", "-zsh", nil])
        XCTAssertEqual(s.chain.map(\.trusted), [true, true, false])
        XCTAssertEqual(s.chain.last?.signer, "Ad hoc signed")
        XCTAssertEqual(s.evidence, [ApprovalSummary.Fact(label: "Screen", value: "Unlocked")])
        XCTAssertEqual(s.notificationTitle, "Mac mini: sudo shutdown -r now")
        XCTAssertEqual(s.notificationBody, "Code \(s.code)")
        XCTAssertEqual(s.authenticationReason, "approve “sudo shutdown -r now” (code \(s.code)) on Mac mini")
        XCTAssertNil(s.requestedBy)
    }

    func testAPasswordDialogNamesThePasswordTheJetKVMTypes() throws {
        let (center, k) = try owner(withTarget: true)
        let ask = Ask(target: target.id, kind: Kind.securityAgent, title: "System Settings wants to make changes",
                      evidence: Evidence(locked: false, secureInput: SecureInput(pid: 7, bundle: "com.apple.SecurityAgent", team: nil),
                                         window: Rect(x: 552, y: 219, w: 400, h: 346), display: Size(w: 1504, h: 948)),
                      secret: SecretKind.mac, issued: Int64(Date().timeIntervalSince1970))
        let r = try request(ask, center: center, keys: k)
        let stored = ApprovalSummary(r, broker: center.broker(brokerKey.id), passwordStored: true)
        XCTAssertEqual(stored.password, ApprovalSummary.Password(kind: SecretKind.mac, name: "Mac password", stored: true))
        XCTAssertFalse(stored.canGrant)
        XCTAssertEqual(stored.codeHint, "Approving lets the JetKVM answer the prompt on Mac mini.")
        XCTAssertEqual(stored.evidence.map(\.value), ["Unlocked", "com.apple.SecurityAgent", "400 × 346 at 552, 219 of 1504 × 948"])
        XCTAssertEqual(ApprovalSummary(r, broker: center.broker(brokerKey.id), passwordStored: false).password?.stored, false)
        // A long title is cut in the Touch ID reason.
        let long = Ask(target: target.id, kind: Kind.confirm, title: String(repeating: "x", count: 80), issued: Int64(Date().timeIntervalSince1970))
        let longRequest = try request(long, center: center, keys: k)
        XCTAssertEqual(ApprovalSummary(longRequest, broker: center.broker(brokerKey.id), passwordStored: false).authenticationReason,
                       "approve “\(String(repeating: "x", count: 59))…” (code \(longRequest.verified.code)) on Mac mini")
        // Coordinates no screen has don't trap.
        let odd = Ask(target: target.id, kind: Kind.securityAgent, title: "Dialog",
                      evidence: Evidence(locked: false, window: Rect(x: 1e300, y: -1e300, w: 400, h: 1e7)),
                      secret: SecretKind.mac, issued: Int64(Date().timeIntervalSince1970))
        XCTAssertEqual(ApprovalSummary(try request(odd, center: center, keys: k), broker: center.broker(brokerKey.id),
                                       passwordStored: false).evidence.last?.value, "400 × ? at ?, ?") // JSON has no NaN or infinity
    }

    func testArgumentsAndTimes() {
        XCTAssertEqual(ApprovalSummary.abbreviate(["rm", "-rf", "My Files"]), #"rm -rf "My Files""#)
        XCTAssertNil(ApprovalSummary.abbreviate([]))
        let long = ApprovalSummary.abbreviate(Array(repeating: "argument", count: 40))!
        XCTAssertEqual(long.count, 160)
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertEqual(ApprovalSummary.timeLeft(42), "0:42")
        XCTAssertEqual(ApprovalSummary.timeLeft(90), "1:30")
        XCTAssertEqual(ApprovalSummary.timeLeft(-3), "0:00")
    }

    func testOutcomes() {
        func text(_ o: ApprovalOutcome) -> [String?] { [o.title, o.detail] }
        XCTAssertEqual(text(ApprovalOutcome(state: "approved", byName: "Alex's iPhone", byMe: false, note: nil)),
                       ["Handled on Alex's iPhone", "Approved"])
        XCTAssertEqual(text(ApprovalOutcome(state: "denied", byName: "Mac", byMe: true, note: nil)), ["Denied", nil])
        XCTAssertEqual(text(ApprovalOutcome(state: "failed", byName: "Alex's iPhone", byMe: false, note: "no prompt")),
                       ["Handled on Alex's iPhone", "Failed: no prompt"])
        XCTAssertEqual(text(ApprovalOutcome(state: "expired", byName: nil, byMe: false, note: nil)), ["Expired", nil])
    }

    // MARK: Remote install

    func testStagingOutput() {
        let out = "/tmp/blitzkvm-remote.AbC123\nfe80::4a:4bff:fe00:1%en7 51234 fe80::4a:4bff:fe00:2%en7 22\n"
        XCTAssertEqual(RemoteInstall.staged(output: out),
                       RemoteInstall.Staged(directory: "/tmp/blitzkvm-remote.AbC123", linkAddress: "fe80::4a:4bff:fe00:1"))
        XCTAssertNil(RemoteInstall.staged(output: "/tmp/elsewhere\nfe80::1%en7 1 fe80::2%en7 22"))
        XCTAssertNil(RemoteInstall.staged(output: "/tmp/blitzkvm-remote.AbC123\n192.168.1.40 51234 192.168.1.5 22"),
                     "only the USB link's link-local address")
        XCTAssertNil(RemoteInstall.staged(output: "/tmp/blitzkvm-remote.AbC123; rm -rf /\nfe80::1%en7 1 fe80::2%en7 22"))
    }

    func testIdentityMustMatchItsKey() {
        let line = #"{"id":"\#(target.id)","key":"\#(B64.encode(target.publicKey))"}"#
        XCTAssertEqual(RemoteInstall.identity(output: "installing\n" + line + "\n", name: "Mac mini"),
                       Target(name: "Mac mini", key: target.publicKey))
        let forged = #"{"id":"\#(SoftwareSigner().id)","key":"\#(B64.encode(target.publicKey))"}"#
        XCTAssertNil(RemoteInstall.identity(output: forged, name: "Mac mini"))
        XCTAssertNil(RemoteInstall.identity(output: "sudo: a password is required", name: "Mac mini"))
    }

    func testCommandsRefuseUnexpectedPaths() {
        let files = ["blitzkvm-remote": String(repeating: "a", count: 64)]
        XCTAssertNil(RemoteInstall.identityCommand(staging: "/etc", files: files))
        XCTAssertNil(RemoteInstall.identityCommand(staging: "/tmp/blitzkvm-remote.AbC123", files: ["../x": String(repeating: "a", count: 64)]))
        XCTAssertNil(RemoteInstall.identityCommand(staging: "/tmp/blitzkvm-remote.AbC123", files: ["x": "not a hash"]))
        XCTAssertNil(RemoteInstall.cleanupCommand(staging: "/"))
        // The agent reads this domain and key (RemoteCore's OnePassword.keepRunning…).
        XCTAssertEqual(RemoteInstall.keepOnePasswordCommand(true),
                       "defaults write xyz.scio.blitzkvm.remote KeepOnePasswordRunning -bool true")
        XCTAssertTrue(RemoteInstall.keepOnePasswordCommand(false).hasSuffix("; true"), "off succeeds when it was never on")
        let command = RemoteInstall.identityCommand(staging: "/tmp/blitzkvm-remote.AbC123", files: files)
        XCTAssertTrue(command?.hasPrefix("/usr/bin/sudo -k -S -p '' /bin/sh -c '") == true)
        XCTAssertEqual(RemoteInstall.sudoInput(password: "pässwörd"), Data("pässwörd\n".utf8))
    }

    /// The root step's script, run here without sudo: it copies the staged
    /// files, checks them, writes the roster and link.json and runs
    /// install.sh from its own copy; a file changed after hashing stops it.
    func testRootStepChecksTheStagedFiles() throws {
        let staging = try shell("mktemp -d /tmp/blitzkvm-remote.XXXXXX").trimmingCharacters(in: .whitespacesAndNewlines)
        defer { try? FileManager.default.removeItem(atPath: staging) }
        let dir = URL(fileURLWithPath: staging)
        // A stand-in install.sh: shows what it was given.
        try #"printf 'args=%s\n' "$*"; cat roster.json; echo; cat link.json; echo; ls"#
            .write(to: dir.appendingPathComponent("install.sh"), atomically: true, encoding: .utf8)
        try "not hashed".write(to: dir.appendingPathComponent("odd name"), atomically: true, encoding: .utf8)
        _ = try shell("printf 'bin' > \(RemoteInstall.quote(staging))/blitzkvm-remote")
        var files: [String: String] = [:]
        for name in ["install.sh", "blitzkvm-remote"] {
            files[name] = try shell("shasum -a 256 \(RemoteInstall.quote(staging + "/" + name)) | cut -d' ' -f1")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertNil(RemoteInstall.rootScript(staging: staging, files: files.merging(["odd name": files["install.sh"]!]) { a, _ in a },
                                              extra: [:], run: "true"), "file names stay plain")

        let (center, _) = try owner(withTarget: true)
        let roster = try XCTUnwrap(center.broker(brokerKey.id)?.roster)
        let command = try XCTUnwrap(RemoteInstall.installCommand(staging: staging, files: files, roster: roster,
                                                                  linkAddress: "fe80::4a:4bff:fe00:1", sudoApprovals: false))
        // Without the sudo prefix, as this test's user.
        let prefix = "/usr/bin/sudo -k -S -p '' "
        XCTAssertTrue(command.hasPrefix(prefix))
        let output = try shell(String(command.dropFirst(prefix.count)))
        XCTAssertTrue(output.contains("args=--no-sudo /private/var/tmp/blitzkvm-install."), output)
        let lines = output.split(separator: "\n")
        let rosterLine = try XCTUnwrap(lines.first { $0.hasPrefix("{\"") && $0.contains("\"t\"") })
        XCTAssertEqual(try Wire.decoder.decode(Envelope.self, from: Data(rosterLine.utf8)), roster)
        XCTAssertTrue(output.contains(#"{"address":"fe80::4a:4bff:fe00:1"}"#), output)
        XCTAssertFalse(output.contains("odd name"), "only the hashed files are copied")
        XCTAssertTrue(lines.contains("blitzkvm-remote") && lines.contains("roster.json"), output)

        // Negative control: a file swapped after hashing.
        _ = try shell("printf 'evil' > \(RemoteInstall.quote(staging))/blitzkvm-remote")
        let refused = try shell(String(command.dropFirst(prefix.count)) + "; echo status=$?", allowFailure: true)
        XCTAssertTrue(refused.contains("the uploaded files changed"), refused)
        XCTAssertFalse(refused.contains("args="), refused)

        // A symlink in the user's staging directory isn't followed by root.
        _ = try shell("ln -sf /etc/hosts \(RemoteInstall.quote(staging))/blitzkvm-remote")
        let linked = try shell(String(command.dropFirst(prefix.count)) + "; echo status=$?", allowFailure: true)
        XCTAssertTrue(linked.contains("isn't a plain file"), linked)
        XCTAssertTrue(command.contains("exec </dev/null"), "the password line doesn't reach the steps")
    }

    /// The real remote/install/install.sh takes the options the app passes:
    /// run as this test's user, both steps get past its argument checks to
    /// its root check.
    func testInstallScriptTakesTheAppsOptions() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../remote/install/install.sh").standardized
        guard FileManager.default.fileExists(atPath: script.path) else { throw XCTSkip("no remote/install/install.sh") }
        let staging = try shell("mktemp -d /tmp/blitzkvm-remote.XXXXXX").trimmingCharacters(in: .whitespacesAndNewlines)
        defer { try? FileManager.default.removeItem(atPath: staging) }
        try FileManager.default.copyItem(atPath: script.path, toPath: staging + "/install.sh")
        _ = try shell("printf 'bin' > \(RemoteInstall.quote(staging))/blitzkvm-remote")
        var files: [String: String] = [:]
        for name in ["install.sh", "blitzkvm-remote"] {
            files[name] = try shell("shasum -a 256 \(RemoteInstall.quote(staging + "/" + name)) | cut -d' ' -f1")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let (center, _) = try owner(withTarget: true)
        let roster = try XCTUnwrap(center.broker(brokerKey.id)?.roster)
        let prefix = "/usr/bin/sudo -k -S -p '' "
        let commands = [RemoteInstall.identityCommand(staging: staging, files: files),
                        RemoteInstall.installCommand(staging: staging, files: files, roster: roster,
                                                     linkAddress: "fe80::4a:4bff:fe00:1", sudoApprovals: true),
                        RemoteInstall.installCommand(staging: staging, files: files, roster: roster,
                                                     linkAddress: "fe80::4a:4bff:fe00:1", sudoApprovals: false)]
        for command in commands {
            let output = try shell(String(try XCTUnwrap(command).dropFirst(prefix.count)), allowFailure: true)
            XCTAssertTrue(output.contains("install: run as root"), output)
        }
    }

    func testQuotingSurvivesTheShell() throws {
        let text = #"a'b"c $HOME `x` \n"#
        XCTAssertEqual(try shell("printf %s \(RemoteInstall.quote(text))"), text)
    }

    func testFailuresInASentence() {
        func explain(_ stderr: String, _ code: Int = 1) -> String {
            RemoteInstall.explain(HostLinkRun.Result(stdout: "", stderr: stderr, exitCode: code), user: "alex", computer: "Mac mini")
        }
        XCTAssertEqual(explain("Sorry, try again.\nsudo: no password was provided\nsudo: 1 incorrect password attempt"),
                       "The password of alex on Mac mini isn't right.")
        XCTAssertEqual(explain("alex is not in the sudoers file."), "alex isn't an administrator on Mac mini.")
        XCTAssertEqual(explain("install: missing /x/roster.json"), "Missing /x/roster.json.")
        XCTAssertEqual(explain("", 3), "A command on Mac mini failed (exit 3).")
        XCTAssertTrue(RemoteInstall.needsNoSudo(stderr: "install: /usr/local isn't root's; install with --no-sudo"))
    }

    func testHostLinkRunParameters() throws {
        let sync = ClipboardSync(user: "alex", computerName: "Mac mini", hostKey: "ssh-ed25519 AAAA")
        let params = HostLinkRun.params(sync: sync, privateKeyPath: "/k", command: "true", stdin: Data("pw\n".utf8), timeout: 30)
        XCTAssertEqual(params["stdin"], .string("cHcK"), "standard base64, as Go's []byte")
        XCTAssertEqual(params["timeout"], .number(30))
        XCTAssertEqual(params["hostKey"], .string("ssh-ed25519 AAAA"))
        let result = try JSONDecoder().decode(HostLinkRun.Result.self, from: Data(#"{"stdout":"a","stderr":"","exitCode":2}"#.utf8))
        XCTAssertEqual(result, HostLinkRun.Result(stdout: "a", stderr: "", exitCode: 2))
    }

    // MARK: Helpers

    @discardableResult
    private func shell(_ command: String, allowFailure: Bool = false) throws -> String {
        let p = Foundation.Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        if !allowFailure && p.terminationStatus != 0 { XCTFail("\(command): \(text)") }
        return text
    }
}
