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
        // Connected only once the server accepts `initialize`.
        #expect(link.state == .connecting)
        // The old session unwinds only now, after handing over a request it read before 해제.
        old.deliver(CodexBridge.encode(try codexFixture("commandApproval")))
        old.finish()
        try await Task.sleep(for: .milliseconds(200))
        #expect(host.requests.isEmpty)
        #expect(link.state == .connecting)
        // The replacement still works: its answer to initialize gets `initialized` back.
        new.deliver(#"{"id":1,"result":{}}"#)
        #expect(await eventually { new.sent.count == 3 })
        #expect(new.sent.dropFirst().first == #"{"method":"initialized"}"#)
        #expect(link.state == .connected(.reused))
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

// MARK: Every way a request leaves

extension CodexBridgeTests {
    @Test(arguments: [
        // A secret question, which the terminal asks.
        #"{"id":"req-8","method":"item/tool/requestUserInput","params":{"threadId":"019a0000-0000-7000-8000-000000000001","turnId":"t","itemId":"call_7","isBlocking":true,"questions":[{"id":"q_token","header":"토큰","question":"API 토큰을 입력해 주세요","isOther":false,"isSecret":true,"options":null}]}}"#,
        // A question that cannot be read.
        #"{"id":"req-8","method":"item/tool/requestUserInput","params":{"threadId":"019a0000-0000-7000-8000-000000000001","turnId":"t","itemId":"call_7","isBlocking":true,"questions":[{"header":"토큰"}]}}"#,
        // A request meant for another client.
        #"{"id":"req-8","method":"item/tool/call","params":{"threadId":"019a0000-0000-7000-8000-000000000001","turnId":"t","callId":"c","tool":"lookup","arguments":{}}}"#,
    ])
    func R07__a_reused_id_withdraws_the_older_request_whatever_replaces_it(replacement: String) async throws {
        try connect()
        host.responses = [Self.answer(CodexBridge.detailsButtonID)]
        let first = bridge.receive(try codexFixture("commandApprovalLong"))
        let item = try await screenItem()
        #expect(bridge.receive(try jsonValue(replacement)) == nil)
        for _ in 0..<100 where !bridge.screen.items.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(bridge.screen.items.isEmpty, "the older request still waits")
        // The older request's answer must not go out as the answer to its replacement.
        bridge.screen.respond(to: item.id, with: .allow)
        await first?.value
        #expect(outbox.messages.isEmpty)
    }

    @Test func R07__a_request_withdrawn_before_it_is_shown_never_reaches_the_notch() async throws {
        try connect()
        let resolved = bridge.receive(try codexFixture("commandApproval"))
        bridge.receive(try codexFixture("resolved"))
        await resolved?.value
        let closed = bridge.receive(try codexFixture("userInput"))
        bridge.close()
        await closed?.value
        #expect(host.requests.isEmpty)
        #expect(outbox.messages.isEmpty)
    }

    static let mixedQuestions = #"{"id":15,"method":"item/tool/requestUserInput","params":{"threadId":"019a0000-0000-7000-8000-000000000001","turnId":"t","itemId":"call_8","isBlocking":true,"questions":[{"id":"q_note","header":"메모","question":"남길 말이 있나요?","isOther":true,"isSecret":false,"options":[{"label":"없어요","description":""}]},{"id":"q_env","header":"환경","question":"어디에 올릴까요?","isOther":false,"isSecret":false,"options":[{"label":"staging","description":""},{"label":"production","description":""}]}]}}"#

    @Test func R07__the_screen_sends_only_answers_codex_accepts() async throws {
        try connect()
        host.responses = [Self.answer(CodexBridge.typeAnswersButtonID)]
        let task = bridge.receive(try jsonValue(Self.mixedQuestions))
        let item = try await screenItem()
        guard case .questions(let questions, let picked) = item.content else {
            Issue.record("not a question form")
            return
        }
        var draft = AnswerDraft(questions, picked: picked)
        draft.type("배포가 끝나면 알려 주세요", at: 0)
        // Typed into a question that only takes its options: 보내기 must stay off.
        draft.type("스테이징", at: 1)
        #expect(draft.answers == nil, "the screen accepts an answer codex never receives")
        draft.pick("production", at: 1)
        #expect(draft.answers != nil)
        bridge.screen.respond(to: item.id, with: draft.response)
        await task?.value
        #expect(outbox.messages == [try jsonValue(#"{"id":15,"result":{"answers":{"q_note":{"answers":["배포가 끝나면 알려 주세요"]},"q_env":{"answers":["production"]}}}}"#)])
    }
}

/// Link states in the order they were set.
@MainActor
final class StateLog {
    var all: [CodexLink.State] = []

    func retried(because word: String) -> Bool {
        all.contains { if case .retrying(let reason) = $0 { reason.contains(word) } else { false } }
    }
}

extension CodexLinkTests {
    @Test func R07__a_refused_initialize_drops_the_connection_and_retries() async throws {
        defer { try? FileManager.default.removeItem(atPath: home) }
        let refused = FakeConnection()
        let next = FakeConnection()
        let (link, listener) = try makeLink([refused, next])
        defer { close(listener) }
        let states = StateLog()
        link.onState = { [states] in states.all.append($0) }
        link.start()
        #expect(await eventually { refused.sent.count == 1 })
        refused.deliver(#"{"id":1,"error":{"code":-32600,"message":"Invalid request"}}"#)
        #expect(await eventually { refused.closed }, "the refused connection stays open")
        refused.finish()
        #expect(await eventually { next.sent.count == 1 }, "no new attempt after the refusal")
        #expect(!states.all.contains(.connected(.reused)), "settings showed a connection that never initialized")
        #expect(states.retried(because: "초기화"))
        link.stop()
        next.finish()
    }
}

@MainActor
@Suite struct CodexOwnershipTests {
    @Test func R07__releasing_the_plugin_frees_the_codex_link_and_model() throws {
        let directory = try makeDirectory()
        weak var link: CodexLink?
        weak var model: CodexModel?
        do {
            let plugin = AgentsPlugin(
                context: try makeContext(host: FakeHost(), directory: directory),
                socketPath: directory.appendingPathComponent("s").path,
                settingsURL: directory.appendingPathComponent("settings.json"),
                activator: FakeActivator(),
                codexEndpoint: CodexEndpoint(home: directory),
                codexExecutable: nil,
                codexLauncher: FakeLauncher(socketPath: ""),
                codexTerminal: { _ in nil }
            )
            link = plugin.codexLink
            model = plugin.codex
        }
        #expect(link == nil, "the link outlives the plugin")
        #expect(model == nil, "the Codex model outlives the plugin")
    }
}

extension WebSocketTests {
    @Test func R07__a_socket_closed_before_its_handshake_never_connects() throws {
        let (folder, path) = makeSocketPath()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let listener = try listen(at: path)
        defer { close(listener) }
        // The link holds the socket before anything can block, so 해제 can close it.
        let socket = try WebSocket(unixPath: path)
        socket.close()
        #expect(throws: WebSocketError.self) { try socket.handshake(timeout: .seconds(1)) }
        _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)
        let accepted = Darwin.accept(listener, nil, nil)
        if accepted >= 0 { close(accepted) }
        #expect(accepted < 0, "the socket connected before its handshake")
    }
}

// MARK: Initialize deadline, the server check, question forms

/// Strings collected on the main actor.
@MainActor
final class Notes {
    var all: [String] = []
}

extension CodexBridgeTests {
    @Test func R07__an_unanswered_initialize_fails_only_its_own_connection() async throws {
        let bridge = CodexBridge(
            context: try makeContext(host: host, directory: try makeDirectory()),
            activator: activator,
            terminal: { _ in nil },
            initializeTimeout: .milliseconds(150)
        )
        let notes = Notes()
        // Replaced at once: its deadline must not fire into the next connection.
        bridge.open(send: { _ in }, ready: { notes.all.append("ready 1") }, failed: { notes.all.append("failed 1: \($0)") })
        bridge.open(send: { _ in }, ready: { notes.all.append("ready 2") }, failed: { notes.all.append("failed 2: \($0)") })
        bridge.receive(try jsonValue(#"{"id":1,"result":{}}"#))
        try await Task.sleep(for: .milliseconds(400))
        #expect(notes.all == ["ready 2"])
        bridge.open(send: { _ in }, ready: { notes.all.append("ready 3") }, failed: { notes.all.append("failed 3: \($0)") })
        #expect(await eventually { notes.all.count == 2 })
        #expect(notes.all.last == "failed 3: app-server가 초기화 요청에 답하지 않았어요.")
        // A closed connection's messages are no longer read.
        bridge.receive(try codexFixture("commandApproval"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(host.requests.isEmpty)
    }

    @Test func R07__an_options_only_question_gets_no_text_field_on_the_screen() async throws {
        try connect()
        host.responses = [Self.answer(CodexBridge.typeAnswersButtonID)]
        let task = bridge.receive(try jsonValue(Self.mixedQuestions))
        let item = try await screenItem()
        guard case .questions(let questions, _) = item.content else {
            Issue.record("not a question form")
            return
        }
        #expect(questions.map(\.takesText) == [true, false])
        try capture(AgentsScreen(model: bridge.screen).padding(.horizontal, 12).frame(width: 390, height: 400).background(Color.black), named: "R07-render-screen-mixed")
        bridge.screen.respond(to: item.id, with: .released)
        await task?.value
    }
}

/// A server check the test holds until it lets go.
final class HeldCheck: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var released = false
    private var mainThread: Bool?

    var hasEntered: Bool { lock.withLock { entered } }
    var ranOnMainThread: Bool? { lock.withLock { mainThread } }
    func release() { lock.withLock { released = true } }

    func check(_ path: String) async -> CodexSupervisor.Check {
        lock.withLock {
            entered = true
            mainThread = pthread_main_np() != 0
        }
        while !lock.withLock({ released }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return .absent
    }
}

extension CodexSupervisorTests {
    @Test func R07__the_server_check_runs_off_the_main_actor_and_disconnect_ends_it() async throws {
        defer { try? FileManager.default.removeItem(atPath: home) }
        let held = HeldCheck()
        let launcher = FakeLauncher(socketPath: endpoint.socketPath)
        defer { launcher.listeners.forEach { close($0) } }
        let supervisor = CodexSupervisor(endpoint: endpoint, executable: codex, launcher: launcher, check: held.check)
        let attempt = Task { try await supervisor.ensure() }
        #expect(await eventually { held.hasEntered })
        #expect(held.ranOnMainThread == false)
        // 해제 as the link does it: cancel the attempt, then stop the supervisor.
        attempt.cancel()
        supervisor.stop()
        held.release()
        await #expect(throws: CancellationError.self) { try await attempt.value }
        #expect(launcher.launches.isEmpty, "a server started after 해제")
    }

    @Test func R07__the_real_check_is_bounded_and_off_the_main_actor() async throws {
        defer { try? FileManager.default.removeItem(atPath: home) }
        let fd = try listen(at: endpoint.socketPath)
        #expect(await CodexSupervisor.check(endpoint.socketPath, timeout: .milliseconds(200)) == .listening)
        // The socket file stays behind, but nothing accepts on it.
        close(fd)
        #expect(await CodexSupervisor.check(endpoint.socketPath, timeout: .milliseconds(200)) == .absent)
    }
}
