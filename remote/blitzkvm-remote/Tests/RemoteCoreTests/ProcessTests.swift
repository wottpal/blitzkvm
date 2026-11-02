import ApprovalKit
import XCTest
@testable import RemoteCore

final class ProcessTests: XCTestCase {
    /// The chain of this test process, as the daemon would read it.
    func testChainOfThisProcess() throws {
        let chain = Chain.build(from: getpid(), inspector: SystemProcesses())
        XCTAssertFalse(chain.isEmpty)
        XCTAssertLessThanOrEqual(chain.count, Chain.maxLength)
        let me = chain[0]
        XCTAssertEqual(me.pid, getpid())
        XCTAssertEqual(me.uid, getuid())
        XCTAssertEqual(me.process.path.map { URL(fileURLWithPath: $0).lastPathComponent }, me.name)
        XCTAssertEqual(me.process.args?.first.map { URL(fileURLWithPath: $0).lastPathComponent },
                       URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent)
        XCTAssertNotNil(me.process.signer)
        XCTAssertGreaterThan(me.start, 1_700_000_000)
        if chain.count > 1 { XCTAssertEqual(chain[1].pid, getppid()) }
        // Every signer is one of the protocol's.
        for e in chain {
            let s = e.process.signer ?? ""
            XCTAssertTrue(["apple", "adhoc", "unsigned"].contains(s) || s.hasPrefix("developer:"), s)
        }
    }

    /// A child of this process, a platform binary.
    func testSigners() throws {
        let sleep = Foundation.Process()
        sleep.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleep.arguments = ["5"]
        try sleep.run()
        defer { sleep.terminate() }
        let id = try XCTUnwrap(CodeSigning.identity(pid: sleep.processIdentifier))
        XCTAssertTrue(id.apple)
        XCTAssertEqual(id.identifier, "com.apple.sleep")
        XCTAssertEqual(id.signer, "apple")
        XCTAssertTrue(id.isApple(["com.apple.sleep"]))
        XCTAssertFalse(id.isApple(Holders.securityAgent))
        XCTAssertFalse(id.isDeveloper(team: OnePassword.team, identifier: OnePassword.bundle))
    }

    func testProcArgs() {
        var buf: [UInt8] = []
        withUnsafeBytes(of: Int32(3)) { buf.append(contentsOf: $0) }
        buf += Array("/usr/bin/sudo".utf8) + [0, 0, 0, 0]
        for a in ["sudo", "shutdown", "-r"] { buf += Array(a.utf8) + [0] }
        buf += Array("PATH=/usr/bin".utf8) + [0] // the environment: never read
        XCTAssertEqual(Processes.parseProcArgs(buf), ["sudo", "shutdown", "-r"])
    }

    func testArgsAreClippedAndSafe() {
        let clipped = Chain.clipArgs(["x"] + Array(repeating: String(repeating: "a", count: 300), count: 40))
        XCTAssertLessThanOrEqual(clipped.count, 25)
        XCTAssertTrue(clipped.allSatisfy { $0.utf8.count <= 200 })
        XCTAssertEqual(clipped.last, Display.truncated)
        XCTAssertEqual(Chain.clipArgs(["echo", "a\nb", "\u{1b}[2J"]), ["echo", "a\\nb", "\\x1b[2J"])
    }

    /// Wrappers live where the system keeps them; anything else in /x.
    func entry(_ pid: Int32, _ name: String, start: Double = 100, path: String? = nil) -> ChainEntry {
        let bare = name.hasPrefix("-") ? String(name.dropFirst()) : name
        let place = Chain.wrappers.contains(bare.lowercased()) ? "/bin/\(bare)" : "/x/\(name)"
        return ChainEntry(process: ApprovalKit.Process(pid: Int(pid), name: name, path: path ?? place), uid: 501, start: start)
    }

    /// A process names itself: a binary called zsh outside the system's
    /// directories is no wrapper, and an editor's extension host never anchors.
    func testRenamedWrappersAndMultiTenantHosts() {
        let fake = entry(899, "zsh", path: "/Users/alex/.cache/zsh")
        XCTAssertEqual(Chain.anchor([entry(900, "sudo"), fake, entry(700, "node")])?.pid, 899)
        XCTAssertNil(Chain.anchor([entry(900, "sudo"), entry(899, "zsh"),
                                   entry(700, "Code Helper (Plugin)", path: "/Applications/Visual Studio Code.app/x/Code Helper (Plugin)")]))
    }

    /// A parent that started after its child is a reused pid: the chain stops.
    func testChainStopsAtAYoungerParent() {
        let procs = FakeProcesses()
        procs.add(ProcInfo(pid: 900, ppid: 899, uid: 501, comm: "sudo", start: 200))
        procs.add(ProcInfo(pid: 899, ppid: 1, uid: 501, comm: "node", start: 300))
        XCTAssertEqual(Chain.build(from: 900, inspector: procs).map(\.pid), [900])
    }

    func testAnchorSkipsShellsAndWrappers() {
        // sudo ← zsh ← env ← node (an agent) ← zsh ← Terminal
        let chain = [entry(900, "sudo"), entry(899, "zsh"), entry(898, "env"), entry(700, "node"), entry(600, "zsh"),
                     entry(500, "Terminal")]
        XCTAssertEqual(Chain.anchor(chain), Anchor(pid: 700, start: 100, name: "node"))
        XCTAssertEqual(Chain.summary(chain), "sudo ← zsh ← env ← node ← zsh ← Terminal")
        XCTAssertTrue(Chain.reachesShell(chain))
        // Only shells up to launchd: nothing to anchor a grant to.
        XCTAssertNil(Chain.anchor([entry(900, "sudo"), entry(899, "zsh"), entry(800, "sshd-session"), entry(1, "launchd")]))
        XCTAssertNil(Chain.anchor([entry(900, "sudo")]))
        // The requesting tool itself never anchors, even when it isn't a shell.
        XCTAssertEqual(Chain.anchor([entry(900, "blitzkvm-remote"), entry(700, "python3")])?.pid, 700)
    }

    /// A person's terminal is no anchor: every tab would share the grant.
    /// Reaching one first means approve once.
    func testTerminalsAndMultiplexersNeverAnchor() {
        for terminal in [entry(500, "Terminal"), entry(500, "iTerm2"), entry(500, "ghostty"), entry(500, "wezterm-gui"),
                         entry(500, "alacritty"), entry(500, "kitty"), entry(500, "tmux"), entry(500, "screen"),
                         entry(500, "zellij"), entry(500, "Hyper"),
                         entry(500, "stable", path: "/Applications/Warp.app/Contents/MacOS/stable")] {
            XCTAssertNil(Chain.anchor([entry(900, "sudo"), entry(899, "zsh"), terminal, entry(400, "node")]), terminal.name)
            XCTAssertTrue(Chain.isTerminal(terminal), terminal.name)
        }
        XCTAssertNil(Chain.anchor([entry(900, "sudo"), entry(899, "-zsh"), entry(898, "login"), entry(500, "Terminal")]))
        XCTAssertFalse(Chain.isTerminal(entry(700, "node")))
    }

    func testGrantScope() {
        var grants = Grants()
        let agent = Anchor(pid: 700, start: 100, name: "node")
        func key(kind: String = Kind.sudo, uid: uid_t = 501, anchor: Anchor = agent, tty: String? = "ttys003",
                 session: Int32? = 100_017) -> Grants.Key {
            Grants.Key(kind: kind, uid: uid, anchor: anchor, tty: tty, session: session)
        }
        grants.add(key(), minutes: 10, now: 1000)
        XCTAssertTrue(grants.covers(key(), now: 1001))
        // Another anchor, a reused pid (other start time), another user, kind,
        // terminal or audit session: ask again.
        XCTAssertFalse(grants.covers(key(anchor: Anchor(pid: 701, start: 100, name: "node")), now: 1001))
        XCTAssertFalse(grants.covers(key(anchor: Anchor(pid: 700, start: 200, name: "node")), now: 1001))
        XCTAssertFalse(grants.covers(key(uid: 502), now: 1001))
        XCTAssertFalse(grants.covers(key(kind: Kind.confirm), now: 1001))
        XCTAssertFalse(grants.covers(key(tty: "ttys004"), now: 1001))
        XCTAssertFalse(grants.covers(key(tty: nil), now: 1001))
        XCTAssertFalse(grants.covers(key(session: 100_018), now: 1001))
        // Ten minutes, then it's over.
        XCTAssertTrue(grants.covers(key(), now: 1599))
        XCTAssertFalse(grants.covers(key(), now: 1600))
        XCTAssertEqual(grants.count, 0)
    }

    func testClippedText() {
        let s = String(repeating: "ä", count: 2000) // 4000 bytes
        let c = s.clipped(bytes: 2048)
        XCTAssertLessThanOrEqual(c.utf8.count, 2048)
        XCTAssertTrue(c.hasSuffix("…(truncated)"))
        XCTAssertEqual("short".clipped(bytes: 2048), "short")
    }

    func testSessionOfAPeer() throws {
        // A socket pair to itself: the peer's audit session is this process's.
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        let peer = try XCTUnwrap(PeerCredentials.of(fds[0]))
        XCTAssertEqual(peer.pid, getpid())
        XCTAssertNotNil(peer.session)
    }
}

final class DisplayTests: XCTestCase {
    func testControlsBecomeVisible() {
        XCTAssertEqual(Display.safe("a\nb\tc\rd"), "a\\nb\\tc\\rd")
        XCTAssertEqual(Display.safe("\u{1b}[31mred\u{7}"), "\\x1b[31mred\\x07")
        // Separators would fake a line, invisible characters hide letters.
        XCTAssertEqual(Display.safe("a\u{2028}b\u{200B}c\u{E0041}"), "a\\u{2028}b\\u{200B}c\\u{E0041}")
        XCTAssertEqual(Display.safe("\u{7f}\u{85}\u{9b}"), "\\x7f\\x85\\x9b") // DEL and C1
        XCTAssertEqual(Display.safe("plain ünïcödé ✓"), "plain ünïcödé ✓")
    }

    /// Right-to-left overrides could make `rm -rf ~/x` read as something else.
    func testBidiControlsAreEscaped() {
        XCTAssertEqual(Display.safe("abc\u{202E}fed"), "abc\\u{202E}fed")
        for c: UInt32 in [0x200E, 0x200F, 0x061C, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069] {
            let s = Display.safe("x" + String(UnicodeScalar(c)!) + "y")
            XCTAssertFalse(s.unicodeScalars.contains { $0.value == c }, String(c, radix: 16))
        }
    }

    func testCommandsAreShellQuoted() {
        XCTAssertEqual(Display.command(["sudo", "shutdown", "-r", "now"]), "sudo shutdown -r now")
        XCTAssertEqual(Display.command(["sudo", "rm", "-rf", "/tmp/a b"]), "sudo rm -rf '/tmp/a b'")
        XCTAssertEqual(Display.command(["echo", "it's", "\"q\"", ""]), "echo 'it'\\''s' '\"q\"' ''")
        // One argument can't pose as two lines or two commands.
        XCTAssertEqual(Display.command(["sh", "-c", "true\nrm -rf ~"]), "sh -c 'true\\nrm -rf ~'")
        XCTAssertEqual(Display.command(["a;b", "$(x)"]), "'a;b' '$(x)'")
    }

    func testTruncationIsMarked() {
        let long = Display.safe(String(repeating: "\u{1b}", count: 1000), maxBytes: 100)
        XCTAssertLessThanOrEqual(long.utf8.count, 100)
        XCTAssertTrue(long.hasSuffix("…(truncated)"))
        XCTAssertTrue(long.dropLast("…(truncated)".count).hasSuffix("\\x1b"), "an escape is never cut in half")
        let cmd = Display.command(["sudo"] + Array(repeating: "argument", count: 500), maxBytes: 2048)
        XCTAssertLessThanOrEqual(cmd.utf8.count, 2048)
        XCTAssertTrue(cmd.hasSuffix("…(truncated)"))
    }
}

final class ConsoleTests: XCTestCase {
    func testParse() {
        let other: [String: Any] = ["kCGSSessionOnConsoleKey": false, "kCGSSessionUserIDKey": 502, "kCGSSessionSecureInputPID": 9]
        let console: [String: Any] = ["kCGSSessionOnConsoleKey": true, "kCGSSessionUserIDKey": 501,
                                      "kCGSSessionUserNameKey": "user"]
        XCTAssertEqual(Console.parse([other, console]), ConsoleState(uid: 501))
        var locked = console
        locked["CGSSessionScreenIsLocked"] = true
        locked["kCGSSessionSecureInputPID"] = 7000
        XCTAssertEqual(Console.parse([locked]), ConsoleState(uid: 501, locked: true, secureInputPID: 7000))
        XCTAssertEqual(Console.parse([other]), ConsoleState())
        XCTAssertEqual(Console.parse([]), ConsoleState())
    }

    /// The real registry reads without a permission (values vary).
    func testReadsTheRegistry() {
        _ = Console.read()
    }
}

final class StoreTests: XCTestCase {
    func testKeyAndGenesis() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TargetStore(paths: Paths(state: dir, socket: dir.appendingPathComponent("s").path))
        let key = try store.loadOrCreateKey()
        XCTAssertEqual(try store.loadOrCreateKey().id, key.id, "the key is made once")
        var st = stat()
        XCTAssertEqual(stat(store.paths.key.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        let identity = try store.identity()
        XCTAssertEqual(identity.id, Wire.kid(identity.key.data))

        let world = World(target: key.publicKey)
        // A genesis must name this target and be signed by one of its owners.
        let elsewhere = World(target: SoftwareSigner().publicKey)
        XCTAssertThrowsError(try store.installGenesis(elsewhere.roster(seq: 1), targetID: key.id))
        XCTAssertThrowsError(try store.installGenesis(world.roster(seq: 1, signer: world.b.presence), targetID: key.id))
        XCTAssertNil(store.loadRoster())
        try store.installGenesis(world.roster(seq: 1), targetID: key.id)
        XCTAssertEqual(store.loadRoster()?.roster.seq, 1)
    }

    func testEndpoint() {
        XCTAssertEqual(HostLink.Endpoint.parse("127.0.0.1:4023"), .fixed(host: "127.0.0.1", port: 4023))
        XCTAssertEqual(HostLink.Endpoint.parse("[fe80::1%en7]:4023"), .fixed(host: "fe80::1%en7", port: 4023))
        XCTAssertNil(HostLink.Endpoint.parse("nope"))
        let link = HostLink.Endpoint.link(HostLink.Config(address: "fe80::4a:4bff:fe00:1"))
        XCTAssertEqual(link.resolve(interface: { "en7" })?.host, "fe80::4a:4bff:fe00:1%en7")
        XCTAssertEqual(link.resolve(interface: { "en7" })?.port, 4023)
        XCTAssertNil(link.resolve(interface: { nil }), "no link interface, nothing to dial")
        XCTAssertNil(HostLink.Endpoint.link(HostLink.Config(address: "192.168.1.40")).resolve(interface: { "en7" }))
        // This Mac has no JetKVM link (or does: either way it doesn't crash).
        _ = HostLink.interface()
        XCTAssertNil(HostLink.interface(mac: [0x02, 0, 0, 0, 0, 0x99]))
    }
}
