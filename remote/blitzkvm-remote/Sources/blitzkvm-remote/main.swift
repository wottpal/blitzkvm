import ApprovalKit
import Darwin
import Foundation
import RemoteCore

// blitzkvm-remote <mode>: the target side of BlitzKVM's remote approvals
// (remote/README.md).

let usage = """
    usage: blitzkvm-remote daemon [--user-mode] [--state DIR] [--socket PATH] [--link HOST:PORT] [--insecure-agent]
                                  [--print-identity | --install-roster FILE]
           blitzkvm-remote agent [--user-mode] [--socket PATH]
           blitzkvm-remote confirm QUESTION [--grant] [--timeout SECONDS] [--detail TEXT] [--user-mode] [--socket PATH]
           blitzkvm-remote pam --user U --service S --tty T --pid P [--state DIR] [--socket PATH]
    """

/// `--flag`, `--key value` and positionals, in any order.
struct Options {
    var flags = Set<String>()
    var values: [String: String] = [:]
    var positionals: [String] = []

    static let valued: Set<String> = ["--state", "--socket", "--link", "--install-roster", "--timeout", "--detail",
                                      "--user", "--service", "--tty", "--pid"]

    init(_ args: ArraySlice<String>) throws {
        var it = args.makeIterator()
        while let a = it.next() {
            if Self.valued.contains(a) {
                guard let v = it.next() else { throw OptionError("\(a) needs a value") }
                values[a] = v
            } else if a.hasPrefix("--") {
                flags.insert(a)
            } else {
                positionals.append(a)
            }
        }
    }

    var userMode: Bool { flags.contains("--user-mode") }

    var paths: Paths {
        var p = userMode ? Paths.user() : Paths.system
        if let state = values["--state"] {
            p.state = URL(fileURLWithPath: state)
            if userMode { p.socket = p.state.appendingPathComponent("blitzkvm-remote.sock").path }
        }
        if let socket = values["--socket"] { p.socket = socket }
        return p
    }
}

struct OptionError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func fail(_ message: String, _ status: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(status)
}

func runDaemon(_ o: Options) -> Never {
    guard o.userMode || geteuid() == 0 else { fail("blitzkvm-remote daemon: run as root, or with --user-mode") }
    let paths = o.paths
    let store = TargetStore(paths: paths)
    if o.flags.contains("--print-identity") {
        do {
            let data = try JSONEncoder.wire.encode(try store.identity())
            print(String(decoding: data, as: UTF8.self))
            exit(0)
        } catch { fail("blitzkvm-remote: \(error)", 1) }
    }
    if let file = o.values["--install-roster"] {
        do {
            let env = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
            let roster = try store.installGenesis(env, targetID: try store.loadOrCreateKey().id)
            print("installed roster \(roster.seq) (\(roster.approvers.count) approvers)")
            exit(0)
        } catch { fail("blitzkvm-remote: the roster wasn't installed: \(error)", 1) }
    }

    var config = Daemon.Config(paths: paths)
    config.userMode = o.userMode
    if let link = o.values["--link"] {
        guard let endpoint = HostLink.Endpoint.parse(link) else { fail("blitzkvm-remote: --link wants HOST:PORT") }
        config.endpoint = endpoint
    }
    // The agent's word drives clicks: it must be signed like this daemon.
    if let team = CodeSigning.ownIdentity()?.team { config.agentRequirement = CodeSigning.agentRequirement(team: team) }
    config.insecureAgent = o.flags.contains("--insecure-agent")
    if config.insecureAgent {
        Log.info("WARNING: --insecure-agent: any local process may act as the agent and steer screen asks; for tests only")
    } else if config.agentRequirement == nil {
        Log.info("WARNING: this daemon isn't signed with a Developer ID, so no agent is trusted: screen asks are unavailable")
    }
    let daemon: Daemon
    do {
        daemon = try Daemon(config: config)
        try daemon.start()
    } catch { fail("blitzkvm-remote daemon: \(error)", 1) }
    signal(SIGPIPE, SIG_IGN)
    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            daemon.stop()
            exit(0)
        }
        source.resume()
        keep.append(source)
    }
    dispatchMain()
}

var keep: [Any] = []

func runConfirm(_ o: Options) -> Never {
    guard let question = o.positionals.first, !question.isEmpty else { fail(usage) }
    let timeout = Int(o.values["--timeout"] ?? "60") ?? 60
    // The protocol caps both at 2048 bytes; the daemon clips them too.
    let message = LocalMessage(op: "confirm", title: question.clipped(bytes: 2048), detail: o.values["--detail"]?.clipped(bytes: 2048),
                               grant: o.flags.contains("--grant"), timeout: timeout)
    let (outcome, text) = RequesterClient.request(socket: o.paths.socket, message, timeout: TimeInterval(min(max(timeout, 10), 120) + 15)) {
        FileHandle.standardError.write(Data((Display.safe($0, maxBytes: 1024) + "\n").utf8))
    }
    if let text, !text.isEmpty { FileHandle.standardError.write(Data((Display.safe(text, maxBytes: 1024) + "\n").utf8)) }
    exit(outcome.confirmExit)
}

/// Run as root by pam_blitzkvm.so inside sudo: its stdout goes to the
/// user's terminal line by line; exit 0 only on a verified approval.
func runPam(_ o: Options) -> Never {
    let paths = o.paths
    if TargetStore(paths: paths).inMaintenance { exit(3) }
    guard let pidString = o.values["--pid"], let pid = Int32(pidString) else { fail(usage) }
    setvbuf(stdout, nil, _IOLBF, 0)
    let message = LocalMessage(op: "pam", user: o.values["--user"], service: o.values["--service"], tty: o.values["--tty"], pid: pid)
    let (outcome, text) = RequesterClient.request(socket: paths.socket, message, timeout: 65) { print(Display.safe($0, maxBytes: 1024)) }
    if outcome == .unavailable && text == "BlitzKVM: the approval daemon isn't running" { exit(2) }
    if let text, !text.isEmpty { print(Display.safe(text, maxBytes: 1024)) }
    exit(outcome == .approved ? 0 : outcome == .denied ? 1 : 2)
}

let args = CommandLine.arguments.dropFirst()
guard let mode = args.first else { fail(usage) }
let options: Options
do { options = try Options(args.dropFirst()) } catch { fail("blitzkvm-remote: \(error)\n\(usage)") }
switch mode {
case "daemon": runDaemon(options)
case "agent":
    Log.toStderr = isatty(STDERR_FILENO) != 0
    Agent(socket: options.paths.socket, checkServerIsRoot: !options.userMode).run()
case "confirm": runConfirm(options)
case "pam": runPam(options)
default: fail(usage)
}
