import Darwin
import Foundation

public enum SocketError: Error, CustomStringConvertible {
    case resolve(String), system(String, Int32), timeout, pathTooLong(String)

    public var description: String {
        switch self {
        case .resolve(let s): return "can't resolve \(s)"
        case .system(let call, let e): return "\(call): \(String(cString: strerror(e)))"
        case .timeout: return "timed out"
        case .pathTooLong(let p): return "socket path longer than 103 bytes: \(p)"
        }
    }
}

/// Plain BSD sockets: the link is a scoped link-local TCP address
/// (`fe80::…%en7`), which getaddrinfo understands, and the local socket needs
/// the peer's credentials, which only getsockopt gives.
public enum Sockets {
    /// Connects to host:port (an IPv6 literal may carry a `%iface` scope).
    public static func connectTCP(host: String, port: UInt16, timeout: TimeInterval = 5) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_NUMERICSERV
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else { throw SocketError.resolve(host) }
        defer { freeaddrinfo(res) }
        var lastError = SocketError.resolve(host)
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            ai = a.pointee.ai_next
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            guard fd >= 0 else { lastError = .system("socket", errno); continue }
            do {
                try connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen, timeout: timeout)
                var one: Int32 = 1
                setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                noSigPipe(fd)
                return fd
            } catch let e as SocketError {
                lastError = e
                Darwin.close(fd)
            }
        }
        throw lastError
    }

    private static func connect(_ fd: Int32, _ addr: UnsafeMutablePointer<sockaddr>, _ len: socklen_t,
                                timeout: TimeInterval) throws {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        if Darwin.connect(fd, addr, len) != 0 {
            guard errno == EINPROGRESS else { throw SocketError.system("connect", errno) }
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let n = poll(&p, 1, Int32(timeout * 1000))
            guard n > 0 else { throw n == 0 ? SocketError.timeout : SocketError.system("poll", errno) }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { throw SocketError.system("connect", err) }
        }
        _ = fcntl(fd, F_SETFL, flags)
    }

    static func noSigPipe(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// A TCP listener on 127.0.0.1 (tests: the fake broker).
    public static func listenLoopback() throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0, listen(fd, 8) == 0 else { Darwin.close(fd); throw SocketError.system("bind", errno) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return (fd, UInt16(bigEndian: addr.sin_port))
    }

    // MARK: Unix domain

    static func unixAddress(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw SocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    /// Listens on a Unix socket that anyone may connect to: the daemon tells
    /// its peers apart by their credentials, not by file permissions.
    public static func listenUnix(path: String, mode: mode_t = 0o666) throws -> Int32 {
        var addr = try unixAddress(path)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { let e = errno; Darwin.close(fd); throw SocketError.system("bind \(path)", e) }
        chmod(path, mode)
        guard listen(fd, 16) == 0 else { let e = errno; Darwin.close(fd); throw SocketError.system("listen", e) }
        return fd
    }

    public static func connectUnix(path: String) throws -> Int32 {
        var addr = try unixAddress(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { let e = errno; Darwin.close(fd); throw SocketError.system("connect \(path)", e) }
        noSigPipe(fd)
        return fd
    }

    /// Accepts one connection (blocking); nil once the listener is closed.
    public static func accept(_ listener: Int32) -> Int32? {
        while true {
            let fd = Darwin.accept(listener, nil, nil)
            if fd >= 0 { noSigPipe(fd); return fd }
            if errno == EINTR || errno == ECONNABORTED { continue }
            return nil
        }
    }
}

/// Who is on the other end of a Unix socket, from the kernel.
public struct PeerCredentials: Equatable {
    public var uid: uid_t
    public var pid: pid_t
    public var auditToken: audit_token_t?

    public static func == (a: PeerCredentials, b: PeerCredentials) -> Bool { a.uid == b.uid && a.pid == b.pid }

    /// The peer's audit session: a child shares its parent's (the PAM
    /// client sudo's).
    public var session: Int32? { auditToken.map { audit_token_to_asid($0) } }

    public init(uid: uid_t, pid: pid_t, auditToken: audit_token_t? = nil) {
        self.uid = uid; self.pid = pid; self.auditToken = auditToken
    }

    public static func of(_ fd: Int32) -> PeerCredentials? {
        var cred = xucred()
        var len = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &len) == 0, cred.cr_version == XUCRED_VERSION else { return nil }
        var pid: pid_t = 0
        len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0 else { return nil }
        var token = audit_token_t()
        len = socklen_t(MemoryLayout<audit_token_t>.size)
        let haveToken = getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &len) == 0
        return PeerCredentials(uid: cred.cr_uid, pid: pid, auditToken: haveToken ? token : nil)
    }
}
