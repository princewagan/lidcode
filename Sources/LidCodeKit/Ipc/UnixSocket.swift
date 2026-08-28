import Foundation

/// Shared low-level helpers for AF_UNIX stream sockets.
enum UnixSocket {
    /// `sun_path` is a fixed 104-byte buffer; anything longer is silently truncated,
    /// so refuse it loudly instead.
    static let maxPathLength = 103

    static func makeAddress(_ path: String) -> sockaddr_un? {
        guard path.utf8.count <= maxPathLength else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // Capacity is read up front: touching `addr.sun_path` inside the closure
        // would overlap with the exclusive access the closure already holds.
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                strncpy(dst, path, UnixSocket.maxPathLength)
            }
        }
        return addr
    }

    static func withSockAddr<T>(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                body(generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// Why a read stopped. A timeout and a closed peer are the same `nil` to the
    /// kernel-facing code but very different facts to the caller: a closed socket means
    /// reconnect, a timeout means the peer is *there* and not answering — which for the
    /// root helper is the difference between "not installed" and "wedged".
    ///
    /// Distinguishing them is not cosmetic. `HelperClient`'s heartbeat treats any
    /// failure as "stand down from closed-lid", and a wedged helper has to reach that
    /// path rather than blocking the caller forever.
    enum ReadOutcome {
        case line(Data)
        /// EOF, or an error that is not a timeout.
        case closed
        case timedOut
    }

    /// Read until newline.
    static func readLine(fd: Int32, buffer: inout Data) -> ReadOutcome {
        while true {
            if let index = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<index]
                buffer = Data(buffer[buffer.index(after: index)...])
                return .line(Data(line))
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                continue
            }
            // 0 is a clean EOF. -1 with EAGAIN/EWOULDBLOCK is `SO_RCVTIMEO` firing;
            // EINTR is a signal, which is not a failure at all — retry it, or a stray
            // SIGCHLD from `ShellCommand` would look like a dropped connection.
            guard count < 0 else { return .closed }
            switch errno {
            case EINTR:                     continue
            case EAGAIN, EWOULDBLOCK:       return .timedOut
            default:                        return .closed
            }
        }
    }

    /// Returns nil on success, or the error that stopped it.
    @discardableResult
    static func writeAll(fd: Int32, data: Data) -> SocketError? {
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(fd, base, remaining.count)
            }
            if written > 0 {
                remaining = Data(remaining.dropFirst(written))
                continue
            }
            guard written < 0 else { return .closed }
            switch errno {
            case EINTR:                     continue
            case EAGAIN, EWOULDBLOCK:       return .timedOut
            default:                        return .closed
            }
        }
        return nil
    }

    /// Bound **both** directions, not just receive.
    ///
    /// A send timeout looks unnecessary for line-sized JSON over a local socket, and it
    /// is — right up until the peer stops reading. Then the kernel's send buffer fills,
    /// `write()` blocks with no deadline, and whichever queue the caller was on is gone
    /// for good. That queue is the runtime's, and losing it freezes the menu bar.
    static func setTimeout(fd: Int32, second: Int) {
        var tv = timeval(tv_sec: second, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, size)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, size)
    }

    /// `connect()` with a deadline.
    ///
    /// `SO_SNDTIMEO` does not bound a blocking `connect()` on Darwin, so the descriptor
    /// is put in non-blocking mode for the call and raced with `poll()`. An AF_UNIX
    /// connect to a live listener completes immediately; the case worth defending
    /// against is a socket file whose owner is alive but wedged, where the connect sits
    /// in the listen backlog indefinitely — the root helper, on a bad day.
    ///
    /// Blocking mode is restored afterwards so the `SO_RCVTIMEO`/`SO_SNDTIMEO`
    /// deadlines govern every subsequent read and write.
    static func connect(fd: Int32, addr: inout sockaddr_un, timeoutSecond: Int) -> SocketError? {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            return .cannotConnect(String(cString: strerror(errno)))
        }
        defer { _ = fcntl(fd, F_SETFL, flags) }

        let joined = withSockAddr(&addr) { pointer, length in
            Darwin.connect(fd, pointer, length)
        }
        if joined == 0 { return nil }
        guard errno == EINPROGRESS else {
            return .cannotConnect(String(cString: strerror(errno)))
        }

        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&descriptor, 1, Int32(timeoutSecond * 1000))
        if ready == 0 { return .timedOut }
        guard ready > 0 else { return .cannotConnect(String(cString: strerror(errno))) }

        // poll() reporting writable says the attempt *finished*, not that it succeeded.
        // The verdict is in SO_ERROR, and skipping this check hands the caller a
        // descriptor that fails on first use with a misleading error.
        var code: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &code, &size) == 0 else {
            return .cannotConnect(String(cString: strerror(errno)))
        }
        guard code == 0 else { return .cannotConnect(String(cString: strerror(code))) }
        return nil
    }
}

/// Line-delimited JSON server over AF_UNIX. One dispatch queue per connection —
/// the connection count here is a handful, not a thundering herd.
public final class LineSocketServer {
    public typealias Handler = (Data) -> Data?
    /// Fired when a connection closes. The helper's deadman switch hangs off this.
    public typealias CloseHandler = () -> Void

    private let path: String
    private let handler: Handler
    private let onClose: CloseHandler?
    private var listenFd: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "com.lidcode.socket.accept")
    private var isStopped = false

    public init(path: String, onClose: CloseHandler? = nil, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
        self.onClose = onClose
    }

    /// - Parameters:
    ///   - mode: POSIX permission for the socket file.
    ///   - ownerUid: chown the socket to this uid so a root-owned helper socket is
    ///     still reachable by exactly one user, rather than world-writable.
    public func start(mode: mode_t = 0o600, ownerUid: uid_t? = nil) throws {
        unlink(path)

        listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFd >= 0 else { throw SocketError.cannotCreate(String(cString: strerror(errno))) }

        guard var addr = UnixSocket.makeAddress(path) else {
            throw SocketError.cannotBind("path longer than \(UnixSocket.maxPathLength) bytes")
        }
        let bound = UnixSocket.withSockAddr(&addr) { pointer, length in
            bind(listenFd, pointer, length)
        }
        guard bound == 0 else {
            let message = String(cString: strerror(errno))
            close(listenFd)
            throw SocketError.cannotBind(message)
        }

        chmod(path, mode)
        if let ownerUid { chown(path, ownerUid, gid_t(0)) }

        guard listen(listenFd, 8) == 0 else {
            let message = String(cString: strerror(errno))
            close(listenFd)
            throw SocketError.cannotBind(message)
        }

        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while !isStopped {
            let fd = accept(listenFd, nil, nil)
            guard fd >= 0 else {
                if isStopped { return }
                usleep(50_000)
                continue
            }
            DispatchQueue(label: "com.lidcode.socket.connection").async { [weak self] in
                self?.serve(fd: fd)
            }
        }
    }

    private func serve(fd: Int32) {
        defer {
            close(fd)
            onClose?()
        }
        var buffer = Data()
        // No read deadline on an accepted connection, on purpose: the app↔helper socket
        // is persistent and mostly idle between heartbeats, so "nothing has arrived for
        // five seconds" is the normal state here, not a fault. The deadman switch is
        // what notices a peer that has genuinely gone away.
        loop: while true {
            switch UnixSocket.readLine(fd: fd, buffer: &buffer) {
            case .closed, .timedOut:
                break loop
            case .line(let line):
                guard !line.isEmpty else { continue }
                if let reply = handler(line) {
                    var out = reply
                    out.append(0x0A)
                    guard UnixSocket.writeAll(fd: fd, data: out) == nil else { return }
                }
            }
        }
    }

    public func stop() {
        isStopped = true
        // Reset the descriptor, don't just close it. `stop()` runs twice on quit — the
        // menu's Quit button shuts the model down and then `applicationWillTerminate`
        // does it again — and without this the second call closes a number the kernel
        // may already have handed to something else. Harmless while the process is
        // exiting; a genuine close-someone-else's-socket bug anywhere it is not.
        if listenFd >= 0 {
            close(listenFd)
            listenFd = -1
        }
        unlink(path)
    }
}

/// Short-lived request/response client. Also usable as a persistent connection when
/// the caller needs the server to notice a disconnect (see the helper heartbeat).
public final class LineSocketClient {
    private let path: String
    private var fd: Int32 = -1
    private var buffer = Data()
    private let lock = NSLock()

    public init(path: String) { self.path = path }

    deinit { disconnect() }

    public var isConnected: Bool { fd >= 0 }

    public func connect(timeoutSecond: Int = 5) throws {
        lock.lock()
        defer { lock.unlock() }
        guard fd < 0 else { return }

        let newFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard newFd >= 0 else { throw SocketError.cannotCreate(String(cString: strerror(errno))) }

        guard var addr = UnixSocket.makeAddress(path) else {
            close(newFd)
            throw SocketError.cannotConnect("path too long")
        }
        // Deadlines are armed *before* the connect and cover it too. Every call below
        // this line is bounded, which is what lets a caller on a serial queue survive a
        // peer that stops answering — see the freeze notes on `LidCodeRuntime`.
        UnixSocket.setTimeout(fd: newFd, second: timeoutSecond)
        if let error = UnixSocket.connect(fd: newFd, addr: &addr, timeoutSecond: timeoutSecond) {
            close(newFd)
            throw error
        }
        fd = newFd
        buffer = Data()
    }

    public func disconnect() {
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 { close(fd) }
        fd = -1
    }

    /// Send one request, read one response. Drops the connection on any failure so
    /// the next call reconnects cleanly rather than reusing a half-dead socket.
    public func roundTrip<Request: Encodable, Response: Decodable>(
        _ request: Request,
        expecting: Response.Type
    ) throws -> Response {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { throw SocketError.closed }

        let payload = try Wire.encodeLine(request)
        // Any failure — including a timeout — drops the connection. A socket that timed
        // out mid-exchange has an unread reply queued on it, so reusing it would hand
        // the *next* request the previous one's answer.
        if let error = UnixSocket.writeAll(fd: fd, data: payload) {
            close(fd); fd = -1
            throw error
        }
        switch UnixSocket.readLine(fd: fd, buffer: &buffer) {
        case .line(let line):
            return try Wire.decode(Response.self, from: line)
        case .timedOut:
            close(fd); fd = -1
            throw SocketError.timedOut
        case .closed:
            close(fd); fd = -1
            throw SocketError.closed
        }
    }
}
