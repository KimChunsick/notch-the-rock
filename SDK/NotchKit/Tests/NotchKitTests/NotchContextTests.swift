import Foundation
import SwiftUI
import Testing
@testable import NotchKit

/// Records every host call so the tests can check what `NotchContext` forwards.
@MainActor
final class RecordingHost: NotchHost {
    var calls: [String] = []
    var attentionReply: AttentionResponse = .dismissed
    var lastAttention: AttentionRequest?
    var trusted = false

    func post(_ activity: LiveActivity, from pluginID: String) {
        calls.append("post \(activity.id) p\(activity.priority) \(pluginID)")
    }
    func clearActivity(id: String, from pluginID: String) {
        calls.append("clear \(id) \(pluginID)")
    }
    func showHUD(_ hud: HUD, duration: Duration, from pluginID: String) {
        calls.append("hud \(hud.title) \(duration) \(pluginID)")
    }
    func present(_ takeover: Takeover, from pluginID: String) {
        calls.append("takeover \(takeover.duration) \(pluginID)")
    }
    func requestAttention(_ request: AttentionRequest, from pluginID: String) async -> AttentionResponse {
        calls.append("attention \(request.title) \(pluginID)")
        lastAttention = request
        return attentionReply
    }
    func expand(toTabOf pluginID: String) {
        calls.append("expand \(pluginID)")
    }
    func collapse(from pluginID: String) {
        calls.append("collapse \(pluginID)")
    }
    var isAccessibilityTrusted: Bool { trusted }
    func requestAccessibility(from pluginID: String) {
        calls.append("requestAccessibility \(pluginID)")
    }
    func log(_ level: LogLevel, _ message: String, from pluginID: String) {
        calls.append("log \(level) \(message) \(pluginID)")
    }
}

@MainActor
final class SamplePlugin: NotchPlugin {
    static let manifest = PluginManifest(
        id: "com.example.sample",
        name: "Sample",
        version: "1.0.0",
        symbol: "sparkles",
        sdkVersion: NotchKitSDK.version
    )
    let context: NotchContext
    init(context: NotchContext) { self.context = context }
    func activate() {}
    func deactivate() {}
}

@MainActor
func makeContext(_ host: RecordingHost, id: String = "com.example.sample") throws -> NotchContext {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("NotchKitTests-\(UUID().uuidString)")
        .appendingPathComponent(id)
    let storage = try PluginStorage(
        directory: directory,
        defaultsSuiteName: "NotchKitTests.\(id)",
        keychainService: "NotchKitTests.\(id)"
    )
    return NotchContext(pluginID: id, bundleURL: directory.deletingLastPathComponent().appendingPathComponent("Sample.notchplugin"), host: host, storage: storage)
}

@MainActor
@Suite struct NotchContextTests {
    @Test func R03__context_forwards_presentations_with_plugin_id() throws {
        let host = RecordingHost()
        let context = try makeContext(host)
        context.post(LiveActivity(id: "now", priority: 5, leading: { Text("L") }, trailing: { Text("R") }))
        context.clear(activityID: "now")
        context.showHUD(HUD(symbol: "battery.100", title: "배터리", value: 0.8), duration: .seconds(2))
        context.present(Takeover(duration: .seconds(3)) { Text("hello") })
        context.expand()
        context.collapse()
        context.log.info("ready")
        #expect(host.calls == [
            "post now p5 com.example.sample",
            "clear now com.example.sample",
            "hud 배터리 2.0 seconds com.example.sample",
            "takeover 3.0 seconds com.example.sample",
            "expand com.example.sample",
            "collapse com.example.sample",
            "log info ready com.example.sample",
        ])
    }

    @Test func R03__context_forwards_permissions() throws {
        let host = RecordingHost()
        let context = try makeContext(host)
        #expect(context.permissions.isAccessibilityTrusted == false)
        host.trusted = true
        #expect(context.permissions.isAccessibilityTrusted == true)
        context.permissions.requestAccessibility()
        #expect(host.calls == ["requestAccessibility com.example.sample"])
    }

    @Test func R03__attention_request_round_trips_through_host() async throws {
        let host = RecordingHost()
        let context = try makeContext(host)
        let answer = AttentionAnswer(buttonID: "allow", choices: ["q1": ["A", "C"]], text: "메모")
        host.attentionReply = .answered(answer)
        let request = AttentionRequest(
            title: "권한 요청",
            message: "Bash 명령을 실행할까요?",
            accent: .orange,
            buttons: [
                AttentionButton(id: "allow", title: "허용", role: .primary),
                AttentionButton(id: "deny", title: "거부", role: .destructive),
            ],
            choices: [AttentionChoices(id: "q1", prompt: "고르세요", options: ["A", "B", "C"], allowsMultiple: true)],
            textField: AttentionTextField(placeholder: "거부 이유"),
            releaseTitle: "터미널에서 답하기",
            timeout: .seconds(120)
        )
        let response = await context.requestAttention(request)
        #expect(response == .answered(answer))
        #expect(host.calls == ["attention 권한 요청 com.example.sample"])
        #expect(host.lastAttention?.choices.first?.allowsMultiple == true)
        #expect(host.lastAttention?.releaseTitle == "터미널에서 답하기")

        host.attentionReply = .released
        #expect(await context.requestAttention(request) == .released)
        host.attentionReply = .timedOut
        #expect(await context.requestAttention(request) == .timedOut)
    }

    @Test func R03__storage_creates_private_plugin_directory() throws {
        let host = RecordingHost()
        let context = try makeContext(host)
        let attributes = try FileManager.default.attributesOfItem(atPath: context.storage.directory.path)
        #expect(attributes[.type] as? FileAttributeType == .typeDirectory)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(context.storage.directory.lastPathComponent == "com.example.sample")
    }

    @Test func R03__entry_export_round_trips_plugin_type() throws {
        let raw = NotchPluginEntry.export(SamplePlugin.self)
        let object = Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue()
        let entry = try #require(object as? NotchPluginEntry)
        #expect(ObjectIdentifier(entry.pluginType) == ObjectIdentifier(SamplePlugin.self))
        #expect(entry.pluginType.manifest.id == "com.example.sample")
        let plugin = entry.pluginType.init(context: try makeContext(RecordingHost()))
        #expect(plugin.expandedTab == nil)
        #expect(plugin.settingsView == nil)
    }
}
