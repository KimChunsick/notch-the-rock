import CryptoKit
import Darwin
import Foundation

struct WebSocketError: Error, CustomStringConvertible {
    let description: String
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
    /// masked payload. Unknown opcodes decode as nil too; the caller treats a stalled buffer as an error.
    static func decode(_ buffer: Data) -> (WebSocketFrame, Int)? {
        let bytes = [UInt8](buffer.prefix(14))
        guard bytes.count >= 2, let opcode = Opcode(rawValue: bytes[0] & 0x0F) else { return nil }
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
            guard value <= UInt64(Int32.max) else { return nil }
            length = Int(value)
            offset = 10
        }
        let mask = masked ? Array(bytes.dropFirst(offset).prefix(4)) : []
        offset += mask.count
        guard mask.count == (masked ? 4 : 0), buffer.count >= offset + length else { return nil }
        let start = buffer.startIndex + offset
        var payload = Data(buffer[start..<start + length])
        if masked {
            payload = Data(payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        }
        return (WebSocketFrame(fin: bytes[0] & 0x80 != 0, opcode: opcode, payload: payload, masked: masked), offset + length)
    }
}

/// A WebSocket client over a connected stream socket, as codex's app-server speaks it on its Unix
/// socket: an HTTP Upgrade, then text frames that each carry one JSON-RPC message. `receive()` is
/// called from one thread at a time and blocks; `send(text:)` may be called from any thread.
final class WebSocket: @unchecked Sendable {
    private let fd: Int32
    private let writeLock = NSLock()
    /// Bytes read but not yet used; touched only by the reading thread.
    private var buffer = Data()
    private let closed = NSLock()
    private var isClosed = false

    /// Takes over `fd`; `close()` closes it.
    init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Connects to the Unix socket at `unixPath` and completes the handshake.
    static func connect(unixPath: String) throws -> WebSocket {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WebSocketError(description: "socket: \(String(cString: strerror(errno)))") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = unixPath.utf8CString
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw WebSocketError(description: "The socket path is too long: \(unixPath)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            path.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw WebSocketError(description: "connect \(unixPath): \(message)")
        }
        let socket = WebSocket(fd: fd)
        do {
            try socket.handshake()
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

    /// Sends the HTTP Upgrade request and checks the server's 101 answer and accept key.
    func handshake() throws {
        let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        try write(Data("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8))
        let separator = Data("\r\n\r\n".utf8)
        while buffer.range(of: separator) == nil {
            guard buffer.count < 16_384 else { throw WebSocketError(description: "The upgrade answer is too long") }
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

    func send(text: String) throws {
        try send(WebSocketFrame(fin: true, opcode: .text, payload: Data(text.utf8)))
    }

    /// The next text message, put together from its fragments, or nil once the server closed the
    /// connection. Answers pings and the server's close on the way.
    func receive() throws -> String? {
        var message = Data()
        var inMessage = false
        while true {
            let frame = try nextFrame()
            switch frame.opcode {
            case .ping:
                try send(WebSocketFrame(fin: true, opcode: .pong, payload: frame.payload))
            case .pong:
                continue
            case .close:
                try? send(WebSocketFrame(fin: true, opcode: .close, payload: frame.payload.prefix(2)))
                return nil
            case .text, .binary:
                guard !inMessage else { throw WebSocketError(description: "A new message began inside a fragmented one") }
                message = frame.payload
                inMessage = true
            case .continuation:
                guard inMessage else { throw WebSocketError(description: "A continuation arrived outside a message") }
                message.append(frame.payload)
            }
            if inMessage, frame.fin {
                return String(decoding: message, as: UTF8.self)
            }
        }
    }

    /// Closes the socket; a `receive()` blocked on another thread returns with an error.
    func close() {
        closed.lock()
        defer { closed.unlock() }
        guard !isClosed else { return }
        isClosed = true
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    private func send(_ frame: WebSocketFrame) throws {
        try write(frame.encoded(mask: (0..<4).map { _ in UInt8.random(in: .min ... .max) }))
    }

    private func nextFrame() throws -> WebSocketFrame {
        while true {
            if let (frame, used) = WebSocketFrame.decode(buffer) {
                buffer.removeFirst(used)
                return frame
            }
            if buffer.count >= 2, WebSocketFrame.Opcode(rawValue: buffer[buffer.startIndex] & 0x0F) == nil {
                throw WebSocketError(description: "Unknown frame opcode")
            }
            try fill()
        }
    }

    private func fill() throws {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let count = read(fd, &chunk, chunk.count)
        guard count > 0 else {
            throw WebSocketError(description: count == 0 ? "The server closed the socket" : "read: \(String(cString: strerror(errno)))")
        }
        buffer.append(contentsOf: chunk.prefix(count))
    }

    private func write(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
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
}
