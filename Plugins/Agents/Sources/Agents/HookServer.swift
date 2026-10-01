import Darwin
import Foundation
import HookBridge

struct HookServerError: Error, CustomStringConvertible {
    let description: String
}

/// The way back to one helper that waits for a decision.
struct HookReply: Sendable {
    fileprivate let server: HookServer
    fileprivate let connection: Int

    /// Sends the decision and closes the connection; does nothing once the connection is closed.
    func send(_ decision: HookDecision?) {
        server.send(decision, to: connection)
    }

    /// Runs `handler` once when the helper's end closes before a decision was sent (the user answered
    /// in the terminal and Claude Code ended the hook, or its timeout did), or at once when it
    /// already has.
    func onClose(_ handler: @escaping @Sendable () -> Void) {
        server.onClose(of: connection, handler)
    }
}

/// Listens for `notch-hook` on the Agents socket: a Unix socket, 0600, in a folder only the user can
/// enter (0700). A connection from a process of another user is closed before anything is read. Each
/// connection carries one `HookWire` line from the helper, handed to `handler` on the server's queue
/// with a reply when the helper waits for a decision (`HookEvent.awaitsDecision`); a notice's
/// connection is closed at once.
final class HookServer: @unchecked Sendable {
    private let path: String
    private let peerUID: @Sendable (Int32) -> uid_t?
    private let log: @Sendable (String) -> Void
    private let handler: @Sendable (HookMessage, HookReply?) -> Void
    private let queue = DispatchQueue(label: "com.notchtherock.agents.hook-server")
    // Touched only on `queue`.
    private var listener: DispatchSourceRead?
    /// Open connections by a number that, unlike the descriptor, is never reused.
    private var connections: [Int: Connection] = [:]
    private var connectionCount = 0
    /// The socket file this server bound, so `stop()` removes only that file.
    private var boundFile: (device: dev_t, inode: ino_t)?

    private final class Connection {
        let fd: Int32
        let source: DispatchSourceRead
        var buffer = Data()
        /// Set once the message went to the handler with a reply; the connection then stays open
        /// until the reply is sent or the helper goes away.
        var awaitsReply = false
        var closeHandlers: [@Sendable () -> Void] = []

        init(fd: Int32, source: DispatchSourceRead) {
            self.fd = fd
            self.source = source
        }
    }

    /// `peerUID` returns the user id of the process at the other end of a connected socket.
    init(
        path: String,
        peerUID: @escaping @Sendable (Int32) -> uid_t? = HookServer.peerUID(of:),
        log: @escaping @Sendable (String) -> Void,
        handler: @escaping @Sendable (HookMessage, HookReply?) -> Void
    ) {
        self.path = path
        self.peerUID = peerUID
        self.log = log
        self.handler = handler
    }

    static func peerUID(of fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    func start() throws {
        try queue.sync {
            guard listener == nil else { return }
            try listen()
        }
    }

    /// Closes the socket and every open connection, then removes the socket file.
    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for connection in connections.values {
                connection.source.cancel()
            }
            connections.removeAll()
            var info = stat()
            if let boundFile, lstat(path, &info) == 0, info.st_dev == boundFile.device, info.st_ino == boundFile.inode {
                unlink(path)
            }
            boundFile = nil
        }
    }

    private func listen() throws {
        guard var address = HookSocket.address(path) else {
            throw HookServerError(description: "The socket path is too long: \(path)")
        }
        try prepareFolder()
        var info = stat()
        if lstat(path, &info) == 0 {
            // A socket left by an earlier run of the app; anything else is not ours to remove.
            guard info.st_mode & S_IFMT == S_IFSOCK else {
                throw HookServerError(description: "Something other than a socket is at \(path)")
            }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HookServerError(description: "socket() failed: \(String(cString: strerror(errno)))") }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 16) == 0, lstat(path, &info) == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw HookServerError(description: "Cannot listen on \(path): \(reason)")
        }
        boundFile = (info.st_dev, info.st_ino)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(on: fd) }
        source.setCancelHandler { close(fd) }
        listener = source
        source.resume()
    }

    /// Creates the socket's folder for this user only, or checks that the existing one is a real
    /// folder of this user and closes it to everyone else.
    private func prepareFolder() throws {
        let folder = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(folder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw HookServerError(description: "The socket folder is missing or not this user's own folder: \(folder)")
        }
        if info.st_mode & 0o777 != 0o700 {
            guard chmod(folder, 0o700) == 0 else {
                throw HookServerError(description: "Cannot make the socket folder private: \(folder)")
            }
        }
    }

    private func acceptPending(on listenerFD: Int32) {
        while true {
            let fd = accept(listenerFD, nil, nil)
            guard fd >= 0 else { return }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let uid = peerUID(fd)
            guard uid == getuid() else {
                close(fd)
                log("Closed a hook connection from another user (uid \(uid.map(String.init) ?? "unknown")).")
                continue
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            connectionCount += 1
            let id = connectionCount
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.read(id) }
            source.setCancelHandler { close(fd) }
            connections[id] = Connection(fd: fd, source: source)
            source.resume()
        }
    }

    private func read(_ id: Int) {
        guard let connection = connections[id] else { return }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = Darwin.read(connection.fd, &chunk, chunk.count)
        if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
        guard count > 0 else {
            // The helper went away: before a whole message arrived, or while it waited for a reply.
            let handlers = connection.awaitsReply ? connection.closeHandlers : []
            finish(id)
            handlers.forEach { $0() }
            return
        }
        // A helper sends one line; anything after it is ignored.
        guard !connection.awaitsReply else { return }
        connection.buffer.append(contentsOf: chunk[..<count])
        guard let end = connection.buffer.firstIndex(of: UInt8(ascii: "\n")) else {
            if connection.buffer.count > HookWire.maxLineLength {
                log("Dropped a hook message longer than \(HookWire.maxLineLength) bytes.")
                finish(id)
            }
            return
        }
        let line = Data(connection.buffer[..<end])
        connection.buffer = Data()
        guard let message = HookWire.decode(HookMessage.self, from: line) else {
            finish(id)
            log("Dropped a hook message the plugin cannot read.")
            return
        }
        guard message.event.awaitsDecision else {
            finish(id)
            handler(message, nil)
            return
        }
        connection.awaitsReply = true
        handler(message, HookReply(server: self, connection: id))
    }

    fileprivate func send(_ decision: HookDecision?, to id: Int) {
        queue.async { [self] in
            guard let connection = connections[id] else { return }
            // A few hundred bytes: the socket's send buffer takes them at once.
            if let line = try? HookWire.line(HookResponse(decision: decision)) {
                _ = HookSocket.write(line, to: connection.fd)
            }
            finish(id)
        }
    }

    fileprivate func onClose(of id: Int, _ handler: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard let connection = connections[id] else {
                handler()
                return
            }
            connection.closeHandlers.append(handler)
        }
    }

    private func finish(_ id: Int) {
        connections.removeValue(forKey: id)?.source.cancel()
    }
}
