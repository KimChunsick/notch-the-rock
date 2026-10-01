import Darwin
import Foundation
import HookBridge
import NotchKit
import SwiftUI
import Testing
@testable import Agents

/// Claude Code's input for a Bash permission request (hooks reference, PermissionRequest).
let permissionInput = #"{"session_id":"s1","cwd":"/Users/me/notch-the-rock","permission_mode":"default","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"npm run build"},"tool_use_id":"toolu_01ABC123"}"#

/// Claude Code's input for AskUserQuestion with one single-select and one multi-select question.
let questionInput = #"""
{"session_id":"s1","cwd":"/Users/me/notch-the-rock","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_use_id":"toolu_02","tool_input":{"questions":[{"question":"How should I format the output?","header":"Format","options":[{"label":"Summary","description":"Brief overview"},{"label":"Detailed","description":"Full explanation"}],"multiSelect":false},{"question":"Which sections should I include?","header":"Sections","options":[{"label":"Introduction","description":"Opening"},{"label":"Conclusion","description":"Closing"},{"label":"Appendix","description":"Extra"}],"multiSelect":true}]}}
"""#

/// The plugin listening on a temporary socket, its notch played by a `FakeHost`.
@MainActor
final class LivePlugin {
    let host = FakeHost()
    let plugin: AgentsPlugin
    let paths = makeSocketPath()
    let directory: URL
    let context: NotchContext

    init(wait: Int? = nil) throws {
        directory = try makeDirectory()
        context = try makeContext(host: host, directory: directory)
        if let wait {
            context.storage.defaults.set(wait, forKey: ApprovalWait.defaultsKey)
        }
        plugin = AgentsPlugin(
            context: context,
            socketPath: paths.socket,
            settingsURL: directory.appendingPathComponent("settings.json"),
            activator: FakeActivator()
        )
        plugin.activate()
    }

    func stop() {
        plugin.deactivate()
        context.storage.defaults.removeObject(forKey: ApprovalWait.defaultsKey)
        try? FileManager.default.removeItem(atPath: paths.folder)
    }

    /// Runs the hook for `event` with `input` and returns what it printed.
    func hook(_ event: HookEvent, _ input: String) async -> Data {
        await run(
            HookRunner(socketPath: paths.socket, environment: [:], readInput: { Data(input.utf8) }, findTerminal: { nil }),
            [event.rawValue]
        )
    }
}

func expectJSON(_ output: Data, _ expected: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(jsonObject(output) == jsonObject(Data(expected.utf8)), "printed \(String(decoding: output, as: UTF8.self))", sourceLocation: sourceLocation)
}

@MainActor
@Suite struct ApprovalTests {
    static func answer(_ button: String?, choices: [String: [String]] = [:], text: String? = nil) -> AttentionResponse {
        .answered(AttentionAnswer(buttonID: button, choices: choices, text: text))
    }

    @Test func R06__allow_in_the_notch_prints_the_allow_decision() async throws {
        let live = try LivePlugin()
        defer { live.stop() }
        live.host.responses = [Self.answer(ClaudeBridge.allowButtonID)]

        let output = await live.hook(.permissionRequest, permissionInput)
        expectJSON(output, #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#)
        let request = try #require(live.host.requests.first)
        #expect(request.title == "notch-the-rock · Bash")
        #expect(request.message == "npm run build")
        #expect(request.buttons.map(\.title) == ["거부", "허용"])
        #expect(request.releaseTitle == "터미널에서 답하기")
        #expect(request.timeout == .seconds(120))
    }

    @Test func R06__deny_asks_for_a_message_and_prints_it() async throws {
        let live = try LivePlugin()
        defer { live.stop() }
        live.host.responses = [
            Self.answer(ClaudeBridge.denyButtonID),
            Self.answer(ClaudeBridge.sendDenialButtonID, text: "빌드 말고 테스트만 돌려 주세요"),
        ]

        let output = await live.hook(.permissionRequest, permissionInput)
        expectJSON(output, #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"빌드 말고 테스트만 돌려 주세요"}}}"#)
        #expect(live.host.requests.count == 2)
        #expect(live.host.requests.last?.textField != nil)
        #expect(live.host.requests.last?.releaseTitle == "터미널에서 답하기")
    }

    @Test func R06__deny_without_a_message_still_denies() async throws {
        let live = try LivePlugin()
        defer { live.stop() }
        live.host.responses = [Self.answer(ClaudeBridge.denyButtonID), Self.answer(ClaudeBridge.sendDenialButtonID, text: "  ")]

        let output = await live.hook(.permissionRequest, permissionInput)
        let decision = (jsonObject(output)?["hookSpecificOutput"] as? NSDictionary)?["decision"] as? NSDictionary
        #expect(decision?["behavior"] as? String == "deny")
        #expect((decision?["message"] as? String)?.isEmpty == false)
    }

    @Test func R06__a_picked_option_answers_the_question() async throws {
        let live = try LivePlugin()
        defer { live.stop() }
        live.host.responses = [Self.answer(nil, choices: ["0": ["Summary"], "1": ["Introduction", "Conclusion"]], text: "")]

        let output = await live.hook(.preToolUse, questionInput)
        let questions = try #require((jsonObject(Data(questionInput.utf8))?["tool_input"] as? NSDictionary)?["questions"])
        let expected: NSDictionary = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "updatedInput": [
                    "questions": questions,
                    "answers": [
                        "How should I format the output?": "Summary",
                        "Which sections should I include?": ["Introduction", "Conclusion"],
                    ],
                ],
            ],
        ]
        #expect(jsonObject(output) == expected, "printed \(String(decoding: output, as: UTF8.self))")
        let request = try #require(live.host.requests.first)
        #expect(request.choices.map(\.options) == [["Summary", "Detailed"], ["Introduction", "Conclusion", "Appendix"]])
        #expect(request.choices.map(\.allowsMultiple) == [false, true])
        #expect(request.textField != nil)
        #expect(request.releaseTitle == "터미널에서 답하기")
        #expect(request.timeout == .seconds(120))
    }

    @Test func R06__typed_text_answers_a_question_left_unpicked() async throws {
        let live = try LivePlugin()
        defer { live.stop() }
        live.host.responses = [Self.answer(nil, choices: ["1": ["Appendix"]], text: "표로 정리해 주세요")]

        let output = await live.hook(.preToolUse, questionInput)
        let answers = ((jsonObject(output)?["hookSpecificOutput"] as? NSDictionary)?["updatedInput"] as? NSDictionary)?["answers"] as? NSDictionary
        #expect(answers == [
            "How should I format the output?": "표로 정리해 주세요",
            "Which sections should I include?": ["Appendix"],
        ] as NSDictionary)
    }

    @Test func R06__an_unanswered_question_is_left_to_the_terminal() async throws {
        let live = try LivePlugin()
        defer { live.stop() }
        live.host.responses = [Self.answer(nil, choices: ["0": ["Summary"]], text: "")]
        #expect(await live.hook(.preToolUse, questionInput).isEmpty)
    }

    @Test(arguments: [AttentionResponse.released, .timedOut, .dismissed])
    func R06__release_timeout_and_close_print_nothing(_ response: AttentionResponse) async throws {
        let live = try LivePlugin()
        defer { live.stop() }
        live.host.responses = [response, response]
        #expect(await live.hook(.permissionRequest, permissionInput).isEmpty)
        #expect(await live.hook(.preToolUse, questionInput).isEmpty)
        #expect(live.host.requests.count == 2)
    }

    @Test func R06__other_tools_before_use_are_not_asked() async throws {
        let live = try LivePlugin()
        defer { live.stop() }
        let bash = #"{"session_id":"s1","cwd":"/tmp/p","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}"#
        #expect(await live.hook(.preToolUse, bash).isEmpty)
        #expect(live.host.requests.isEmpty)
    }

    @Test func R06__the_wait_follows_the_setting() async throws {
        let live = try LivePlugin(wait: 300)
        defer { live.stop() }
        live.host.responses = [.released]
        _ = await live.hook(.permissionRequest, permissionInput)
        #expect(live.host.requests.first?.timeout == .seconds(300))
    }

    @Test func R06__a_closed_hook_withdraws_its_request() async throws {
        let live = try LivePlugin()
        defer { live.stop() }
        live.host.waitsForCancellation = true
        let process = Process()
        process.executableURL = builtHook
        process.arguments = ["PermissionRequest"]
        process.environment = [HookSocket.pathEnvironmentKey: live.paths.socket]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = Pipe()
        try process.run()
        stdin.fileHandleForWriting.write(Data(permissionInput.utf8))
        try stdin.fileHandleForWriting.close()
        for _ in 0..<300 where live.host.requests.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(live.host.requests.count == 1)

        // Claude Code kills the hook when the user answers in the terminal.
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        for _ in 0..<300 where live.host.cancellations == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(live.host.cancellations == 1)
    }

    @Test func R06__another_user_cannot_ask() async throws {
        let server = try TestServer(peerUID: { _ in getuid() + 1 })
        defer { server.stop() }
        let runner = HookRunner(socketPath: server.path, environment: [:], readInput: { Data(permissionInput.utf8) }, findTerminal: { nil })
        #expect(await run(runner, ["PermissionRequest"]).isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.inbox.all.isEmpty)
    }

    @Test(arguments: [HookEvent.permissionRequest, .preToolUse])
    func R06__offline_hook_answers_nothing_at_once(_ event: HookEvent) throws {
        let paths = makeSocketPath()
        let result = try runProcess(
            builtHook, [event.rawValue],
            input: Data((event == .preToolUse ? questionInput : permissionInput).utf8),
            environment: [HookSocket.pathEnvironmentKey: paths.socket]
        )
        print("R06 offline notch-hook \(event.rawValue): exit \(result.status), \(result.stdout.count) bytes on stdout, \(result.elapsed)")
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.elapsed < .seconds(1))
    }

    @Test func R06__installed_hooks_outwait_the_notch() {
        let entries = HookEntry.claude(helper: URL(fileURLWithPath: "/Applications/NotchTheRock.app/Contents/PlugIns/Agents.notchplugin/Contents/Helpers/notch-hook"))
        let question = entries.first { $0.event == "PreToolUse" }
        let permission = entries.first { $0.event == "PermissionRequest" }
        #expect(question?.matcher == "AskUserQuestion")
        #expect(permission?.matcher == nil)
        let longest = ApprovalWait.choices.max() ?? 0
        #expect((question?.timeout ?? 0) > longest)
        #expect((permission?.timeout ?? 0) > longest)
    }

    @Test func R06__render_permission_and_question() async throws {
        let live = try LivePlugin()
        defer { live.stop() }
        live.host.responses = [Self.answer(ClaudeBridge.denyButtonID), .released, .released]
        _ = await live.hook(.permissionRequest, permissionInput)
        _ = await live.hook(.preToolUse, questionInput)
        let requests = live.host.requests
        #expect(requests.count == 3)
        try capture(AttentionPreview(request: requests[0]), named: "R06-render-permission")
        try capture(AttentionPreview(request: requests[1]), named: "R06-render-deny-message")
        try capture(AttentionPreview(request: requests[2]), named: "R06-render-question")
    }
}
