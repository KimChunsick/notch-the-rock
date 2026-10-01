import Darwin
import Foundation
import HookBridge
import NotchKit
import SwiftUI
import Testing
@testable import Agents

/// Messages recorded from codex-cli 0.153.4 shapes (see the fixture's `shapesFrom`).
func codexFixture(_ name: String) throws -> JSONValue {
    let url = packageRoot.appendingPathComponent("Tests/Fixtures/codex-0.153.4/messages.json")
    let all = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    return try #require(all["messages"]?[name], "no fixture \(name)")
}

func jsonValue(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

/// What the bridge sent to the app-server.
@MainActor
final class Outbox {
    var messages: [JSONValue] = []
}

@MainActor
@Suite struct CodexBridgeTests {
    static let thread1 = "019a0000-0000-7000-8000-000000000001"
    let host = FakeHost()
    let activator = FakeActivator()
    let outbox = Outbox()
    let bridge: CodexBridge

    init() throws {
        let terminals = ["/Users/me/notch-the-rock": ghostty]
        bridge = CodexBridge(
            context: try makeContext(host: host, directory: try makeDirectory()),
            activator: activator,
            terminal: { cwd in cwd.flatMap { terminals[$0] } }
        )
        bridge.open { [outbox] in outbox.messages.append($0) }
    }

    static func answer(_ buttonID: String?, choices: [String: [String]] = [:], text: String? = nil) -> AttentionResponse {
        .answered(AttentionAnswer(buttonID: buttonID, choices: choices, text: text))
    }

    /// Plays the handshake and resumes the first thread, so its folder is known.
    func connect() throws {
        bridge.receive(try codexFixture("initializeResponse"))
        bridge.receive(try codexFixture("loadedListPage1"))
        bridge.receive(try codexFixture("resumeResponse"))
        outbox.messages.removeAll()
    }

    func screenItem() async throws -> ScreenItem {
        for _ in 0..<200 where bridge.screen.items.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(bridge.screen.items.first)
    }

    // MARK: Handshake and threads

    @Test func R07__initialize_then_list_and_resume_every_loaded_thread() throws {
        #expect(outbox.messages == [try jsonValue(#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"notch-the-rock","title":"NotchTheRock","version":"1.0.0"},"capabilities":{"experimentalApi":true}}}"#)])
        bridge.receive(try codexFixture("initializeResponse"))
        #expect(outbox.messages.dropFirst().map { $0 } == [
            try jsonValue(#"{"method":"initialized"}"#),
            try jsonValue(#"{"id":2,"method":"thread/loaded/list","params":{}}"#),
        ])
        outbox.messages.removeAll()
        bridge.receive(try codexFixture("loadedListPage1"))
        #expect(outbox.messages == [
            try jsonValue(#"{"id":3,"method":"thread/loaded/list","params":{"cursor":"c1"}}"#),
            try jsonValue(#"{"id":4,"method":"thread/resume","params":{"threadId":"019a0000-0000-7000-8000-000000000001","excludeTurns":true}}"#),
        ])
        outbox.messages.removeAll()
        bridge.receive(try codexFixture("loadedListPage2"))
        #expect(outbox.messages == [
            try jsonValue(#"{"id":5,"method":"thread/resume","params":{"threadId":"019a0000-0000-7000-8000-000000000002","excludeTurns":true}}"#),
        ])
        bridge.receive(try codexFixture("resumeResponse"))
        #expect(bridge.threads[Self.thread1] == "/Users/me/notch-the-rock")
    }

    @Test func R07__a_new_thread_is_resumed_when_it_starts() throws {
        try connect()
        bridge.receive(try codexFixture("threadStarted"))
        #expect(outbox.messages == [
            try jsonValue(#"{"id":5,"method":"thread/resume","params":{"threadId":"019a0000-0000-7000-8000-000000000003","excludeTurns":true}}"#),
        ])
        #expect(bridge.threads["019a0000-0000-7000-8000-000000000003"] == "/Users/me/other-project")
    }

    @Test func R07__numeric_ids_go_out_as_integers() throws {
        let text = CodexBridge.encode(try jsonValue(#"{"id":7,"result":{"decision":"accept"}}"#))
        #expect(text.contains(#""id":7"#))
        #expect(!text.contains("7.0"))
    }

    // MARK: Command approvals

    @Test(arguments: [
        (CodexBridge.allowButtonID, "accept"),
        (CodexBridge.allowForSessionButtonID, "acceptForSession"),
        (CodexBridge.denyButtonID, "decline"),
    ])
    func R07__each_command_answer_sends_its_decision(button: String, decision: String) async throws {
        try connect()
        host.responses = [Self.answer(button)]
        await bridge.receive(try codexFixture("commandApproval"))?.value

        let request = try #require(host.requests.first)
        #expect(request.title == "notch-the-rock · 명령 실행")
        #expect(request.message == "swift build")
        #expect(request.buttons.map(\.title) == ["거부", "이번 세션 동안 허용", "허용"])
        #expect(request.releaseTitle == "터미널에서 답하기")
        #expect(outbox.messages == [.object(["id": .number(7), "result": .object(["decision": .string(decision)])])])
    }

    @Test(arguments: [AttentionResponse.released, .timedOut, .dismissed])
    func R07__an_unanswered_request_is_left_to_the_terminal(response: AttentionResponse) async throws {
        try connect()
        host.responses = [response]
        await bridge.receive(try codexFixture("commandApproval"))?.value
        #expect(outbox.messages.isEmpty)
    }

    @Test func R07__a_long_command_is_allowed_only_from_the_full_detail() async throws {
        try connect()
        host.responses = [Self.answer(CodexBridge.detailsButtonID)]
        let task = bridge.receive(try codexFixture("commandApprovalLong"))
        let item = try await screenItem()
        let request = try #require(host.requests.first)
        #expect(request.buttons.map(\.title) == ["거부", "자세히 보기"])
        guard case .permission(let detail) = item.content else {
            Issue.record("not a permission: \(item.content)")
            return
        }
        #expect(detail.sections.first?.body.hasSuffix("tee /tmp/notch-context-report.txt") == true)
        #expect(detail.sections.map(\.label).contains("이유"))
        bridge.screen.respond(to: item.id, with: .allow)
        await task?.value
        #expect(outbox.messages == [try jsonValue(#"{"id":"req-8","result":{"decision":"accept"}}"#)])
    }

    @Test func R07__network_access_is_shown_in_full_before_it_is_allowed() async throws {
        try connect()
        host.responses = [Self.answer(CodexBridge.detailsButtonID)]
        let task = bridge.receive(try codexFixture("commandApprovalNetwork"))
        let item = try await screenItem()
        #expect(host.requests.first?.buttons.map(\.id) == [CodexBridge.denyButtonID, CodexBridge.detailsButtonID])
        guard case .permission(let detail) = item.content else { return }
        #expect(detail.sections.contains { $0.body.contains("example.com") })
        bridge.screen.respond(to: item.id, with: .deny(reason: ""))
        await task?.value
        #expect(outbox.messages == [try jsonValue(#"{"id":9,"result":{"decision":"decline"}}"#)])
    }

    // MARK: File changes

    @Test func R07__a_file_change_shows_its_diff_before_it_is_allowed() async throws {
        try connect()
        #expect(bridge.receive(try codexFixture("fileChangeStarted")) == nil)
        host.responses = [Self.answer(CodexBridge.detailsButtonID)]
        let task = bridge.receive(try codexFixture("fileChangeApproval"))
        let item = try await screenItem()
        let request = try #require(host.requests.first)
        #expect(request.title == "notch-the-rock · 파일 수정")
        #expect(request.buttons.map(\.title) == ["거부", "자세히 보기"])
        guard case .permission(let detail) = item.content else { return }
        #expect(detail.sections == [OperationDetail.Section(label: "/Users/me/notch-the-rock/README.md (수정)", body: "@@ -1 +1 @@\n-# Notch\n+# NotchTheRock\n")])
        bridge.screen.respond(to: item.id, with: .allow)
        await task?.value
        #expect(outbox.messages == [try jsonValue(#"{"id":10,"result":{"decision":"accept"}}"#)])
    }

    @Test func R07__an_unseen_file_change_can_only_be_declined() async throws {
        try connect()
        host.responses = [Self.answer(CodexBridge.denyButtonID)]
        await bridge.receive(try codexFixture("fileChangeApprovalUnseen"))?.value
        #expect(host.requests.first?.buttons.map(\.id) == [CodexBridge.denyButtonID])
        #expect(outbox.messages == [try jsonValue(#"{"id":11,"result":{"decision":"decline"}}"#)])
    }

    // MARK: Questions

    @Test func R07__a_picked_option_answers_by_question_id() async throws {
        try connect()
        host.responses = [Self.answer(nil, choices: ["q_target": ["staging"]], text: "")]
        await bridge.receive(try codexFixture("userInput"))?.value
        let request = try #require(host.requests.first)
        #expect(request.title == "notch-the-rock · Codex의 질문")
        #expect(request.choices == [AttentionChoices(id: "q_target", prompt: "배포 대상 · 어디에 배포할까요?", options: ["staging", "production"])])
        #expect(request.textField != nil)
        #expect(outbox.messages == [try jsonValue(#"{"id":12,"result":{"answers":{"q_target":{"answers":["staging"]}}}}"#)])
    }

    @Test func R07__typed_text_answers_a_single_question() async throws {
        try connect()
        host.responses = [Self.answer(nil, text: " qa ")]
        await bridge.receive(try codexFixture("userInput"))?.value
        #expect(outbox.messages == [try jsonValue(#"{"id":12,"result":{"answers":{"q_target":{"answers":["qa"]}}}}"#)])
    }

    @Test func R07__several_questions_answer_each_by_its_id() async throws {
        try connect()
        host.responses = [Self.answer(CodexBridge.sendAnswersButtonID, choices: ["q_branch": ["develop"], "q_tag": ["아니요"]])]
        await bridge.receive(try codexFixture("userInputTwo"))?.value
        #expect(host.requests.first?.choices.map(\.id) == ["q_branch", "q_tag"])
        #expect(outbox.messages == [try jsonValue(#"{"id":13,"result":{"answers":{"q_branch":{"answers":["develop"]},"q_tag":{"answers":["아니요"]}}}}"#)])
    }

    @Test func R07__a_secret_question_stays_in_the_terminal() async throws {
        try connect()
        await bridge.receive(try codexFixture("userInputSecret"))?.value
        #expect(host.requests.isEmpty)
        #expect(outbox.messages.isEmpty)
    }

    // MARK: Answered elsewhere, turn completed

    @Test func R07__a_request_answered_in_the_terminal_leaves_the_notch() async throws {
        try connect()
        host.waitsForCancellation = true
        let task = bridge.receive(try codexFixture("commandApproval"))
        for _ in 0..<200 where host.requests.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(bridge.receive(try codexFixture("resolved")) == nil)
        await task?.value
        #expect(host.cancellations == 1)
        #expect(outbox.messages.isEmpty)
    }

    @Test func R07__a_closed_connection_withdraws_every_request() async throws {
        try connect()
        host.waitsForCancellation = true
        let task = bridge.receive(try codexFixture("userInput"))
        for _ in 0..<200 where host.requests.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        bridge.close()
        await task?.value
        #expect(host.cancellations == 1)
        #expect(outbox.messages.isEmpty)
    }

    @Test func R07__turn_completed_glows_with_the_project_and_jumps_to_its_terminal() async throws {
        try connect()
        host.responses = [.answered(AttentionAnswer(buttonID: CodexBridge.jumpButtonID))]
        await bridge.receive(try codexFixture("turnCompleted"))?.value
        let request = try #require(host.requests.first)
        #expect(request.title == "notch-the-rock")
        #expect(request.message == "Codex가 작업을 마쳤어요.")
        #expect(request.buttons.map(\.title) == ["터미널로 이동"])
        #expect(activator.activated == [ghostty])
        #expect(bridge.receive(try codexFixture("turnInterrupted")) == nil)
    }

    @Test func R07__an_unknown_terminal_just_opens_the_notch() async throws {
        try connect()
        bridge.receive(try codexFixture("threadStarted"))
        host.responses = [.answered(AttentionAnswer(buttonID: CodexBridge.jumpButtonID))]
        let done = #"{"method":"turn/completed","params":{"threadId":"019a0000-0000-7000-8000-000000000003","turn":{"id":"t","items":[],"status":"completed"}}}"#
        await bridge.receive(try jsonValue(done))?.value
        #expect(host.requests.first?.title == "other-project")
        #expect(host.requests.first?.buttons.map(\.title) == ["노치 열기"])
        #expect(activator.activated.isEmpty)
        #expect(host.expansions == 1)
    }

    // MARK: Untrusted messages

    @Test func R07__only_an_exact_integer_id_answers_a_call() throws {
        // The bridge's first call is `initialize`, id 1.
        for id in ["1.9", #""1""#, "-0", "1.0000001"] {
            bridge.receive(try jsonValue(#"{"id":\#(id),"result":{}}"#))
        }
        #expect(outbox.messages.count == 1)
        #expect(host.logs.count == 4)
        bridge.receive(try jsonValue(#"{"id":1,"result":{}}"#))
        #expect(outbox.messages.dropFirst().first == (try jsonValue(#"{"method":"initialized"}"#)))
    }

    @Test func R07__a_huge_numeric_id_is_ignored() throws {
        bridge.receive(try jsonValue(#"{"id":1e100,"result":{}}"#))
        bridge.receive(try jsonValue(#"{"id":-1e300,"result":{}}"#))
        #expect(outbox.messages.count == 1)
        #expect(host.logs.count == 2)
    }

    @Test func R07__a_reused_request_id_withdraws_the_older_request() async throws {
        try connect()
        host.responses = [Self.answer(CodexBridge.detailsButtonID), .dismissed]
        // The first request waits on the Agents screen when the server sends another with its id.
        let first = bridge.receive(try codexFixture("commandApprovalLong"))
        let item = try await screenItem()
        guard case .object(var reused) = try codexFixture("commandApproval") else { return }
        reused["id"] = .string("req-8")
        await bridge.receive(.object(reused))?.value
        for _ in 0..<100 where !bridge.screen.items.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(bridge.screen.items.isEmpty, "the older request still waits")
        // Answering the withdrawn request afterwards reaches neither connection.
        let later = Outbox()
        bridge.open { [later] in later.messages.append($0) }
        bridge.screen.respond(to: item.id, with: .allow)
        await first?.value
        #expect(outbox.messages.isEmpty)
        #expect(later.messages.map { $0["method"] } == [.string("initialize")])
    }

    @Test(arguments: [
        // No patch.
        #"[{"path":"/Users/me/notch-the-rock/a.txt","kind":{"type":"update","move_path":null}}]"#,
        // The second change has no path.
        #"[{"path":"/Users/me/notch-the-rock/a.txt","kind":{"type":"add"},"diff":"+a\n"},{"kind":{"type":"delete"},"diff":"-b\n"}]"#,
        // A kind codex 0.153.4 does not send.
        #"[{"path":"/Users/me/notch-the-rock/a.txt","kind":{"type":"chmod"},"diff":""}]"#,
        "[]",
    ])
    func R07__a_change_that_is_not_fully_readable_can_only_be_declined(changes: String) async throws {
        try connect()
        bridge.receive(try jsonValue(#"{"method":"item/started","params":{"threadId":"019a0000-0000-7000-8000-000000000001","turnId":"t","startedAtMs":1,"item":{"type":"fileChange","id":"call_4","status":"inProgress","changes":\#(changes)}}}"#))
        host.responses = [Self.answer(CodexBridge.denyButtonID)]
        await bridge.receive(try codexFixture("fileChangeApproval"))?.value
        let request = try #require(host.requests.first)
        #expect(request.buttons.map(\.id) == [CodexBridge.denyButtonID])
        #expect(request.message.contains("읽지 못한"))
        #expect(outbox.messages == [try jsonValue(#"{"id":10,"result":{"decision":"decline"}}"#)])
    }

    @Test func R07__a_command_run_in_another_folder_shows_that_folder() async throws {
        try connect()
        host.responses = [Self.answer(CodexBridge.allowButtonID), .dismissed]
        func approval(_ id: Int, cwd: String) throws -> JSONValue {
            try jsonValue(#"{"id":\#(id),"method":"item/commandExecution/requestApproval","params":{"threadId":"019a0000-0000-7000-8000-000000000001","turnId":"t","itemId":"c\#(id)","startedAtMs":1,"command":"rm -rf ./build","cwd":"\#(cwd)","kind":"command","availableDecisions":["accept","decline"]}}"#)
        }
        await bridge.receive(try approval(21, cwd: "/Users/me/elsewhere/app"))?.value
        let request = try #require(host.requests.first)
        #expect(request.title == "app · 명령 실행")
        #expect(request.message == "rm -rf ./build\n폴더: /Users/me/elsewhere/app")
        #expect(request.buttons.map(\.id) == [CodexBridge.denyButtonID, CodexBridge.allowButtonID])
        #expect(outbox.messages == [try jsonValue(#"{"id":21,"result":{"decision":"accept"}}"#)])
        // A folder too long to show with the command sends the request to the full detail.
        let deep = "/Users/me/" + String(repeating: "deep/", count: 30) + "app"
        await bridge.receive(try approval(22, cwd: deep))?.value
        #expect(host.requests.last?.buttons.map(\.id) == [CodexBridge.denyButtonID, CodexBridge.detailsButtonID])
    }

    @Test func R07__render_approval_question_and_settings() async throws {
        try connect()
        host.responses = [.released, .released]
        await bridge.receive(try codexFixture("commandApproval"))?.value
        await bridge.receive(try codexFixture("userInput"))?.value
        try capture(AttentionPreview(request: host.requests[0]), named: "R07-render-approval")
        try capture(AttentionPreview(request: host.requests[1]), named: "R07-render-question")

        let directory = try makeDirectory()
        let defaults = try #require(UserDefaults(suiteName: isolatedDefaultsSuite(in: directory)))
        let codex = CodexModel(defaults: defaults, executable: URL(fileURLWithPath: "/opt/homebrew/bin/codex"), readVersion: { _ in "0.150.0" }, start: {}, stop: {})
        await codex.checkVersion()
        let hooks = ClaudeHooksModel(installer: HookInstaller(
            settingsURL: directory.appendingPathComponent("settings.json"),
            recordURL: directory.appendingPathComponent("record.json"),
            entries: HookEntry.claude(helper: directory.appendingPathComponent("notch-hook"))
        ))
        try capture(Form { AgentsSettingsView(model: hooks, codex: codex, defaults: defaults) }.formStyle(.grouped).frame(width: 520), named: "R07-render-settings")
    }
}

// MARK: WebSocket framing

/// Reads from `fd` until `buffer` holds a whole frame, and returns it.
func readFrame(_ fd: Int32, _ buffer: inout Data) throws -> WebSocketFrame {
    while true {
        if let (frame, used) = try WebSocketFrame.decode(buffer) {
            buffer.removeFirst(used)
            return frame
        }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &chunk, chunk.count)
        try #require(count > 0, "the socket closed")
        buffer.append(contentsOf: chunk.prefix(count))
    }
}

/// The next frame within `seconds`, or nil when none arrives in time or the socket closes.
func readFrame(_ fd: Int32, _ buffer: inout Data, within seconds: Int) throws -> WebSocketFrame? {
    var limit = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    while true {
        if let (frame, used) = try WebSocketFrame.decode(buffer) {
            buffer.removeFirst(used)
            return frame
        }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &chunk, chunk.count)
        guard count > 0 else { return nil }
        buffer.append(contentsOf: chunk.prefix(count))
    }
}

/// A flag set on one thread and read on another.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// Reads the client's HTTP request up to its blank line.
func readHandshake(_ fd: Int32) throws -> String {
    var data = Data()
    while !data.contains("\r\n\r\n".data(using: .utf8)!) {
        var byte: UInt8 = 0
        try #require(read(fd, &byte, 1) == 1)
        data.append(byte)
    }
    return String(decoding: data, as: UTF8.self)
}

func writeAll(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
}

@Suite struct WebSocketTests {
    func socketPair() throws -> (client: Int32, server: Int32) {
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        // The client may close while the test still writes.
        var on: Int32 = 1
        setsockopt(fds[1], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return (fds[0], fds[1])
    }

    func accept(_ server: Int32) throws {
        let request = try readHandshake(server)
        #expect(request.hasPrefix("GET / HTTP/1.1\r\n"))
        #expect(request.contains("Upgrade: websocket\r\n"))
        #expect(request.contains("Sec-WebSocket-Version: 13\r\n"))
        let key = try #require(request.split(separator: "\r\n").first { $0.hasPrefix("Sec-WebSocket-Key: ") }?.dropFirst(19))
        writeAll(server, Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(WebSocket.acceptKey(for: String(key)))\r\n\r\n".utf8))
    }

    @Test func R07__accept_key_matches_rfc6455() {
        #expect(WebSocket.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    @Test func R07__masked_text_fragments_ping_pong_and_close() async throws {
        let (clientFD, server) = try socketPair()
        defer { close(server) }
        let socket = WebSocket(fd: clientFD)
        let client = Task.detached { () throws -> [String?] in
            try socket.handshake()
            socket.send(text: #"{"method":"initialized"}"#)
            return [try socket.receive(), try socket.receive()]
        }
        try accept(server)
        var buffer = Data()
        let sent = try readFrame(server, &buffer)
        #expect(sent.masked)
        #expect(sent.opcode == .text && sent.fin)
        #expect(String(decoding: sent.payload, as: UTF8.self) == #"{"method":"initialized"}"#)

        writeAll(server, WebSocketFrame(fin: true, opcode: .ping, payload: Data("p".utf8)).encoded(mask: nil))
        writeAll(server, WebSocketFrame(fin: false, opcode: .text, payload: Data(#"{"id":"#.utf8)).encoded(mask: nil))
        writeAll(server, WebSocketFrame(fin: true, opcode: .continuation, payload: Data("1}".utf8)).encoded(mask: nil))
        let pong = try readFrame(server, &buffer)
        #expect(pong.opcode == .pong && pong.masked)
        #expect(pong.payload == Data("p".utf8))

        writeAll(server, WebSocketFrame(fin: true, opcode: .close, payload: Data([0x03, 0xE8])).encoded(mask: nil))
        let messages = try await client.value
        #expect(messages == [#"{"id":1}"#, nil])
        let closing = try readFrame(server, &buffer)
        #expect(closing.opcode == .close && closing.masked)
        socket.close()
    }

    @Test func R07__long_payloads_use_extended_lengths() throws {
        let payload = Data(repeating: 0x41, count: 70_000)
        let encoded = WebSocketFrame(fin: true, opcode: .text, payload: payload).encoded(mask: [1, 2, 3, 4])
        #expect(encoded[1] == 0x80 | 127)
        let (decoded, used) = try #require(try WebSocketFrame.decode(encoded))
        #expect(used == encoded.count)
        #expect(decoded.payload == payload)
        let medium = WebSocketFrame(fin: true, opcode: .text, payload: Data(repeating: 0x42, count: 300)).encoded(mask: nil)
        #expect(medium[1] == 126)
        #expect(try WebSocketFrame.decode(medium.prefix(100)) == nil)
    }

    @Test func R07__a_refused_upgrade_fails_the_handshake() async throws {
        let (clientFD, server) = try socketPair()
        defer { close(server) }
        let socket = WebSocket(fd: clientFD)
        let client = Task.detached { () -> Bool in
            do { try socket.handshake(); return true } catch { return false }
        }
        _ = try readHandshake(server)
        writeAll(server, Data("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n".utf8))
        #expect(await client.value == false)
        socket.close()
    }

    @Test func R07__a_ping_between_fragments_does_not_end_the_message() async throws {
        let (clientFD, server) = try socketPair()
        defer { close(server) }
        let socket = WebSocket(fd: clientFD)
        defer { socket.close() }
        let client = Task.detached { () throws -> String? in
            try socket.handshake()
            return try socket.receive()
        }
        try accept(server)
        writeAll(server, WebSocketFrame(fin: false, opcode: .text, payload: Data(#"{"id":"#.utf8)).encoded(mask: nil))
        writeAll(server, WebSocketFrame(fin: true, opcode: .ping, payload: Data("p".utf8)).encoded(mask: nil))
        writeAll(server, WebSocketFrame(fin: true, opcode: .continuation, payload: Data("1}".utf8)).encoded(mask: nil))
        var buffer = Data()
        #expect(try readFrame(server, &buffer, within: 2)?.opcode == .pong)
        #expect(try await client.value == #"{"id":1}"#)
    }

    @Test(arguments: [
        // The top bit of the 64-bit length.
        [0x81, 127, 0x80, 0, 0, 0, 0, 0, 0, 0] as [UInt8],
        // 16 MiB + 1.
        [0x81, 127, 0, 0, 0, 0, 0x01, 0, 0, 0x01],
    ])
    func R07__an_oversized_frame_is_refused_at_once(header: [UInt8]) async throws {
        let (clientFD, server) = try socketPair()
        defer { close(server) }
        let socket = WebSocket(fd: clientFD)
        defer { socket.close() }
        let client = Task.detached { () -> Bool in
            do {
                try socket.handshake()
                _ = try socket.receive()
                return false
            } catch {
                return true
            }
        }
        try accept(server)
        writeAll(server, Data(header))
        var buffer = Data()
        let closing = try readFrame(server, &buffer, within: 2)
        #expect(closing?.opcode == .close)
        #expect(closing?.payload == Data([0x03, 0xF1]))
        // Ends a client still waiting for the payload.
        shutdown(server, SHUT_RDWR)
        #expect(await client.value)
    }

    @Test func R07__sending_never_waits_for_a_peer_that_stopped_reading() async throws {
        let (clientFD, server) = try socketPair()
        defer { close(server) }
        let socket = WebSocket(fd: clientFD)
        let big = String(repeating: "a", count: 8 << 20)
        let returned = Flag()
        let sending = Task.detached {
            socket.send(text: big)
            returned.set()
        }
        // A blocking write would never return: the peer never reads. Masking 8 MiB in a debug build
        // takes a while under a loaded test run, so the wait is generous.
        for _ in 0..<500 where !returned.isSet {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(returned.isSet, "send waited for the peer")
        // Disconnect still works while the write is stuck.
        socket.close()
        await sending.value
        #expect(throws: (any Error).self) { try socket.receive() }
    }
}

// MARK: Supervisor, install, terminal mapping

/// Starts nothing: records each launch, and when `listens` binds a user-only listening socket where
/// codex would, as `codex app-server --listen unix://…` does.
@MainActor
final class FakeLauncher: CodexLaunching {
    final class FakeProcess: CodexServerProcess {
        var terminated = false
        let exit: @Sendable (Int32) -> Void
        init(exit: @escaping @Sendable (Int32) -> Void) { self.exit = exit }
        func terminate() { terminated = true }
    }

    var launches: [(executable: URL, arguments: [String], environment: [String: String])] = []
    var processes: [FakeProcess] = []
    var listeners: [Int32] = []
    var listens = true
    let socketPath: String

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func launch(_ executable: URL, arguments: [String], environment: [String: String], onExit: @escaping @Sendable (Int32) -> Void) throws -> any CodexServerProcess {
        launches.append((executable, arguments, environment))
        if listens {
            listeners.append(try listen(at: socketPath))
        }
        let process = FakeProcess(exit: onExit)
        processes.append(process)
        return process
    }
}

/// A listening Unix socket at `path` in a 0700 folder, the socket 0600.
func listen(at path: String, folderMode: mode_t = 0o700) throws -> Int32 {
    let folder = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    chmod(folder, folderMode)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        path.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) }
    }
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    try #require(bound == 0, "bind \(errno)")
    chmod(path, 0o600)
    try #require(Darwin.listen(fd, 4) == 0)
    return fd
}

@MainActor
@Suite struct CodexSupervisorTests {
    let home = "/tmp/nk-\(UUID().uuidString.prefix(8))"
    var endpoint: CodexEndpoint { CodexEndpoint(home: URL(fileURLWithPath: home)) }
    let codex = URL(fileURLWithPath: "/opt/homebrew/bin/codex")

    @Test func R07__the_default_endpoint_follows_codex_home() {
        let fallback = CodexEndpoint.current(environment: [:], home: URL(fileURLWithPath: "/Users/me"))
        #expect(fallback.socketPath == "/Users/me/.codex/app-server-control/app-server-control.sock")
        let set = CodexEndpoint.current(environment: ["CODEX_HOME": home], home: URL(fileURLWithPath: "/Users/me"))
        #expect(set.socketPath == home + "/app-server-control/app-server-control.sock")
    }

    @Test func R07__a_listening_user_only_server_is_reused_and_never_stopped() async throws {
        defer { try? FileManager.default.removeItem(atPath: home) }
        let fd = try listen(at: endpoint.socketPath)
        defer { close(fd) }
        let launcher = FakeLauncher(socketPath: endpoint.socketPath)
        let supervisor = CodexSupervisor(endpoint: endpoint, executable: codex, launcher: launcher)
        #expect(try await supervisor.ensure() == .reused)
        #expect(launcher.launches.isEmpty)
        supervisor.stop()
        #expect(FileManager.default.fileExists(atPath: endpoint.socketPath))
    }

    @Test func R07__without_a_server_one_is_spawned_and_stopped_on_disconnect() async throws {
        defer { try? FileManager.default.removeItem(atPath: home) }
        let launcher = FakeLauncher(socketPath: endpoint.socketPath)
        defer { launcher.listeners.forEach { close($0) } }
        let supervisor = CodexSupervisor(endpoint: endpoint, executable: codex, launcher: launcher)
        #expect(try await supervisor.ensure() == .spawned)
        let launch = try #require(launcher.launches.first)
        #expect(launch.executable == codex)
        #expect(launch.arguments == ["app-server", "--listen", "unix://" + endpoint.socketPath])
        #expect(launch.environment["CODEX_HOME"] == home)
        // Already running: the next check reuses its own server without a second launch.
        #expect(try await supervisor.ensure() == .spawned)
        #expect(launcher.launches.count == 1)
        supervisor.stop()
        #expect(launcher.processes.map(\.terminated) == [true])
    }

    @Test func R07__an_own_server_that_exited_is_spawned_again() async throws {
        defer { try? FileManager.default.removeItem(atPath: home) }
        let launcher = FakeLauncher(socketPath: endpoint.socketPath)
        let supervisor = CodexSupervisor(endpoint: endpoint, executable: codex, launcher: launcher)
        #expect(try await supervisor.ensure() == .spawned)
        launcher.listeners.forEach { close($0) }
        launcher.listeners.removeAll()
        unlink(endpoint.socketPath)
        launcher.processes[0].exit(1)
        for _ in 0..<100 where supervisor.ownsServer {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await supervisor.ensure() == .spawned)
        #expect(launcher.launches.count == 2)
        launcher.listeners.forEach { close($0) }
        supervisor.stop()
        #expect(launcher.processes.map(\.terminated) == [false, true])
    }

    @Test func R07__a_socket_folder_others_can_enter_is_refused() async throws {
        defer { try? FileManager.default.removeItem(atPath: home) }
        let fd = try listen(at: endpoint.socketPath, folderMode: 0o755)
        defer { close(fd) }
        let launcher = FakeLauncher(socketPath: endpoint.socketPath)
        let supervisor = CodexSupervisor(endpoint: endpoint, executable: codex, launcher: launcher)
        await #expect(throws: CodexServerError.self) { try await supervisor.ensure() }
        #expect(launcher.launches.isEmpty)
    }

    @Test func R07__a_server_that_never_listens_fails_the_attempt() async throws {
        defer { try? FileManager.default.removeItem(atPath: home) }
        let launcher = FakeLauncher(socketPath: endpoint.socketPath)
        launcher.listens = false
        let supervisor = CodexSupervisor(endpoint: endpoint, executable: codex, launcher: launcher, startTimeout: .milliseconds(200))
        await #expect(throws: CodexServerError.self) { try await supervisor.ensure() }
        #expect(launcher.processes.map(\.terminated) == [true])
    }

    @Test func R07__retries_back_off_up_to_thirty_seconds() {
        #expect((0..<7).map(CodexSupervisor.backoff) == [1, 2, 4, 8, 16, 30, 30].map { Duration.seconds($0) })
    }
}

@Suite struct CodexInstallTests {
    @Test func R07__version_warning_names_the_tested_version() {
        let codex = URL(fileURLWithPath: "/opt/homebrew/bin/codex")
        #expect(CodexInstall(executable: codex, version: "0.153.4").warning == nil)
        #expect(CodexInstall(executable: codex, version: "0.160.0").warning?.contains("0.153.4") == true)
        #expect(CodexInstall(executable: codex, version: nil).warning != nil)
        #expect(CodexInstall.parseVersion("codex-cli 0.153.4\n") == "0.153.4")
        #expect(CodexInstall.parseVersion("garbage") == nil)
    }

    @Test func R07__find_takes_the_first_executable_and_its_version_is_read_later() async throws {
        let directory = try makeDirectory()
        let script = directory.appendingPathComponent("codex")
        try "#!/bin/sh\necho 'codex-cli 0.150.0'\n".write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        #expect(CodexInstall.find(candidates: [directory.appendingPathComponent("missing").path, script.path]) == script)
        #expect(CodexInstall.find(candidates: [directory.appendingPathComponent("missing").path]) == nil)
        #expect(await CodexInstall.readVersion(script) == "0.150.0")
    }
}

@Suite struct CodexTerminalTests {
    let terminal = TerminalLocation(bundleID: "com.apple.Terminal", tty: "/dev/ttys004")
    let other = TerminalLocation(bundleID: "com.mitchellh.ghostty", tty: "/dev/ttys009")

    @Test func R07__the_tui_in_the_thread_folder_names_the_terminal() {
        let processes = [CodexProcess(pid: 10, cwd: "/Users/me/a"), CodexProcess(pid: 11, cwd: "/Users/me/b"), CodexProcess(pid: 12, cwd: "/Users/me/a")]
        let terminals: [pid_t: TerminalLocation] = [10: terminal, 11: other]
        // pid 12 (the app-server, started by the app) has no terminal and does not count.
        #expect(CodexTerminals.terminal(forCwd: "/Users/me/a", processes: processes) { terminals[$0] } == terminal)
        #expect(CodexTerminals.terminal(forCwd: "/Users/me/c", processes: processes) { terminals[$0] } == nil)
    }

    @Test func R07__two_terminals_in_one_folder_are_ambiguous() {
        let processes = [CodexProcess(pid: 10, cwd: "/Users/me/a"), CodexProcess(pid: 11, cwd: "/Users/me/a")]
        let terminals: [pid_t: TerminalLocation] = [10: terminal, 11: other]
        #expect(CodexTerminals.terminal(forCwd: "/Users/me/a", processes: processes) { terminals[$0] } == nil)
    }

    @Test func R07__system_listing_reads_this_process_folder() {
        // This test runner is not named codex, so it is not listed; the listing still runs.
        #expect(CodexTerminals.systemProcesses().allSatisfy { !$0.cwd.isEmpty })
    }
}

/// Connects to a throwaway app-server when `CODEX_PROBE_SOCKET` is set (see the plugin's probe
/// instructions) and writes the transcript to `CODEX_PROBE_TRANSCRIPT`.
@Suite struct CodexProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_PROBE_SOCKET"] != nil))
    func R07__probe_a_throwaway_app_server() async throws {
        let environment = ProcessInfo.processInfo.environment
        let path = try #require(environment["CODEX_PROBE_SOCKET"])
        var transcript = "# R07 probe — WebSocket over \(path), codex app-server with a temporary CODEX_HOME\n"
        let socket = try WebSocket.connect(unixPath: path)
        defer { socket.close() }
        transcript += "handshake: 101 Switching Protocols, Sec-WebSocket-Accept verified\n"
        func call(_ text: String) throws {
            transcript += "→ \(text)\n"
            socket.send(text: text)
        }
        func reply() throws -> JSONValue {
            let text = try #require(try socket.receive())
            transcript += "← \(text)\n"
            return try jsonValue(text)
        }
        try call(#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"notch-the-rock","title":"NotchTheRock","version":"1.0.0"},"capabilities":{"experimentalApi":true}}}"#)
        var answer = try reply()
        while answer["id"] == nil { answer = try reply() }
        #expect(answer["result"] != nil)
        try call(#"{"method":"initialized"}"#)
        try call(#"{"id":2,"method":"thread/loaded/list","params":{}}"#)
        answer = try reply()
        while answer["id"] == nil { answer = try reply() }
        #expect(answer["result"]?["data"]?.array != nil)
        if let out = environment["CODEX_PROBE_TRANSCRIPT"] {
            try transcript.write(toFile: out, atomically: true, encoding: .utf8)
        }
    }
}
