import Darwin
import Dispatch
import Foundation

/// Who is on the other end of a Unix socket.
public enum PeerCredentials {
    /// True only if the connected process runs as the same user as this one.
    public static func isSameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return false }
        return uid == geteuid()
    }
}

/// The app's end of the MCP bridge: a Unix domain socket the `atlantis-mcp` helper connects to.
///
/// Security (AGENTS.md, PRD §17): never TCP; the socket file is `0600` inside a `0700` directory;
/// every accepted connection is checked with `getpeereid` and dropped unless it is the same user.
/// Idle costs nothing: accepting uses a `DispatchSource` and each connection blocks on its own
/// socket with a timeout, so there is no polling.
public final class MCPSocketServer: @unchecked Sendable {
    public enum StartError: Error, Equatable, CustomStringConvertible {
        case pathTooLong(Int)
        case alreadyRunning
        case notASocket(String)
        case directoryNotOwned(String)
        case posix(String, Int32)

        public var description: String {
            switch self {
            case .pathTooLong(let n): "Socket path is too long (\(n) bytes, max 103)."
            case .alreadyRunning: "Another Atlantis is already serving MCP."
            case .notASocket(let p): "\(p) exists and isn't a socket, so it was left alone."
            case .directoryNotOwned(let p): "\(p) isn't owned by you."
            case .posix(let what, let code): "\(what) failed: \(String(cString: strerror(code)))."
            }
        }
    }

    public let socketURL: URL
    private let handler: MCPProtocolHandler
    private let peerCheck: @Sendable (Int32) -> Bool
    private let maxConnections: Int
    private let requestTimeout: Double

    private let acceptQueue = DispatchQueue(label: "au.lifeos.atlantis.mcp.accept", qos: .utility)
    private let workQueue = DispatchQueue(label: "au.lifeos.atlantis.mcp.work", qos: .utility, attributes: .concurrent)
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var active = Set<Int32>()
    private var running = false
    private let stopped = DispatchSemaphore(value: 0)

    /// - Parameters:
    ///   - peerCheck: defaults to the same-user check; tests inject a refusing one.
    ///   - requestTimeout: how long a connection may take to send its request.
    public init(socketURL: URL,
                handler: MCPProtocolHandler,
                maxConnections: Int = 32,
                requestTimeout: Double = 10,
                peerCheck: @escaping @Sendable (Int32) -> Bool = PeerCredentials.isSameUser) {
        self.socketURL = socketURL
        self.handler = handler
        self.maxConnections = maxConnections
        self.requestTimeout = requestTimeout
        self.peerCheck = peerCheck
    }

    public var isRunning: Bool { lock.withLock { running } }

    // MARK: Start / stop

    public func start() throws {
        if isRunning { return }
        let path = socketURL.path
        let dir = socketURL.deletingLastPathComponent().path

        // The directory is the real lock on the door: 0700, ours.
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var dirStat = stat()
        guard lstat(dir, &dirStat) == 0 else { throw StartError.posix("stat directory", errno) }
        guard dirStat.st_uid == geteuid(), (dirStat.st_mode & S_IFMT) == S_IFDIR else { throw StartError.directoryNotOwned(dir) }
        if dirStat.st_mode & 0o777 != 0o700, chmod(dir, 0o700) != 0 { throw StartError.posix("chmod directory", errno) }

        try removeStaleSocket(at: path)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else { throw StartError.pathTooLong(bytes.count) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.posix("socket", errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bindResult == 0 else { let e = errno; close(fd); throw StartError.posix("bind", e) }
        // Straight after bind; the 0700 directory means nobody else could reach it in between.
        guard chmod(path, 0o600) == 0 else { let e = errno; close(fd); unlink(path); throw StartError.posix("chmod socket", e) }
        guard listen(fd, 64) == 0 else { let e = errno; close(fd); unlink(path); throw StartError.posix("listen", e) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending(on: fd) }
        source.setCancelHandler { [stopped] in close(fd); stopped.signal() }
        lock.withLock {
            listenFD = fd
            self.source = source
            running = true
        }
        source.resume()
    }

    /// Stops accepting, drops open connections and removes the socket file. Safe to call twice.
    public func stop() {
        let source: DispatchSourceRead? = lock.withLock {
            guard running else { return nil }
            running = false
            let s = self.source
            self.source = nil
            listenFD = -1
            return s
        }
        guard let source else { return }
        // Unblock connections waiting on their sockets; each one closes its own fd.
        lock.withLock { for fd in active { shutdown(fd, SHUT_RDWR) } }
        // Cancelling runs the cancel handler (set in start), which closes the listening fd.
        source.cancel()
        _ = stopped.wait(timeout: .now() + 2)
        unlink(socketURL.path)
    }

    private func removeStaleSocket(at path: String) throws {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        guard (st.st_mode & S_IFMT) == S_IFSOCK else { throw StartError.notASocket(path) }
        // A live server answers a connect; a dead one leaves a refused socket file behind.
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw StartError.posix("socket", errno) }
        defer { close(probe) }
        if (try? MCPSocketClient.connect(probe, to: path)) != nil { throw StartError.alreadyRunning }
        unlink(path)
    }

    // MARK: Connections

    private func acceptPending(on listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return // EAGAIN: nothing more waiting
            }
            admit(fd)
        }
    }

    private func admit(_ fd: Int32) {
        // Blocking, no SIGPIPE, not inherited by children.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        guard peerCheck(fd) else { close(fd); return }
        let admitted = lock.withLock { () -> Bool in
            guard running, active.count < maxConnections else { return false }
            active.insert(fd)
            return true
        }
        guard admitted else { close(fd); return }

        workQueue.async { [self] in
            serve(fd)
            lock.withLock { _ = active.remove(fd) }
            close(fd)
        }
    }

    /// One request, one reply, then hang up.
    private func serve(_ fd: Int32) {
        Framing.setTimeouts(fd, seconds: requestTimeout)
        guard let request = try? Framing.readFrame(from: fd) else { return }
        // Replies can take as long as a tool needs; only sending the answer is time-limited.
        Framing.setTimeouts(fd, seconds: requestTimeout)
        let reply = Blocking.run { await self.handler.handle(request) }
        if let reply { try? Framing.writeFrame(reply, to: fd) }
    }
}

/// Runs async work from a thread that may block (a dispatch worker, never the cooperative pool).
enum Blocking {
    private final class Box<T>: @unchecked Sendable { var value: T? }

    static func run<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await work()
            done.signal()
        }
        done.wait()
        return box.value!
    }
}
