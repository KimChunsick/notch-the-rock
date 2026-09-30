import NotchKit
import SwiftUI
import Testing
@testable import NotchTheRock

/// Turning a plugin off withdraws everything it shows from the notch and nothing another plugin shows.
@MainActor
struct NotchHostWithdrawTests {
    let clock = ManualClock()
    let host: NotchHostModel
    let a = "com.example.a"
    let b = "com.example.b"

    init() {
        let clock = clock
        host = NotchHostModel(now: { clock.now })
    }

    func activity(_ id: String, priority: Int = 0) -> LiveActivity {
        LiveActivity(id: id, priority: priority, leading: { Text(id) }, trailing: { EmptyView() })
    }

    func hud(_ title: String) -> HUD {
        HUD(symbol: "speaker.wave.2", title: title)
    }

    /// Lets tasks started on the main actor run until `condition` holds.
    func settle(until condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
    }

    @Test func R03__withdraw_removes_only_that_plugins_items() async throws {
        host.post(activity("a", priority: 10), from: a)
        host.post(activity("b", priority: 0), from: b)
        host.showHUD(hud("A"), duration: .seconds(5), from: a)
        host.showHUD(hud("B"), duration: .seconds(5), from: b)
        let answerA = Task { await host.requestAttention(AttentionRequest(title: "A", message: ""), from: a) }
        await settle { host.attention != nil }
        let answerB = Task { await host.requestAttention(AttentionRequest(title: "B", message: ""), from: b) }
        await Task.yield()
        host.present(Takeover(duration: .seconds(5)) { Text("A") }, from: a)
        #expect(host.state == .takeover)
        #expect(host.liveActivity?.pluginID == a)

        host.withdraw(from: a)

        #expect(await answerA.value == .cancelled)
        #expect(host.takeover == nil)
        #expect(host.liveActivity?.pluginID == b)
        #expect(host.hud?.pluginID == b)
        await settle { host.attention?.pluginID == b }
        #expect(host.state == .attention)

        host.respond(.dismissed, to: try #require(host.attention).id)
        #expect(await answerB.value == .dismissed)
        #expect(host.state == .hud)
    }

    @Test func R03__withdraw_removes_the_plugins_hud() {
        host.post(activity("b"), from: b)
        host.showHUD(hud("A"), duration: .seconds(5), from: a)
        #expect(host.state == .hud)

        host.withdraw(from: a)

        #expect(host.hud == nil)
        #expect(host.state == .collapsed)
        #expect(host.liveActivity?.pluginID == b)
    }

    @Test func R03__withdrawing_a_plugin_showing_nothing_changes_nothing() async throws {
        host.post(activity("a"), from: a)
        host.showHUD(hud("B"), duration: .seconds(5), from: b)
        let answer = Task { await host.requestAttention(AttentionRequest(title: "A", message: ""), from: a) }
        await settle { host.attention != nil }
        host.present(Takeover(duration: .seconds(5)) { Text("B") }, from: b)

        host.withdraw(from: "com.example.c")

        #expect(host.state == .takeover)
        #expect(host.takeover?.pluginID == b)
        #expect(host.hud?.pluginID == b)
        #expect(host.liveActivity?.pluginID == a)
        let pending = try #require(host.attention)
        #expect(pending.pluginID == a)

        host.respond(.released, to: pending.id)
        #expect(await answer.value == .released)
    }
}
