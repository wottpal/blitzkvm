import Darwin
import Foundation

/// Newline-delimited JSON over a socket: a reader thread hands each line to
/// `queue`, and writes block for at most `sendTimeout` (a peer that doesn't
/// read loses its connection rather than stalling the daemon).
public final class LineConn {
    public static let maxLine = 64 << 10

    public let fd: Int32
    private let queue: DispatchQueue
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var closed = false
    private var onLine: ((Data) -> Void)?
    private var onClose: (() -> Void)?

    public init(fd: Int32, queue: DispatchQueue, sendTimeout: TimeInterval = 5) {
        self.fd = fd
        self.queue = queue
        var tv = timeval(tv_sec: Int(sendTimeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Starts reading. Both callbacks run on `queue`; `onClose` runs once,
    /// after the last line.
    public func start(onLine: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        self.onLine = onLine
        self.onClose = onClose
        let t = Thread { [self] in readLoop() }
        t.name = "LineConn \(fd)"
        t.start()
    }

    private func readLoop() {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 << 10)
        loop: while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[(nl + 1)...])
                guard line.count <= Self.maxLine else { break loop }
                if !line.isEmpty {
                    let copy = Data(line)
                    queue.async { [weak self] in self?.onLine?(copy) }
                }
            }
            if buffer.count > Self.maxLine { break }
        }
        close()
        // The reader owns the descriptor; no write is under way once it
        // holds the write lock, and none starts after `closed`.
        writeLock.lock()
        Darwin.close(fd)
        writeLock.unlock()
        queue.async { [self] in
            onClose?()
            onLine = nil
            onClose = nil
        }
    }

    /// Sends one JSON object as a line; false once the connection is gone.
    @discardableResult
    public func send<T: Encodable>(_ message: T) -> Bool {
        guard var data = try? JSONEncoder.wire.encode(message) else { return false }
        data.append(0x0A)
        return sendRaw(data)
    }

    @discardableResult
    public func sendRaw(_ data: Data) -> Bool {
        guard data.count <= Self.maxLine + 1 else { return false }
        writeLock.lock()
        defer { writeLock.unlock() }
        if isClosed { return false }
        var ok = true
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { ok = false; return }
                off += n
            }
        }
        if !ok { close() }
        return ok
    }

    public var isClosed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed
    }

    /// Ends the connection; the reader then closes the descriptor.
    public func close() {
        stateLock.lock()
        let was = closed
        closed = true
        stateLock.unlock()
        if !was { shutdown(fd, SHUT_RDWR) }
    }
}

extension JSONEncoder {
    /// Compact JSON without escaped slashes, like the protocol's examples.
    public static let wire: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return e
    }()
}
