import ApprovalKit
import CryptoKit
import Security
import XCTest
@testable import RemoteCore

/// Owners' update and removal orders: only an owner's presence key, for this
/// target, fresh and once, with exactly the files it signed, signed like the
/// daemon, starts the job. Each refusal leaves nothing to run.
final class MaintainTests: XCTestCase {
    var dir: URL!
    var stage: URL!
    var jobs: URL!
    var paths: Paths!
    var target: SoftwareSigner!
    var world: World!
    var daemon: Daemon!
    var launched: [(dir: URL, script: String, files: [String: Data])] = []
    var codeOK = true
    var team: String? = "ABCDE12345"

    override func setUpWithError() throws {
        Log.toStderr = false
        dir = makeTempDir()
        jobs = makeTempDir()
        var template = Array("/tmp/blitzkvm-remote.XXXXXX".utf8CString)
        stage = URL(fileURLWithPath: String(cString: try XCTUnwrap(mkdtemp(&template))))
        paths = Paths(state: dir, socket: dir.appendingPathComponent("s").path)
        let store = TargetStore(paths: paths)
        target = try store.loadOrCreateKey()
        world = World(target: target.publicKey)
        try store.installGenesis(world.roster(seq: 1), targetID: target.id)
    }

    override func tearDown() {
        daemon?.stop()
        for url in [dir, stage, jobs] { try? FileManager.default.removeItem(at: url!) }
    }

    func startDaemon() throws {
        var config = Daemon.Config(paths: paths)
        config.userMode = true
        config.endpoint = .fixed(host: "127.0.0.1", port: 9) // no broker needed
        config.maintainTeam = team
        config.maintainRoot = MaintainRoot(jobs)
        config.codeCheck = { [unowned self] _, requirement in
            XCTAssertTrue(requirement.contains("certificate leaf[subject.OU] = \"ABCDE12345\""))
            return codeOK
        }
        config.launchMaintenance = { [unowned self] dir in
            var files: [String: Data] = [:]
            for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
                files[name] = try Data(contentsOf: dir.appendingPathComponent(name))
            }
            launched.append((dir, String(decoding: files["run.sh"] ?? Data(), as: UTF8.self), files))
        }
        daemon = try Daemon(config: config)
        try daemon.start()
    }

    /// Stages the update's files; returns their hashes.
    func stageFiles(_ names: Set<String> = MaintainOrder.updateFiles) throws -> [String: String] {
        var hashes: [String: String] = [:]
        for name in names {
            let data = Data("contents of \(name)".utf8)
            try data.write(to: stage.appendingPathComponent(name))
            hashes[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return hashes
    }

    func order(_ action: String = MaintainOrder.update, files: [String: String], signer: SoftwareSigner? = nil,
               target: String? = nil, issued: Int64 = now()) throws -> Envelope {
        let o = MaintainOrder(broker: world.brokerInfo.id, target: target ?? self.target.id, action: action, stage: stage.path,
                              files: files, issued: issued)
        return try Envelope.sign(o, type: "maintain", with: signer ?? world.a.presence)
    }

    func send(_ env: Envelope) -> (outcome: Outcome, text: String?)? {
        PendingResult(socket: paths.socket, LocalMessage(op: "maintain", order: env)).wait()
    }

    func testAnOwnersUpdateRunsInstallFromRootsCopy() throws {
        try startDaemon()
        let files = try stageFiles()
        let env = try order(files: files)
        XCTAssertEqual(send(env)?.outcome, .approved)
        let job = try XCTUnwrap(launched.first)
        XCTAssertTrue(job.dir.path.hasPrefix(jobs.path), "the job runs from root's directory, not the staging one")
        for name in MaintainOrder.updateFiles {
            XCTAssertEqual(job.files[name], Data("contents of \(name)".utf8))
        }
        XCTAssertTrue(job.script.contains("/bin/sh install.sh --update \"$d\""))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("maintain.status"), encoding: .utf8), "running\n")
        // The script is valid sh.
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/sh")
        check.arguments = ["-n", job.dir.appendingPathComponent("run.sh").path]
        try check.run()
        check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 0)
        // The same order again is a replay.
        XCTAssertEqual(send(env)?.outcome, .refused)
        XCTAssertEqual(launched.count, 1)
    }

    /// The job's script, run here (without its launchd and system log
    /// lines): install.sh's outcome lands in the status file the app reads,
    /// and the job's directory goes.
    func testTheJobReportsHowItWent() throws {
        try startDaemon()
        for (script, want) in [("echo 'install: done'\nexit 0\n", "done"), ("echo 'install: /usr/local is writable by others' >&2\nexit 1\n",
                                                                         "failed: install: /usr/local is writable by others")] {
            launched.removeAll()
            var files = try stageFiles()
            let data = Data(script.utf8)
            try data.write(to: stage.appendingPathComponent("install.sh"))
            files["install.sh"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(send(try order(files: files))?.outcome, .approved)
            let job = try XCTUnwrap(launched.first)
            let local = job.script.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.contains("launchctl") && !$0.contains("/Library/Logs") }.joined(separator: "\n")
            let run = Process()
            run.executableURL = URL(fileURLWithPath: "/bin/sh")
            run.arguments = ["-c", local]
            try run.run()
            run.waitUntilExit()
            XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("maintain.status"), encoding: .utf8), want + "\n")
            XCTAssertFalse(FileManager.default.fileExists(atPath: job.dir.path), "the job's directory goes")
        }
    }

    func testRemovalRunsUninstall() throws {
        try startDaemon()
        let files = try stageFiles(MaintainOrder.removeFiles)
        XCTAssertEqual(send(try order(MaintainOrder.remove, files: files))?.outcome, .approved)
        XCTAssertTrue(try XCTUnwrap(launched.first).script.contains("/bin/sh uninstall.sh"))
    }

    /// Each attack is refused, and nothing is left to run.
    func testOrdersThatDontCheckOutAreRefused() throws {
        try startDaemon()
        let files = try stageFiles()
        let attacks: [(String, Envelope)] = [
            ("a non-owner approver", try order(files: files, signer: world.b.presence)),
            ("the owner's transport key (no Touch ID)", try order(files: files, signer: world.a.transport)),
            ("a key outside the roster", try order(files: files, signer: SoftwareSigner())),
            ("another target", try order(files: files, target: SoftwareSigner().id)),
            ("an old order", try order(files: files, issued: now() - 300)),
            ("a file left out", try order(files: files.filter { $0.key != "pam_blitzkvm.so" })),
            ("a file too many", try order(files: files.merging(["extra.sh": String(repeating: "0", count: 64)]) { a, _ in a })),
            ("an unknown action", try order("reboot", files: files)),
        ]
        for (what, env) in attacks {
            XCTAssertEqual(send(env)?.outcome, .refused, what)
        }
        XCTAssertTrue(launched.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: jobs.path), [], "no job directory left")
    }

    /// The staging directory is the user's: a file changed after the owner
    /// signed, or swapped for a link, is refused.
    func testStagedFilesAreCheckedAfterTheCopy() throws {
        try startDaemon()
        var files = try stageFiles()
        try Data("#!/bin/sh\nevil\n".utf8).write(to: stage.appendingPathComponent("install.sh"))
        XCTAssertEqual(send(try order(files: files))?.outcome, .refused)

        files = try stageFiles()
        let elsewhere = jobs.appendingPathComponent("same-contents")
        try Data("contents of install.sh".utf8).write(to: elsewhere)
        try FileManager.default.removeItem(at: stage.appendingPathComponent("install.sh"))
        try FileManager.default.createSymbolicLink(at: stage.appendingPathComponent("install.sh"), withDestinationURL: elsewhere)
        XCTAssertEqual(send(try order(files: files))?.outcome, .refused, "a link, even to the right contents")
        XCTAssertTrue(launched.isEmpty)
    }

    func testBinariesMustBeSignedLikeTheDaemon() throws {
        codeOK = false
        try startDaemon()
        XCTAssertEqual(send(try order(files: try stageFiles()))?.outcome, .refused)
        XCTAssertTrue(launched.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: jobs.path), [])
    }

    func testADaemonWithoutDeveloperIDTakesNoOrders() throws {
        team = nil
        try startDaemon()
        XCTAssertEqual(send(try order(files: try stageFiles()))?.outcome, .unavailable)
        XCTAssertTrue(launched.isEmpty)
    }

    /// The real check, on the signed build (remote/build, from make -C remote):
    /// its own team passes, another team or another identifier doesn't.
    func testSignatureCheckOnTheSignedBuild() throws {
        let build = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build")
        let binary = build.appendingPathComponent("blitzkvm-remote"), pam = build.appendingPathComponent("pam_blitzkvm.so")
        var code: SecStaticCode?
        var info: CFDictionary?
        guard FileManager.default.fileExists(atPath: binary.path),
              SecStaticCodeCreateWithPath(binary as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String else {
            throw XCTSkip("no Developer ID build in remote/build")
        }
        let wanted = Maintenance.requirements(team: team)
        XCTAssertTrue(Maintenance.satisfies(binary, requirement: wanted["blitzkvm-remote"]!))
        XCTAssertTrue(Maintenance.satisfies(pam, requirement: wanted["pam_blitzkvm.so"]!))
        XCTAssertFalse(Maintenance.satisfies(binary, requirement: Maintenance.requirements(team: "ZZZZZZZZZZ")["blitzkvm-remote"]!))
        XCTAssertFalse(Maintenance.satisfies(binary, requirement: wanted["pam_blitzkvm.so"]!), "another identifier")
        XCTAssertFalse(Maintenance.satisfies(build.appendingPathComponent("install.sh"), requirement: wanted["blitzkvm-remote"]!))
    }
}
