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

/// Claude Code's input for AskUserQuestion with a single question.
let singleQuestionInput = #"""
{"session_id":"s1","cwd":"/Users/me/notch-the-rock","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_use_id":"toolu_03","tool_input":{"questions":[{"question":"How should I format the output?","header":"Format","options":[{"label":"Summary","description":"Brief overview"},{"label":"Detailed","description":"Full explanation"}],"multiSelect":false}]}}
"""#

/// Claude Code's input for AskUserQuestion with four questions, the most it asks at once.
let fourQuestionInput = #"""
{"session_id":"s1","cwd":"/Users/me/notch-the-rock","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_use_id":"toolu_04","tool_input":{"questions":[
{"question":"Which framework should I use?","header":"Framework","options":[{"label":"SwiftUI","description":"Declarative"},{"label":"AppKit","description":"Imperative"}],"multiSelect":false},
{"question":"Which platforms should it run on?","header":"Platforms","options":[{"label":"macOS","description":"Mac"},{"label":"iOS","description":"Phone"}],"multiSelect":true},
{"question":"Which test library should I use?","header":"Tests","options":[{"label":"swift-testing","description":"New"},{"label":"XCTest","description":"Old"}],"multiSelect":false},
{"question":"How should I ship it?","header":"Ship","options":[{"label":"Notarized","description":"Signed"},{"label":"Unsigned","description":"Local"}],"multiSelect":false}]}}
"""#

/// Claude Code's PostToolUse for the four-question call above.
let fourQuestionsEnded = #"{"session_id":"s1","cwd":"/Users/me/notch-the-rock","hook_event_name":"PostToolUse","tool_name":"AskUserQuestion","tool_use_id":"toolu_04","tool_input":{},"tool_response":{}}"#

/// A PermissionRequest for `tool` with `toolInput`, as Claude Code sends it.
func permissionInput(tool: String, _ toolInput: [String: Any]) -> String {
    let object: [String: Any] = [
        "session_id": "s1", "cwd": "/Users/me/notch-the-rock", "hook_event_name": "PermissionRequest",
        "tool_name": tool, "tool_input": toolInput, "tool_use_id": "toolu_09",
    ]
    return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

let allowOutput = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#

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
            claudeExecutable: nil,
            activator: FakeActivator(),
            codexEndpoint: CodexEndpoint(home: directory),
            codexExecutable: nil,
            codexLauncher: FakeLauncher(socketPath: ""),
            codexTerminal: { _ in nil }
        )
        plugin.activate()
    }

    func stop() {
        plugin.deactivate()
        context.storage.defaults.removeObject(forKey: ApprovalWait.defaultsKey)
        try? FileManager.default.removeItem(atPath: paths.folder)
    }

    /// The request the Agents screen shows, once the plugin has put it there.
    func screenItem() async throws -> ScreenItem {
        for _ in 0..<300 where plugin.bridge.screen.items.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(plugin.bridge.screen.items.first)
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
    static func answer(_ button: String?, choices: [String: [String]] = [:], text: String? = nil, texts: [String: String] = [:]) -> AttentionResponse {
        .answered(AttentionAnswer(buttonID: button, choices: choices, text: text, texts: texts))
    }

    static let claudeSession = AgentSession.Key(agent: .claude, id: "s1")
    /// The four questions' picks on the card, by question index.
    static let fourPicks: [String: [String]] = ["0": ["SwiftUI"], "1": ["macOS", "iOS"], "2": ["swift-testing"], "3": ["Notarized"]]
    static let fourAnswers: NSDictionary = [
        "Which framework should I use?": "SwiftUI",
        "Which platforms should it run on?": ["macOS", "iOS"],
        "Which test library should I use?": "swift-testing",
        "How should I ship it?": "Notarized",
    ]

    static func state(_ live: LivePlugin) -> AgentSessionState? {
        live.plugin.bridge.screen.sessions[claudeSession]?.state
    }

    /// Waits up to three seconds until `condition` holds.
    static func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Runs the PostToolUse of the four-question call and waits until the plugin has taken it.
    static func endFourQuestionCall(_ live: LivePlugin) async throws {
        let before = try #require(live.plugin.bridge.screen.sessions[claudeSession]?.changed)
        _ = await live.hook(.postToolUse, fourQuestionsEnded)
        try await eventually { (live.plugin.bridge.screen.sessions[claudeSession]?.changed ?? before) > before }
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
        live.host.responses = [Self.answer(ClaudeBridge.sendAnswersButtonID, choices: ["0": ["Summary"], "1": ["Introduction", "Conclusion"]])]

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
        // One text field cannot answer several questions: each gets its own on the card.
        #expect(request.textField == nil)
        #expect(request.buttons.map(\.title) == ["보내기"])
        #expect(request.releaseTitle == "터미널에서 답하기")
        #expect(request.timeout == .seconds(120))
    }

    @Test func R06__typed_text_answers_a_single_question_in_the_notch() async throws {
        let live = try LivePlugin()
        defer { live.stop() }
        live.host.responses = [Self.answer(nil, text: "표로 정리해 주세요")]

        let output = await live.hook(.preToolUse, singleQuestionInput)
        let answers = ((jsonObject(output)?["hookSpecificOutput"] as? NSDictionary)?["updatedInput"] as? NSDictionary)?["answers"] as? NSDictionary
        #expect(answers == ["How should I format the output?": "표로 정리해 주세요"] as NSDictionary)
        #expect(live.host.requests.first?.textField != nil)
        #expect(live.host.requests.first?.buttons.isEmpty == true)
    }

    @Test func R06__a_typed_answer_replaces_the_option_carried_over_from_the_notch() throws {
        let questions = try #require(Question.parse(try jsonValue(questionInput)["tool_input"]))
        // The screen's form (Codex still opens it), as it opens with a pick from the notch, filled in
        // field by field.
        var draft = AnswerDraft(questions, picked: [1: ["Appendix"]])
        draft.type("표로 정리해 주세요", at: 0)
        draft.type("부록은 빼 주세요", at: 1)
        #expect(!draft.isPicked("Appendix", at: 1))
        #expect(draft.answers == [
            "How should I format the output?": .string("표로 정리해 주세요"),
            "Which sections should I include?": .string("부록은 빼 주세요"),
        ])
    }

    @Test func R06__an_unanswered_question_goes_to_the_terminal_with_a_notice_naming_it() async throws {
        let live = try LivePlugin()
        defer { live.stop() }
        live.host.responses = [Self.answer(ClaudeBridge.sendAnswersButtonID, choices: ["0": ["Summary"]])]

        #expect(await live.hook(.preToolUse, questionInput).isEmpty)
        // No form on the Agents screen: the terminal asks, and a notice names the question left open.
        #expect(live.host.expansions == 0)
        #expect(live.plugin.bridge.screen.items.isEmpty)
        try await Self.eventually { live.host.requests.count == 2 }
        #expect(live.host.requests.count == 2)
        #expect(live.host.requests.last?.message == "2번 질문에 아직 답하지 않았어요. 터미널에서 이어서 답해 주세요.")
    }

    @Test func R61__four_answers_sent_from_the_card_reach_claude_and_the_session_works_again() async throws {
        let live = try LivePlugin()
        defer { live.stop() }
        live.host.responses = [Self.answer(ClaudeBridge.sendAnswersButtonID, choices: Self.fourPicks)]

        let output = await live.hook(.preToolUse, fourQuestionInput)
        let input = try #require(jsonObject(Data(fourQuestionInput.utf8))?["tool_input"] as? NSDictionary)
        let hook = try #require(jsonObject(output)?["hookSpecificOutput"] as? NSDictionary, "printed \(String(decoding: output, as: UTF8.self))")
        #expect(hook["hookEventName"] as? String == "PreToolUse")
        #expect(hook["permissionDecision"] as? String == "allow")
        let updated = try #require(hook["updatedInput"] as? NSDictionary)
        #expect(updated["questions"] as? NSArray == input["questions"] as? NSArray)
        #expect(updated["answers"] as? NSDictionary == Self.fourAnswers)
        #expect(live.host.requests.first?.choices.count == 4)
        // Answered: the row works at once, and nothing of the request is left in the notch or on the
        // screen.
        #expect(Self.state(live) == .working)
        #expect(live.host.requests.count == 1)
        #expect(live.plugin.bridge.screen.items.isEmpty)
        #expect(live.plugin.bridge.sessions["s1"]?.waits.isEmpty == true)
        // The call's own end comes later and changes nothing.
        try await Self.endFourQuestionCall(live)
        #expect(Self.state(live) == .working)
        #expect(live.host.requests.count == 1)
    }

    @Test func R61__three_of_four_answers_sent_from_the_card_go_to_the_terminal_with_a_notice_naming_the_fourth() async throws {
        let live = try LivePlugin()
        defer { live.stop() }
        var three = Self.fourPicks
        three["3"] = nil
        live.host.responses = [Self.answer(ClaudeBridge.sendAnswersButtonID, choices: three)]

        // The installed hook helper itself, run as Claude Code runs it, on its own thread.
        let input = Data(fourQuestionInput.utf8)
        let socket = live.paths.socket
        let ran: ProcessResult? = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: try? runProcess(builtHook, [HookEvent.preToolUse.rawValue], input: input, environment: [HookSocket.pathEnvironmentKey: socket]))
            }
        }
        let hook = try #require(ran)
        // Released at once: nothing printed, exit 0, so the terminal asks the question itself.
        #expect(hook.status == 0)
        #expect(hook.stdout.isEmpty, "printed \(String(decoding: hook.stdout, as: UTF8.self))")
        // No form on the Agents screen waits for the fourth answer.
        #expect(live.host.expansions == 0)
        #expect(live.plugin.bridge.screen.items.isEmpty)
        try await Self.eventually { live.host.requests.count == 2 }
        let notice = try #require(live.host.requests.last)
        #expect(live.host.requests.count == 2)
        #expect(notice.title == "notch-the-rock")
        #expect(notice.message == "4번 질문에 아직 답하지 않았어요. 터미널에서 이어서 답해 주세요.")
        #expect(notice.buttons.map(\.id) == [ClaudeBridge.jumpButtonID])
        // The terminal asks now: the row waits until the call ends.
        #expect(Self.state(live) == .awaitingAnswer)
        try await Self.endFourQuestionCall(live)
        #expect(Self.state(live) == .working)
    }

    @Test func R62__four_questions_step_on_one_card_and_a_typed_answer_reaches_claude() async throws {
        let live = try LivePlugin()
        defer { live.stop() }
        var three = Self.fourPicks
        three["3"] = nil
        live.host.responses = [Self.answer(ClaudeBridge.sendAnswersButtonID, choices: three, texts: ["3": " 직접 배포할게요 "])]

        let output = await live.hook(.preToolUse, fourQuestionInput)
        // One card that steps through the four questions, each with its own field, sent from the last.
        let request = try #require(live.host.requests.first)
        #expect(live.host.requests.count == 1)
        #expect(request.choices.map(\.id) == ["0", "1", "2", "3"])
        #expect(request.choices.map(\.textField) == Array(repeating: AttentionTextField(placeholder: "직접 입력"), count: 4))
        #expect(request.textField == nil)
        #expect(request.buttons.map(\.id) == [ClaudeBridge.sendAnswersButtonID])
        #expect(request.buttons.map(\.title) == ["보내기"])
        #expect(request.releaseTitle == "터미널에서 답하기")
        let answers = ((jsonObject(output)?["hookSpecificOutput"] as? NSDictionary)?["updatedInput"] as? NSDictionary)?["answers"] as? NSDictionary
        #expect(answers == [
            "Which framework should I use?": "SwiftUI",
            "Which platforms should it run on?": ["macOS", "iOS"],
            "Which test library should I use?": "swift-testing",
            "How should I ship it?": "직접 배포할게요",
        ] as NSDictionary, "printed \(String(decoding: output, as: UTF8.self))")
        #expect(live.plugin.bridge.screen.items.isEmpty)
        #expect(Self.state(live) == .working)
    }

    @Test func R62__a_question_with_both_a_pick_and_typed_text_sends_the_pick_as_the_screen_form_does() async throws {
        let live = try LivePlugin()
        defer { live.stop() }
        live.host.responses = [Self.answer(ClaudeBridge.sendAnswersButtonID, choices: Self.fourPicks, texts: ["0": "UIKit도 같이요"])]

        let output = await live.hook(.preToolUse, fourQuestionInput)
        let answers = ((jsonObject(output)?["hookSpecificOutput"] as? NSDictionary)?["updatedInput"] as? NSDictionary)?["answers"] as? NSDictionary
        #expect(answers == Self.fourAnswers, "printed \(String(decoding: output, as: UTF8.self))")
        // The same pair on the Agents screen's form gives the same answer.
        let questions = try #require(Question.parse(try jsonValue(fourQuestionInput)["tool_input"]))
        #expect(Question.answers(questions, picked: [0: ["SwiftUI"], 1: ["macOS", "iOS"], 2: ["swift-testing"], 3: ["Notarized"]], typed: [0: "UIKit도 같이요"])?["Which framework should I use?"] == .string("SwiftUI"))
    }

    @Test func R62__a_single_question_keeps_its_one_field_and_a_pick_sends_at_once() async throws {
        let live = try LivePlugin()
        defer { live.stop() }
        live.host.responses = [Self.answer(nil, choices: ["0": ["Detailed"]])]

        let output = await live.hook(.preToolUse, singleQuestionInput)
        let request = try #require(live.host.requests.first)
        #expect(request.choices.map(\.textField) == [nil])
        #expect(request.textField == AttentionTextField(placeholder: "직접 입력해서 답해요"))
        #expect(request.buttons.isEmpty)
        let answers = ((jsonObject(output)?["hookSpecificOutput"] as? NSDictionary)?["updatedInput"] as? NSDictionary)?["answers"] as? NSDictionary
        #expect(answers == ["How should I format the output?": "Detailed"] as NSDictionary)
    }

    @Test func R06__typed_answers_never_copy_one_value_into_every_question() {
        let questions = [
            Question(text: "A?", options: ["x"], multiple: false),
            Question(text: "B?", options: ["y", "z"], multiple: true),
        ]
        #expect(Question.answers(questions, picked: [:], typed: [0: "하나"]) == nil)
        #expect(Question.answers(questions, picked: [1: ["y", "z"]], typed: [0: " 하나 "]) == ["A?": .string("하나"), "B?": .array([.string("y"), .string("z")])])
    }

    @Test func R06__picking_an_option_clears_the_text_typed_for_that_question() {
        let questions = [
            Question(text: "A?", options: ["x"], multiple: false),
            Question(text: "B?", options: ["y", "z"], multiple: true),
        ]
        var draft = AnswerDraft(questions, picked: [:])
        draft.type("하나", at: 0)
        draft.type("둘", at: 1)
        draft.pick("x", at: 0)
        #expect(draft.typed[0] == nil)
        #expect(draft.typed[1] == "둘")
        #expect(draft.answers == ["A?": .string("x"), "B?": .string("둘")])
        draft.type("셋", at: 0)
        #expect(!draft.isPicked("x", at: 0))
        #expect(draft.answers == ["A?": .string("셋"), "B?": .string("둘")])
    }

    // MARK: The screen inside the expanded notch

    /// What a host offers a plugin screen: the most (main's NotchSizing.maxContentSize) and less.
    nonisolated static let offers = [CGSize(width: 390, height: 400), CGSize(width: 390, height: 210)]

    @Test(arguments: offers)
    func R06__the_screen_keeps_its_title_and_controls_inside_the_offered_size(_ offer: CGSize) async throws {
        let live = try LivePlugin()
        defer { live.stop() }
        let content = (1...80).map { "line \($0): " + String(repeating: "내용", count: 20) }.joined(separator: "\n")
        live.host.responses = [Self.answer(ClaudeBridge.detailsButtonID)]
        let screen = AgentsScreen(model: live.plugin.bridge.screen)
        let size = "\(Int(offer.width))x\(Int(offer.height))"

        let permission = Task { await live.hook(.permissionRequest, permissionInput(tool: "Write", ["file_path": "/Users/me/p/a.txt", "content": content])) }
        let item = try await live.screenItem()
        // Measured without a limit the screen asks for all of its content, so a host that sizes
        // the notch to its content offers it the most it can.
        #expect(NSHostingView(rootView: screen).fittingSize.height > offer.height)
        let detail = layOut(screen, in: offer)
        try capture(detail, named: "R06-render-detail-\(size)-T69")
        expectInside(detail, screen, offer, fields: 1)
        live.plugin.bridge.screen.respond(to: item.id, with: .released)
        #expect(await permission.value.isEmpty)

        // The question form, as Codex opens it with a pick from the notch.
        let parsed = try #require(Question.parse(try jsonValue(questionInput)["tool_input"]))
        let questions = Task {
            await live.plugin.bridge.screen.show(
                title: "notch-the-rock · Claude의 질문", content: .questions(parsed, picked: [1: ["Appendix"]]),
                accent: ClaudeBridge.accent, takesDenyReason: true, until: .now + .seconds(120)
            )
        }
        let form = try await live.screenItem()
        let formView = layOut(screen, in: offer)
        try capture(formView, named: "R06-render-questions-\(size)-T69")
        expectInside(formView, screen, offer, fields: 0)
        live.plugin.bridge.screen.respond(to: form.id, with: .released)
        #expect(await questions.value == .released)
    }

    /// `root` shows `screen` laid out in `offer`: `fields` text fields stay in view beside one
    /// scrolling body, all inside the bounds, and the screen's whole stack (title, body, fields and
    /// the buttons, which SwiftUI draws without an AppKit view to look for) fits the offer from the
    /// top, so nothing of it falls outside.
    func expectInside(_ root: NSView, _ screen: AgentsScreen, _ offer: CGSize, fields: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        let needed = NSHostingController(rootView: screen).sizeThatFits(in: offer)
        #expect(needed.width <= offer.width && needed.height <= offer.height, "the screen needs \(needed) in \(offer)", sourceLocation: sourceLocation)
        let (controls, scrollViews) = pinnedControls(in: root)
        #expect(controls.filter { $0.control is NSTextField }.count == fields, sourceLocation: sourceLocation)
        for (control, frame) in controls {
            #expect(root.bounds.contains(frame), "\(type(of: control)) at \(frame) is outside \(root.bounds)", sourceLocation: sourceLocation)
        }
        #expect(scrollViews.count == 1, sourceLocation: sourceLocation)
        for frame in scrollViews {
            #expect(root.bounds.contains(frame), "body at \(frame) is outside \(root.bounds)", sourceLocation: sourceLocation)
            #expect(frame.height >= AgentsScreen.minimumBodyHeight, sourceLocation: sourceLocation)
        }
    }

    // MARK: Operations the notch cannot show in full

    @Test func R06__a_long_command_is_allowed_only_from_the_full_detail() async throws {
        let live = try LivePlugin()
        defer { live.stop() }
        let command = "echo ok && " + String(repeating: "x", count: 467) + " && rm -rf ~/Documents"
        #expect(command.count == 500)
        live.host.responses = [Self.answer(ClaudeBridge.detailsButtonID)]

        let output = Task { await live.hook(.permissionRequest, permissionInput(tool: "Bash", ["command": command, "description": "Clean up"])) }
        let item = try await live.screenItem()
        let request = try #require(live.host.requests.first)
        #expect(!request.buttons.contains { $0.id == ClaudeBridge.allowButtonID })
        #expect(request.buttons.map(\.title) == ["거부", "자세히 보기"])
        #expect(request.releaseTitle == "터미널에서 답하기")
        #expect(live.host.expansions == 1)
        guard case .permission(let detail) = item.content else {
            Issue.record("not a permission: \(item.content)")
            return
        }
        #expect(detail.sections.first == OperationDetail.Section(label: "명령", body: command))
        try capture(AttentionPreview(request: request), named: "R06-render-permission-long-T68")

        live.plugin.bridge.screen.respond(to: item.id, with: .allow)
        expectJSON(await output.value, allowOutput)
    }

    @Test func R06__a_file_write_shows_its_whole_content_before_it_is_decided() async throws {
        let live = try LivePlugin()
        defer { live.stop() }
        let content = (1...80).map { "line \($0): " + String(repeating: "내용", count: 20) }.joined(separator: "\n")
        live.host.responses = [Self.answer(ClaudeBridge.detailsButtonID)]

        let output = Task { await live.hook(.permissionRequest, permissionInput(tool: "Write", ["file_path": "/Users/me/p/a.txt", "content": content])) }
        let item = try await live.screenItem()
        let request = try #require(live.host.requests.first)
        #expect(!request.buttons.contains { $0.id == ClaudeBridge.allowButtonID })
        guard case .permission(let detail) = item.content else {
            Issue.record("not a permission: \(item.content)")
            return
        }
        #expect(detail.sections == [
            OperationDetail.Section(label: "파일", body: "/Users/me/p/a.txt"),
            OperationDetail.Section(label: "새 내용", body: content),
        ])

        // Claude Code's denial carries the typed reason, and the item keeps Claude's colour.
        #expect(item.takesDenyReason)
        #expect(item.accent == ClaudeBridge.accent)
        live.plugin.bridge.screen.respond(to: item.id, with: .deny(reason: "이 파일은 그대로 두세요"))
        expectJSON(await output.value, #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"이 파일은 그대로 두세요"}}}"#)
    }

    @Test func R06__only_a_short_plain_command_fits_the_notch() {
        #expect(OperationDetail(tool: "Bash", input: .object(["command": .string("npm run build"), "description": .string("Build"), "timeout": .number(60000)])).notchText == "npm run build")
        #expect(OperationDetail(tool: "Bash", input: .object(["command": .string(String(repeating: "a", count: 161))])).notchText == nil)
        #expect(OperationDetail(tool: "Bash", input: .object(["command": .string("a\nb\nc\nd")])).notchText == nil)
        let unsandboxed = OperationDetail(tool: "Bash", input: .object(["command": .string("ls"), "dangerouslyDisableSandbox": .bool(true)]))
        #expect(unsandboxed.notchText == nil)
        #expect(unsandboxed.sections.last?.body.contains("dangerouslyDisableSandbox") == true)
        let edit = OperationDetail(tool: "Edit", input: .object(["file_path": .string("/p/a.swift"), "old_string": .string("let a = 1"), "new_string": .string("let a = 2")]))
        #expect(edit.notchText == nil)
        #expect(edit.sections.map(\.body) == ["/p/a.swift", "let a = 1", "let a = 2"])
        let unknown = OperationDetail(tool: "mcp__db__query", input: .object(["sql": .string("DROP TABLE users"), "db": .string("prod")]))
        #expect(unknown.notchText == nil)
        #expect(unknown.sections.count == 1)
        #expect(unknown.sections[0].body.contains("DROP TABLE users") && unknown.sections[0].body.contains("prod"))
    }

    @Test func R06__a_closed_hook_takes_its_request_off_the_screen() async throws {
        let live = try LivePlugin()
        defer { live.stop() }
        live.host.responses = [Self.answer(ClaudeBridge.detailsButtonID)]
        let process = Process()
        process.executableURL = builtHook
        process.arguments = ["PermissionRequest"]
        process.environment = [HookSocket.pathEnvironmentKey: live.paths.socket]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = Pipe()
        try process.run()
        stdin.fileHandleForWriting.write(Data(permissionInput(tool: "Write", ["file_path": "/p/a.txt", "content": "x"]).utf8))
        try stdin.fileHandleForWriting.close()
        _ = try await live.screenItem()

        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        for _ in 0..<300 where !live.plugin.bridge.screen.items.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(live.plugin.bridge.screen.items.isEmpty)
    }

    @Test(arguments: [AttentionResponse.released, .timedOut, .dismissed])
    func R06__release_timeout_and_close_print_nothing(_ response: AttentionResponse) async throws {
        let live = try LivePlugin()
        defer { live.stop() }
        live.host.responses = [response, response]
        #expect(await live.hook(.permissionRequest, permissionInput).isEmpty)
        #expect(await live.hook(.preToolUse, questionInput).isEmpty)
        // A question whose wait ran out says it went to the terminal; one released or closed went
        // there by the user's choice.
        let notices = response == .timedOut ? 1 : 0
        try await Self.eventually { live.host.requests.count >= 2 + notices }
        #expect(live.host.requests.count == 2 + notices)
        if notices == 1 {
            #expect(live.host.requests.last?.message == "답을 다 받지 못해서 터미널에서 이어서 답해 주세요.")
        }
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

    /// The wait the plugin's own picker stored as a number stays once the page declares it as a
    /// choice, and a change on the page applies to the next request.
    @Test func R48__the_declared_wait_keeps_the_stored_value_and_a_change_applies_to_the_next_request() async throws {
        let live = try LivePlugin(wait: 300)
        defer { live.stop() }
        #expect(live.plugin.pluginDescription?.settings == [ApprovalWait.item])
        #expect(live.context.settings.string(ApprovalWait.item) == "300")
        live.context.settings.set("30", for: ApprovalWait.item)
        live.host.responses = [.released]
        _ = await live.hook(.permissionRequest, permissionInput)
        #expect(live.host.requests.first?.timeout == .seconds(30))
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
        try capture(AttentionPreview(request: requests[0]), named: "R06-render-permission-short-T68")
        try capture(AttentionPreview(request: requests[1]), named: "R06-render-deny-message")
        try capture(AttentionPreview(request: requests[2]), named: "R06-render-question")
    }
}
