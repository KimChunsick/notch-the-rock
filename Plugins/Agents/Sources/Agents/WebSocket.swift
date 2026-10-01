import CryptoKit
import Darwin
import Foundation

struct WebSocketError: Error, CustomStringConvertible {
    let description: String
    /// The close code (RFC 6455 §7.4.1) the client sends when the server broke the protocol; nil for
    /// a socket error.
    var closeCode: UInt16? = nil

    static func protocolError(_ description: String) -> WebSocketError {
        WebSocketError(description: description, closeCode: 1002)
    }

    static func tooBig(_ description: String) -> WebSocketError {
        WebSocketError(description: description, closeCode: 1009)
    }
}

/// One WebSocket frame (RFC 6455 §5.2).
struct WebSocketFrame: Equatable {
    enum Opcode: UInt8 {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA
    }

    var fin: Bool
    var opcode: Opcode
    var payload: Data
    /// Whether the frame arrived masked; a client's frames always are.
    var masked = false

    init(fin: Bool, opcode: Opcode, payload: Data, masked: Bool = false) {
        self.fin = fin
        self.opcode = opcode
        self.payload = payload
        self.masked = masked
    }

    /// The frame on the wire, masked with `mask` when given (a client must mask every frame).
    func encoded(mask: [UInt8]?) -> Data {
        var data = Data([(fin ? 0x80 : 0) | opcode.rawValue])
        let flag: UInt8 = mask == nil ? 0 : 0x80
        switch payload.count {
        case ..<126:
            data.append(flag | UInt8(payload.count))
        case ...0xFFFF:
            data.append(flag | 126)
            data.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        default:
            data.append(flag | 127)
            data.append(contentsOf: (0..<8).reversed().map { UInt8((UInt64(payload.count) >> ($0 * 8)) & 0xFF) })
        }
        guard let mask else { return data + payload }
        data.append(contentsOf: mask)
        data.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return data
    }

    /// The first frame in `buffer` and the bytes it used, or nil while it is incomplete. Unmasks a
    /// masked payload. Throws as soon as the header shows a frame that may not be read: an unknown
    /// opcode, reserved bits, a payload above `maxPayload` (or with the top bit of the 64-bit length
    /// set), or a control frame that is fragmented or longer than 125 bytes.
    static func decode(_ buffer: Data, maxPayload: Int = WebSocket.maxMessage) throws -> (WebSocketFrame, Int)? {
        let bytes = [UInt8](buffer.prefix(14))
        guard bytes.count >= 2 else { return nil }
        guard let opcode = Opcode(rawValue: bytes[0] & 0x0F) else { throw WebSocketError.protocolError("Unknown frame opcode") }
        guard bytes[0] & 0x70 == 0 else { throw WebSocketError.protocolError("A frame uses reserved bits") }
        let fin = bytes[0] & 0x80 != 0
        let masked = bytes[1] & 0x80 != 0
        var length = Int(bytes[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            let value = bytes[2..<10].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            guard value <= UInt64(maxPayload) else { throw WebSocketError.tooBig("A frame of \(value) bytes is over the limit") }
            length = Int(value)
            offset = 10
        }
        guard length <= maxPayload else { throw WebSocketError.tooBig("A frame of \(length) bytes is over the limit") }
        if opcode.rawValue >= 0x8 {
            guard fin, length <= 125 else { throw WebSocketError.protocolError("A control frame is fragmented or too long") }
        }
        let mask = masked ? Array(bytes.dropFirst(offset).prefix(4)) : []
        offset += mask.count
        guard mask.count == (masked ? 4 : 0), buffer.count >= offset + length else { return nil }
        let start = buffer.startIndex + offset
        var payload = Data(buffer[start..<start + length])
        if masked {
            payload = Data(payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        }
        return (WebSocketFrame(fin: fin, opcode: opcode, payload: payload, masked: masked), offset + length)
    }
}

/// A WebSocket client over a connected stream socket, as codex's app-server speaks it on its Unix
/// socket: an HTTP Upgrade, then text frames that each carry one JSON-RPC message. A socket made for
/// a path connects in `handshake`, so whoever holds it can `close()` it before anything blocks.
/// `receive()` is called from one thread at a time and blocks. `send(text:)` never blocks: a serial writer delivers
/// the frames in order, and a failed write closes the connection. `close()` works from any thread,
/// at any time, and ends a blocked handshake, receive or write; the descriptor itself is closed when
/// the last user lets go of the socket, so it is never reused under a thread still using it.
final class WebSocket: CodexConnection, @unchecked Sendable {
    /// The largest message (and frame) the client reads, and the most it queues for writing.
    static let maxMessage = 16 << 20

    private let fd: Int32
    /// Where `handshake` connects; nil for a descriptor that is already connected.
    private let unixPath: String?
    private let maxMessage: Int
    /// Bytes read but not yet used; touched only by the reading thread.
    private var buffer = Data()
    private let writer = DispatchQueue(label: "com.notchtherock.agents.websocket-writer")
    private let lock = NSLock()
    private var isClosed = false
    /// Bytes handed to the writer and not written yet.
    private var queued = 0

    /// Takes over `fd`, connected already unless `unixPath` says where `handshake` connects it.
    init(fd: Int32, maxMessage: Int = WebSocket.maxMessage, unixPath: String? = nil) {
        self.fd = fd
        self.unixPath = unixPath
        self.maxMessage = maxMessage
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// A socket for the Unix socket at `unixPath`; `handshake` connects it.
    convenience init(unixPath: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WebSocketError(description: "socket: \(String(cString: strerror(errno)))") }
        self.init(fd: fd, unixPath: unixPath)
    }

    /// Connects `fd` to the Unix socket at `path` without blocking past `deadline`: the connect runs
    /// non-blocking and is waited for in short slices, checking `abandoned` before and between them
    /// (shutting down a socket that is not connected yet wakes nothing). Leaves `fd` blocking. Returns
    /// 0, or the error that ended it: `ETIMEDOUT` at the deadline, `ECANCELED` when abandoned.
    static func connectSocket(_ fd: Int32, to path: String, by deadline: ContinuousClock.Instant, abandoned: () -> Bool) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return ENAMETOOLONG }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            bytes.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        guard !abandoned() else { return ECANCELED }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return errno }
        defer { _ = fcntl(fd, F_SETFL, flags) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let code = result == 0 ? 0 : errno
        guard code == EINPROGRESS || code == EINTR else { return code }
        while !abandoned() {
            let left = deadline - .now
            guard left > .zero else { return ETIMEDOUT }
            let slice = min(left, .milliseconds(50)).components
            var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&poller, 1, max(1, Int32(slice.seconds * 1000 + slice.attoseconds / 1_000_000_000_000_000)))
            if ready < 0, errno != EINTR { return errno }
            if ready > 0 {
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return errno }
                return error
            }
        }
        return ECANCELED
    }

    deinit {
        Darwin.close(fd)
    }

    /// Connects to the Unix socket at `unixPath` and completes the handshake, both within `timeout`.
    static func connect(unixPath: String, timeout: Duration = .seconds(5)) throws -> WebSocket {
        let socket = try WebSocket(unixPath: unixPath)
        do {
            try socket.handshake(timeout: timeout)
        } catch {
            socket.close()
            throw error
        }
        return socket
    }

    /// `Sec-WebSocket-Accept` for `key` (RFC 6455 §4.2.2).
    static func acceptKey(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return Data(digest).base64EncodedString()
    }

    /// Connects (for a socket made for a path), sends the HTTP Upgrade request and checks the server's
    /// 101 answer and accept key, all within `timeout`; a server that answers slowly or not at all
    /// fails it, and so does `close()` from another thread.
    func handshake(timeout: Duration = .seconds(5)) throws {
        let deadline = ContinuousClock.now + timeout
        if let unixPath {
            let code = Self.connectSocket(fd, to: unixPath, by: deadline) { lock.withLock { isClosed } }
            guard code == 0 else { throw WebSocketError(description: "connect \(unixPath): \(String(cString: strerror(code)))") }
            // A close() that came just as the connect went through found nothing to shut down.
            guard !lock.withLock({ isClosed }) else { throw WebSocketError(description: "The connection was closed while connecting") }
        }
        defer {
            setTimeout(SO_SNDTIMEO, nil)
            setTimeout(SO_RCVTIMEO, nil)
        }
        func untilDeadline(_ option: Int32) throws {
            let left = deadline - .now
            guard left > .zero else { throw WebSocketError(description: "The server did not answer the upgrade in time") }
            setTimeout(option, left)
        }
        let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        try untilDeadline(SO_SNDTIMEO)
        try write(Data("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8))
        let separator = Data("\r\n\r\n".utf8)
        while buffer.range(of: separator) == nil {
            guard buffer.count < 16_384 else { throw WebSocketError(description: "The upgrade answer is too long") }
            try untilDeadline(SO_RCVTIMEO)
            try fill()
        }
        let end = buffer.range(of: separator)!.upperBound
        let head = String(decoding: buffer[..<end], as: UTF8.self)
        buffer.removeSubrange(..<end)
        let lines = head.components(separatedBy: "\r\n")
        guard let status = lines.first, status.hasPrefix("HTTP/1.1 101") else {
            throw WebSocketError(description: "The server refused the upgrade: \(lines.first ?? "")")
        }
        let accept = lines.first { $0.lowercased().hasPrefix("sec-websocket-accept:") }
            .map { $0.dropFirst("sec-websocket-accept:".count).trimmingCharacters(in: .whitespaces) }
        guard accept == Self.acceptKey(for: key) else {
            throw WebSocketError(description: "The server's accept key does not match")
        }
    }

    func send(text: String) {
        enqueue(WebSocketFrame(fin: true, opcode: .text, payload: Data(text.utf8)))
    }

    /// The next text message, put together from its fragments, or nil once the server closed the
    /// connection. Answers pings and the server's close on the way; control frames between fragments
    /// leave the message alone. A frame or message over the limit, or a broken frame, is answered
    /// with a close frame and thrown.
    func receive() throws -> String? {
        var message = Data()
        var inMessage = false
        while true {
            let frame: WebSocketFrame
            do {
                frame = try nextFrame()
            } catch let error as WebSocketError where error.closeCode != nil {
                try refuse(error)
            }
            switch frame.opcode {
            case .ping:
                enqueue(WebSocketFrame(fin: true, opcode: .pong, payload: frame.payload))
                continue
            case .pong:
                continue
            case .close:
                enqueue(WebSocketFrame(fin: true, opcode: .close, payload: frame.payload.prefix(2)))
                return nil
            case .text, .binary:
                guard !inMessage else { try refuse(.protocolError("A new message began inside a fragmented one")) }
                message = frame.payload
                inMessage = true
            case .continuation:
                guard inMessage else { try refuse(.protocolError("A continuation arrived outside a message")) }
                guard message.count + frame.payload.count <= maxMessage else {
                    try refuse(.tooBig("A message grew over \(maxMessage) bytes"))
                }
                message.append(frame.payload)
            }
            if frame.fin {
                return String(decoding: message, as: UTF8.self)
            }
        }
    }

    /// Shuts the socket down; a handshake, `receive()` or write blocked on another thread returns
    /// with an error, and queued frames are dropped.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        shutdown(fd, SHUT_RDWR)
    }

    /// Tells the server why the client stops reading (a close frame with the error's code), then
    /// throws `error`.
    private func refuse(_ error: WebSocketError) throws -> Never {
        if let code = error.closeCode {
            enqueue(WebSocketFrame(fin: true, opcode: .close, payload: Data([UInt8(code >> 8), UInt8(code & 0xFF)])))
        }
        throw error
    }

    /// Hands `frame` to the writer. More than `maxMessage` bytes waiting means the server stopped
    /// reading: the connection closes.
    private func enqueue(_ frame: WebSocketFrame) {
        let data = frame.encoded(mask: (0..<4).map { _ in UInt8.random(in: .min ... .max) })
        let accepted = lock.withLock {
            guard !isClosed, queued + data.count <= maxMessage else { return false }
            queued += data.count
            return true
        }
        guard accepted else {
            close()
            return
        }
        writer.async { [self] in
            defer { lock.withLock { queued -= data.count } }
            guard !lock.withLock({ isClosed }) else { return }
            do {
                try write(data)
            } catch {
                close()
            }
        }
    }

    private func nextFrame() throws -> WebSocketFrame {
        while true {
            if let (frame, used) = try WebSocketFrame.decode(buffer, maxPayload: maxMessage) {
                buffer.removeFirst(used)
                return frame
            }
            try fill()
        }
    }

    private func fill() throws {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let count = read(fd, &chunk, chunk.count)
        guard count > 0 else {
            let code = errno
            guard count < 0 else { throw WebSocketError(description: "The server closed the socket") }
            // Only the handshake sets a receive timeout.
            guard code != EAGAIN, code != EWOULDBLOCK else { throw WebSocketError(description: "The server did not answer the upgrade in time") }
            throw WebSocketError(description: "read: \(String(cString: strerror(code)))")
        }
        buffer.append(contentsOf: chunk.prefix(count))
    }

    /// Writes all of `data`; only the handshake and the writer call it, never at the same time.
    private func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard written > 0 else {
                    if written < 0, errno == EINTR { continue }
                    throw WebSocketError(description: "write: \(String(cString: strerror(errno)))")
                }
                offset += written
            }
        }
    }

    /// Sets a send or receive timeout; nil clears it.
    private func setTimeout(_ option: Int32, _ duration: Duration?) {
        let parts = duration?.components ?? (seconds: 0, attoseconds: 0)
        var value = timeval(tv_sec: Int(parts.seconds), tv_usec: Int32(parts.attoseconds / 1_000_000_000_000))
        if duration != nil, value.tv_sec == 0, value.tv_usec == 0 { value.tv_usec = 1 }
        setsockopt(fd, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<timeval>.size))
    }
}
