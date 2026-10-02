import Foundation
import HookBridge
import NotchKit
import SwiftUI
import Testing
@testable import Agents

@MainActor
@Suite struct NotificationTests {
    let host = FakeHost()
    let activator = FakeActivator()
    let bridge: ClaudeBridge

    init() throws {
        bridge = ClaudeBridge(context: try makeContext(host: host, directory: try makeDirectory()), activator: activator)
    }

    func message(_ event: HookEvent, _ payload: String, terminal: TerminalLocation? = nil) throws -> HookMessage {
        HookMessage(event: event, payload: try json(payload), context: HookContext(terminal: terminal, projectDir: nil))
    }

    func sessionStart() throws {
        let start = try message(.sessionStart, #"{"session_id":"s1","cwd":"/Users/me/notch-the-rock","source":"startup"}"#, terminal: ghostty)
        #expect(bridge.receive(start) == nil)
        #expect(bridge.sessions["s1"]?.terminal == ghostty)
    }

    static let jump = AttentionResponse.answered(AttentionAnswer(buttonID: ClaudeBridge.jumpButtonID))

    @Test func R05__turn_finished_glows_with_the_project_and_jumps_to_its_terminal() async throws {
        try sessionStart()
        host.responses = [Self.jump]
        let stop = try message(.stop, #"{"session_id":"s1","cwd":"/Users/me/notch-the-rock","stop_reason":"end_turn"}"#)
        await bridge.receive(stop)?.value

        let request = try #require(host.requests.last)
        #expect(request.title == "notch-the-rock")
        #expect(request.message == "Claude Code가 작업을 마쳤어요.")
        #expect(request.buttons.map(\.id) == [ClaudeBridge.jumpButtonID])
        #expect(request.buttons.first?.title == "터미널로 이동")
        #expect(activator.activated == [ghostty])
        #expect(host.expansions == 0)
    }

    @Test func R05__waiting_for_input_shows_the_notification_message() async throws {
        try sessionStart()
        host.responses = [Self.jump]
        let waiting = try message(
            .notification,
            #"{"session_id":"s1","cwd":"/Users/me/notch-the-rock","notification_type":"idle_prompt","message":"Claude is waiting for your input"}"#
        )
        await bridge.receive(waiting)?.value

        #expect(host.requests.map(\.title) == ["notch-the-rock"])
        #expect(host.requests.map(\.message) == ["Claude is waiting for your input"])
        #expect(activator.activated == [ghostty])
    }

    @Test func R05__permission_prompts_and_other_notices_do_not_glow() throws {
        for type in ["permission_prompt", "auth_success", "elicitation_complete"] {
            let notice = try message(.notification, #"{"session_id":"s1","cwd":"/tmp/p","notification_type":"\#(type)","message":"m"}"#)
            #expect(bridge.receive(notice) == nil)
        }
        #expect(host.requests.isEmpty)
    }

    @Test func R05__unknown_session_click_just_opens_the_notch() async throws {
        host.responses = [Self.jump]
        await bridge.receive(try message(.stop, #"{"session_id":"elsewhere","cwd":"/Users/me/other"}"#))?.value

        #expect(host.requests.first?.title == "other")
        #expect(activator.activated.isEmpty)
        #expect(host.expansions == 1)
    }

    @Test func R05__a_terminal_that_quit_opens_the_notch_instead() async throws {
        try sessionStart()
        activator.succeeds = false
        host.responses = [Self.jump]
        await bridge.receive(try message(.stop, #"{"session_id":"s1","cwd":"/Users/me/notch-the-rock"}"#))?.value

        #expect(activator.activated == [ghostty])
        #expect(host.expansions == 1)
    }

    @Test func R05__events_after_session_start_also_record_the_terminal() async throws {
        host.responses = [Self.jump]
        let stop = try message(.stop, #"{"session_id":"s2","cwd":"/Users/me/p"}"#, terminal: ghostty)
        await bridge.receive(stop)?.value
        #expect(activator.activated == [ghostty])
    }

    @Test func R05__a_newer_notice_replaces_the_older_one_of_the_same_session() async throws {
        try sessionStart()
        host.waitsForCancellation = true
        // A finished turn's idle reminder adds no alert (R40), so the waiting notice comes first here.
        let first = bridge.receive(try message(
            .notification,
            #"{"session_id":"s1","cwd":"/Users/me/notch-the-rock","notification_type":"idle_prompt","message":"waiting"}"#
        ))
        try await Task.sleep(for: .milliseconds(50))
        let second = bridge.receive(try message(.stop, #"{"session_id":"s1","cwd":"/Users/me/notch-the-rock"}"#))
        await first?.value
        #expect(host.requests.count == 2)
        bridge.cancelAll()
        await second?.value
    }

    @Test func R05__the_plugin_shows_a_notice_from_the_hook_helper() async throws {
        let paths = makeSocketPath()
        defer { try? FileManager.default.removeItem(atPath: paths.folder) }
        let directory = try makeDirectory()
        let plugin = AgentsPlugin(
            context: try makeContext(host: host, directory: directory),
            socketPath: paths.socket,
            settingsURL: directory.appendingPathComponent("settings.json"),
            claudeExecutable: nil,
            activator: activator,
            codexEndpoint: CodexEndpoint(home: directory),
            codexExecutable: nil,
            codexLauncher: FakeLauncher(socketPath: ""),
            codexTerminal: { _ in nil }
        )
        plugin.activate()
        host.responses = [Self.jump]
        let runner = HookRunner(
            socketPath: paths.socket,
            environment: [:],
            readInput: { Data(#"{"session_id":"s9","cwd":"/Users/me/proj","hook_event_name":"Stop"}"#.utf8) },
            findTerminal: { ghostty }
        )
        #expect(await run(runner, ["Stop"]).isEmpty)
        for _ in 0..<200 where activator.activated.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(host.requests.map(\.title) == ["proj"])
        #expect(activator.activated == [ghostty])

        plugin.deactivate()
        #expect(!FileManager.default.fileExists(atPath: paths.socket))
    }

    @Test func R05__render_notification_and_settings() throws {
        try sessionStart()
        let request = bridge.notificationRequest(sessionID: "s1", title: "notch-the-rock", message: "Claude Code가 작업을 마쳤어요.")
        try capture(AttentionPreview(request: request), named: "R05-render-notification")

        let directory = try makeDirectory()
        let settings = directory.appendingPathComponent("settings.json")
        let installer = HookInstaller(
            settingsURL: settings,
            recordURL: directory.appendingPathComponent("record.json"),
            entries: HookEntry.claude(helper: URL(fileURLWithPath: "/Applications/NotchTheRock.app/Contents/PlugIns/Agents.notchplugin/Contents/Helpers/notch-hook"))
        )
        let model = ClaudeHooksModel(installer: installer)
        try capture(settingsPage(model), named: "R05-render-settings-disconnected")
        model.install()
        #expect(model.status == .installed)
        try capture(settingsPage(model), named: "R05-render-settings-connected")
        try Data("{ broken".utf8).write(to: settings)
        model.refresh()
        try capture(settingsPage(model), named: "R05-render-settings-unreadable")
    }

    /// Read only: the settings page shows the default wait.
    let renderDefaults = UserDefaults(suiteName: isolatedDefaultsSuite(in: try! makeDirectory("agents-render")))!

    func settingsPage(_ model: ClaudeHooksModel) -> some View {
        Form { AgentsSettingsView(model: model, codex: CodexModel(defaults: renderDefaults, executable: nil, start: {}, stop: {}), defaults: renderDefaults) }
            .formStyle(.grouped)
            .frame(width: 560, height: 360)
    }
}

/// The request's contents laid out the way the notch shows them (title, message, buttons), for a
/// render outside the app. The app's own attention view is private to the app.
struct AttentionPreview: View {
    let request: AttentionRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                request.sourceIcon?.resizable().scaledToFit().frame(width: 16, height: 16)
                if let timeout = request.timeout {
                    Label("\(Int(timeout.components.seconds))초", systemImage: "timer")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(request.accent)
                }
                Spacer()
                Image(systemName: "xmark")
            }
            Text(request.title).font(.system(size: 14, weight: .semibold))
            if !request.message.isEmpty {
                Text(request.message).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
            }
            ForEach(request.choices, id: \.id) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.prompt).font(.system(size: 12, weight: .medium))
                    ForEach(group.options, id: \.self) { option in
                        Label(option, systemImage: group.allowsMultiple ? "square" : "circle")
                            .font(.system(size: 12))
                    }
                }
            }
            if let field = request.textField {
                Text(field.placeholder)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.1)))
            }
            HStack(spacing: 8) {
                if let release = request.releaseTitle {
                    Text(release).modifier(Pill(fill: .white.opacity(0.12)))
                }
                Spacer()
                ForEach(request.buttons, id: \.id) { button in
                    Text(button.title).modifier(Pill(fill: button.role == .primary ? request.accent : button.role == .destructive ? .red : .white.opacity(0.12)))
                }
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(width: 420)
        .background(RoundedRectangle(cornerRadius: 24).fill(.black))
        .padding(12)
        .background(request.accent.opacity(0.35))
    }

    struct Pill: ViewModifier {
        let fill: Color
        func body(content: Content) -> some View {
            content
                .font(.system(size: 12, weight: .semibold))
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(Capsule().fill(fill))
        }
    }
}
