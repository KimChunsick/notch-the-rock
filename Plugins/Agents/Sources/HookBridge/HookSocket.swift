import Darwin
import Foundation

/// The Unix socket the Agents plugin listens on and the helper connects to.
public enum HookSocket {
    /// Overrides the socket path for the helper. Tests use it; the installed hooks do not set it.
    public static let pathEnvironmentKey = "NOTCH_HOOK_SOCKET"

    /// `~/Library/Application Support/NotchTheRock/run/agents.sock`. The folder is the user's only (0700).
    public static func defaultPath(home: URL) -> String {
        home.appendingPathComponent("Library/Application Support/NotchTheRock/run/agents.sock").path
    }

    /// The socket address for `path`, or nil when the path does not fit `sun_path` (104 bytes).
    public static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    /// A connected socket, or nil at once when nothing listens at `path` (no socket file, a stale
    /// one, or a listener too busy to take the connection within `timeout`).
    public static func connect(to path: String, timeout: Duration = .milliseconds(500)) -> Int32? {
        guard var address = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN, wait(fd, for: Int16(POLLOUT), timeout: timeout) else {
                close(fd)
                return nil
            }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
                close(fd)
                return nil
            }
        }
        _ = fcntl(fd, F_SETFL, flags)
        return fd
    }

    /// Writes all of `data`; false when the peer is gone.
    public static func write(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    /// Reads up to the first `\n` (not included); nil when the peer closes before a whole line or the
    /// line grows past `HookWire.maxLineLength`.
    public static func readLine(from fd: Int32) -> Data? {
        var line = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while line.count <= HookWire.maxLineLength {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            if let end = chunk[..<count].firstIndex(of: UInt8(ascii: "\n")) {
                line.append(contentsOf: chunk[..<end])
                return line
            }
            line.append(contentsOf: chunk[..<count])
        }
        return nil
    }

    private static func wait(_ fd: Int32, for events: Int16, timeout: Duration) -> Bool {
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        let milliseconds = Int32(timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000)
        return poll(&descriptor, 1, milliseconds) == 1
    }
}
