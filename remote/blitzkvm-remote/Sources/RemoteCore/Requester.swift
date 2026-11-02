import Darwin
import Foundation

/// The requester's side of the local socket (`confirm`, `pam`, tests): one
/// request, then info lines until the result. Blocking; no daemon, no
/// result in time, or a dropped connection is `unavailable`/`timeout`.
public enum RequesterClient {
    public static func request(socket: String, _ message: LocalMessage, timeout: TimeInterval, requireRoot: Bool = true,
                               info: (String) -> Void) -> (outcome: Outcome, text: String?) {
        guard let fd = try? Sockets.connectUnix(path: socket) else {
            return (.unavailable, "BlitzKVM: the approval daemon isn't running")
        }
        defer { close(fd) }
        // Whoever answers on the socket decides sudo: it must be root's daemon.
        if requireRoot, PeerCredentials.of(fd)?.uid != 0 {
            return (.unavailable, "BlitzKVM: the approval socket isn't root's")
        }
        guard var data = try? JSONEncoder.wire.encode(message) else { return (.refused, nil) }
        data.append(0x0A)
        let sent = data.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        guard sent else { return (.unavailable, "BlitzKVM: the approval daemon didn't listen") }

        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return (.timeout, "BlitzKVM: no answer in time") }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let n = poll(&p, 1, Int32(min(left, 3600) * 1000))
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { continue }
            let got = read(fd, &chunk, chunk.count)
            if got < 0 && errno == EINTR { continue }
            guard got > 0 else { return (.unavailable, "BlitzKVM: the approval daemon went away") }
            buffer.append(contentsOf: chunk[0..<got])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<nl])
                buffer = Data(buffer[(nl + 1)...])
                guard let m = try? JSONDecoder().decode(LocalMessage.self, from: line) else { continue }
                switch m.op {
                case "info": if let t = m.text { info(t) }
                case "result": return (Outcome(rawValue: m.result ?? "") ?? .unavailable, m.text)
                default: break
                }
            }
            if buffer.count > LineConn.maxLine { return (.unavailable, nil) }
        }
    }
}
