import Darwin
import Foundation
import HookBridge
import NotchKit
import SwiftUI
import Testing
@testable import Agents

// MARK: Message limits and the handshake deadline

extension WebSocketTests {
    @Test func R07__fragments_beyond_the_message_limit_are_refused() async throws {
        let (clientFD, server) = try socketPair()
        defer { close(server) }
        let socket = WebSocket(fd: clientFD, maxMessage: 64)
        defer { socket.close() }
        let client = Task.detached { () -> Bool in
            do {
                _ = try socket.receive()
                return false
            } catch {
                return true
            }
        }
        writeAll(server, WebSocketFrame(fin: false, opcode: .text, payload: Data(repeating: 0x61, count: 40)).encoded(mask: nil))
        writeAll(server, WebSocketFrame(fin: false, opcode: .continuation, payload: Data(repeating: 0x61, count: 40)).encoded(mask: nil))
        var buffer = Data()
        let closing = try readFrame(server, &buffer, within: 2)
        #expect(closing?.opcode == .close)
        #expect(closing?.payload == Data([0x03, 0xF1]))
        shutdown(server, SHUT_RDWR)
        #expect(await client.value)
    }

    @Test func R07__a_server_that_never_answers_the_upgrade_times_out() async throws {
        let folder = "/tmp/nk-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: folder) }
        // Never accepts: the connection waits in the backlog and nobody answers the upgrade.
        let listener = try listen(at: folder + "/s.sock")
        defer { close(listener) }
        let started = ContinuousClock.now
        await #expect(throws: WebSocketError.self) {
            try await Task.detached { _ = try WebSocket.connect(unixPath: folder + "/s.sock", timeout: .milliseconds(300)) }.value
        }
        #expect(ContinuousClock.now - started < .seconds(3))
    }
}

// MARK: Connection lifecycle

/// A connection the test drives. `close()` ends a handshake that waits, but a session ends only when
/// the test calls `finish()`, as a reader thread that unwinds late would.
final class FakeConnection: CodexConnection, @unchecked Sendable {
    private let condition = NSCondition()
    private var inbox: [String] = []
    private var finished = false
    private var isClosed = false
    private var texts: [String] = []
    private var waiting = false
    private var timeout: Duration?
    let answersHandshake: Bool

    init(answersHandshake: Bool = true) {
        self.answersHandshake = answersHandshake
    }

    var sent: [String] { condition.withLock { texts } }
    var closed: Bool { condition.withLock { isClosed } }
    var inHandshake: Bool { condition.withLock { waiting } }
    var handshakeTimeout: Duration? { condition.withLock { timeout } }

    func handshake(timeout: Duration) throws {
        condition.lock()
        defer { condition.unlock() }
        self.timeout = timeout
        waiting = true
        while !answersHandshake, !isClosed {
            condition.wait()
        }
        waiting = false
        if isClosed { throw WebSocketError(description: "closed during the handshake") }
    }

    func send(text: String) {
        condition.withLock { texts.append(text) }
    }

    func receive() throws -> String? {
        condition.lock()
        defer { condition.unlock() }
        while inbox.isEmpty, !finished {
            condition.wait()
        }
        return inbox.isEmpty ? nil : inbox.removeFirst()
    }

    func close() {
        condition.withLock {
            isClosed = true
            condition.broadcast()
        }
    }

    func deliver(_ text: String) {
        condition.withLock {
            inbox.append(text)
            condition.broadcast()
        }
    }

    func finish() {
        condition.withLock {
            finished = true
            condition.broadcast()
        }
    }
}

/// Hands out the test's connections in order.
final class ConnectionQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [FakeConnection]

    init(_ connections: [FakeConnection]) {
        self.connections = connections
    }

    func next() throws -> any CodexConnection {
        try lock.withLock {
            guard !connections.isEmpty else { throw WebSocketError(description: "no more connections") }
            return connections.removeFirst()
        }
    }
}

/// Whether `condition` holds within about three seconds.
@MainActor
func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<300 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
@Suite struct CodexLinkTests {
    let home = "/tmp/nk-\(UUID().uuidString.prefix(8))"
    let host = FakeHost()

    /// A link to a listening user-only socket (reused, never started) whose connections are `connections`.
    func makeLink(_ connections: [FakeConnection]) throws -> (CodexLink, Int32) {
        let endpoint = CodexEndpoint(home: URL(fileURLWithPath: home))
        let listener = try listen(at: endpoint.socketPath)
        let bridge = CodexBridge(context: try makeContext(host: host, directory: try makeDirectory()), activator: FakeActivator(), terminal: { _ in nil })
        let queue = ConnectionQueue(connections)
        let link = CodexLink(
            supervisor: CodexSupervisor(endpoint: endpoint, executable: nil, launcher: FakeLauncher(socketPath: endpoint.socketPath)),
            bridge: bridge,
            log: { _ in },
            sleep: { _ in try? await Task.sleep(for: .milliseconds(20)) },
            connect: { _ in try queue.next() }
        )
        return (link, listener)
    }

    @Test func R07__a_stopped_connection_never_tears_down_its_replacement() async throws {
        defer { try? FileManager.default.removeItem(atPath: home) }
        let old = FakeConnection()
        let new = FakeConnection()
        let (link, listener) = try makeLink([old, new])
        defer { close(listener) }
        link.start()
        #expect(await eventually { old.sent.count == 1 })
        link.stop()
        link.start()
        #expect(await eventually { new.sent.count == 1 })
        #expect(link.state == .connected(.reused))
        // The old session unwinds only now, after handing over a request it read before 해제.
        old.deliver(CodexBridge.encode(try codexFixture("commandApproval")))
        old.finish()
        try await Task.sleep(for: .milliseconds(200))
        #expect(host.requests.isEmpty)
        #expect(link.state == .connected(.reused))
        // The replacement still works: its answer to initialize gets `initialized` back.
        new.deliver(#"{"id":1,"result":{}}"#)
        #expect(await eventually { new.sent.count == 3 })
        #expect(new.sent.dropFirst().first == #"{"method":"initialized"}"#)
        link.stop()
        new.finish()
    }

    @Test func R07__disconnect_closes_a_connection_still_in_its_handshake() async throws {
        defer { try? FileManager.default.removeItem(atPath: home) }
        let stuck = FakeConnection(answersHandshake: false)
        let (link, listener) = try makeLink([stuck])
        defer { close(listener) }
        link.start()
        #expect(await eventually { stuck.inHandshake })
        #expect(stuck.handshakeTimeout == .seconds(5))
        link.stop()
        #expect(stuck.closed)
        try await Task.sleep(for: .milliseconds(100))
        #expect(link.state == .off)
    }
}

// MARK: Version check

@Suite struct CodexVersionTests {
    @Test func R07__a_stalled_version_check_times_out_and_stops_codex() async throws {
        let directory = try makeDirectory()
        let script = directory.appendingPathComponent("codex")
        let pidFile = directory.appendingPathComponent("pid")
        try "#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        let started = ContinuousClock.now
        #expect(await CodexInstall.readVersion(script, timeout: .seconds(1)) == nil)
        #expect(ContinuousClock.now - started < .seconds(4))
        // A freshly written script may be killed before its first line under load; then it never runs.
        try await Task.sleep(for: .milliseconds(300))
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8) else { return }
        let pid = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        var gone = false
        for _ in 0..<200 where !gone {
            gone = kill(pid, 0) != 0
            if !gone { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(gone, "codex still runs")
    }

    @MainActor
    @Test func R07__the_plugin_starts_without_running_codex() async throws {
        let directory = try makeDirectory()
        let script = directory.appendingPathComponent("codex")
        let ran = directory.appendingPathComponent("ran")
        try "#!/bin/sh\ntouch '\(ran.path)'\necho 'codex-cli 0.150.0'\n".write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        let plugin = AgentsPlugin(
            context: try makeContext(host: FakeHost(), directory: directory),
            socketPath: directory.appendingPathComponent("s").path,
            settingsURL: directory.appendingPathComponent("settings.json"),
            activator: FakeActivator(),
            codexEndpoint: CodexEndpoint(home: directory),
            codexExecutable: script,
            codexLauncher: FakeLauncher(socketPath: ""),
            codexTerminal: { _ in nil }
        )
        #expect(!FileManager.default.fileExists(atPath: ran.path))
        #expect(plugin.codex.install == nil)
        await plugin.codex.checkVersion()
        #expect(FileManager.default.fileExists(atPath: ran.path))
        #expect(plugin.codex.install == CodexInstall(executable: script, version: "0.150.0"))
        #expect(plugin.codex.install?.warning?.contains("0.153.4") == true)
    }
}

// MARK: The session decision on the Agents screen

extension CodexBridgeTests {
    @Test func R07__the_detail_screen_offers_the_session_decision_codex_allows() async throws {
        try connect()
        host.responses = Array(repeating: Self.answer(CodexBridge.detailsButtonID), count: 3)
        guard case .object(var long) = try codexFixture("commandApprovalLong"), case .object(var params) = long["params"] else { return }
        params["availableDecisions"] = .array([.string("accept"), .string("acceptForSession"), .string("decline")])
        long["params"] = .object(params)
        var task = bridge.receive(.object(long))
        var item = try await screenItem()
        #expect(item.allowsSession)
        try capture(AgentsScreen(model: bridge.screen).padding(.horizontal, 12).frame(width: 390, height: 400).background(Color.black), named: "R07-render-screen-session")
        bridge.screen.respond(to: item.id, with: .allowForSession)
        await task?.value
        // The fixture's own prompt does not offer it.
        task = bridge.receive(try codexFixture("commandApprovalLong"))
        item = try await screenItem()
        #expect(!item.allowsSession)
        bridge.screen.respond(to: item.id, with: .deny(reason: ""))
        await task?.value
        // File changes always may be allowed for the session.
        bridge.receive(try codexFixture("fileChangeStarted"))
        task = bridge.receive(try codexFixture("fileChangeApproval"))
        item = try await screenItem()
        #expect(item.allowsSession)
        bridge.screen.respond(to: item.id, with: .allowForSession)
        await task?.value
        #expect(outbox.messages == [
            try jsonValue(#"{"id":"req-8","result":{"decision":"acceptForSession"}}"#),
            try jsonValue(#"{"id":"req-8","result":{"decision":"decline"}}"#),
            try jsonValue(#"{"id":10,"result":{"decision":"acceptForSession"}}"#),
        ])
    }
}
