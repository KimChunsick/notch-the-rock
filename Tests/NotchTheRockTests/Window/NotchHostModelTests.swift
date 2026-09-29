import NotchKit
import SwiftUI
import Testing
@testable import NotchTheRock

/// A clock the tests move by hand; the host reads it and `expireDue()` applies what is due.
@MainActor
final class ManualClock {
    var now = ContinuousClock.now

    func advance(by duration: Duration) {
        now += duration
    }
}

@MainActor
struct NotchHostModelTests {
    let clock = ManualClock()
    let host: NotchHostModel

    init() {
        let clock = clock
        host = NotchHostModel(now: { clock.now })
    }

    func activity(_ id: String, priority: Int = 0, expiresAfter: Duration? = nil) -> LiveActivity {
        LiveActivity(id: id, priority: priority, expiresAfter: expiresAfter, leading: { Text(id) }, trailing: { EmptyView() })
    }

    /// Lets tasks started on the main actor run until `condition` holds.
    func settle(until condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
    }

    @Test func R02__takeover_beats_attention_beats_hud_beats_live_activity() async throws {
        host.post(activity("music"), from: "com.example.music")
        #expect(host.state == .collapsed)
        #expect(host.liveActivity?.activity.id == "music")

        host.showHUD(HUD(symbol: "speaker.wave.2", title: "음량", value: 0.5), duration: .seconds(2), from: "com.example.keys")
        #expect(host.state == .hud)

        let answer = Task { await host.requestAttention(AttentionRequest(title: "허용할까요?", message: ""), from: "com.example.agent") }
        await settle { host.state == .attention }
        #expect(host.state == .attention)

        host.present(Takeover(duration: .seconds(3)) { Text("안녕하세요") }, from: "com.example.hello")
        #expect(host.state == .takeover)

        clock.advance(by: .seconds(1))
        host.expireDue()
        #expect(host.state == .takeover)

        clock.advance(by: .seconds(2))
        host.expireDue()
        #expect(host.state == .attention)

        let pending = try #require(host.attention)
        host.respond(.dismissed, to: pending.id)
        #expect(await answer.value == .dismissed)
        #expect(host.state == .collapsed)
        #expect(host.hud == nil)
        #expect(host.liveActivity?.activity.id == "music")
    }

    @Test func R02__highest_priority_unexpired_live_activity_wins() {
        host.post(activity("clock", priority: 0), from: "com.example.clock")
        host.post(activity("timer", priority: 100, expiresAfter: .seconds(5)), from: "com.example.timer")
        #expect(host.liveActivity?.activity.id == "timer")

        // Same priority: the most recently posted wins.
        host.post(activity("music", priority: 100), from: "com.example.music")
        #expect(host.liveActivity?.activity.id == "music")
        host.clearActivity(id: "music", from: "com.example.music")
        #expect(host.liveActivity?.activity.id == "timer")

        clock.advance(by: .seconds(5))
        host.expireDue()
        #expect(host.liveActivity?.activity.id == "clock")
    }

    @Test func R02__posting_same_id_replaces_only_that_plugins_activity() {
        host.post(activity("now", priority: 10), from: "com.example.a")
        host.post(activity("now", priority: 20), from: "com.example.b")
        host.post(activity("now", priority: 0), from: "com.example.b")
        #expect(host.liveActivity?.pluginID == "com.example.a")

        // Clearing another plugin's id does nothing.
        host.clearActivity(id: "now", from: "com.example.c")
        #expect(host.liveActivity?.pluginID == "com.example.a")
    }

    @Test func R02__hud_disappears_after_its_duration() {
        host.showHUD(HUD(symbol: "sun.max", title: "밝기"), duration: .seconds(2), from: "com.example.keys")
        #expect(host.state == .hud)
        clock.advance(by: .milliseconds(1_999))
        host.expireDue()
        #expect(host.state == .hud)
        clock.advance(by: .milliseconds(1))
        host.expireDue()
        #expect(host.state == .collapsed)
    }

    @Test func R02__attention_resolves_exactly_once() async throws {
        let answer = Task {
            await host.requestAttention(AttentionRequest(title: "질문", message: "", timeout: .seconds(10)), from: "com.example.agent")
        }
        await settle { host.attention != nil }
        let pending = try #require(host.attention)

        host.respond(.answered(AttentionAnswer(buttonID: "allow")), to: pending.id)
        host.respond(.released, to: pending.id)
        clock.advance(by: .seconds(11))
        host.expireDue()

        #expect(await answer.value == .answered(AttentionAnswer(buttonID: "allow")))
        #expect(host.attention == nil)
    }

    @Test func R02__attention_times_out() async {
        let answer = Task {
            await host.requestAttention(AttentionRequest(title: "질문", message: "", timeout: .seconds(10)), from: "com.example.agent")
        }
        await settle { host.attention != nil }
        clock.advance(by: .seconds(10))
        host.expireDue()
        #expect(await answer.value == .timedOut)
        #expect(host.state == .collapsed)
    }

    @Test func R02__attention_withdrawn_when_task_cancelled() async {
        let answer = Task {
            await host.requestAttention(AttentionRequest(title: "질문", message: ""), from: "com.example.agent")
        }
        await settle { host.attention != nil }
        answer.cancel()
        #expect(await answer.value == .cancelled)
        await settle { host.attention == nil }
        #expect(host.attention == nil)
    }

    @Test func R02__attention_requests_queue_in_order() async throws {
        let first = Task { await host.requestAttention(AttentionRequest(title: "첫째", message: ""), from: "com.example.a") }
        await settle { host.attention != nil }
        let second = Task { await host.requestAttention(AttentionRequest(title: "둘째", message: ""), from: "com.example.b") }
        await Task.yield()
        #expect(host.attention?.request.title == "첫째")

        host.respond(.dismissed, to: try #require(host.attention).id)
        await settle { host.attention?.request.title == "둘째" }
        host.respond(.released, to: try #require(host.attention).id)
        #expect(await first.value == .dismissed)
        #expect(await second.value == .released)
    }

    @Test func R02__takeover_returns_to_collapsed() {
        host.setHovering(true)
        #expect(host.state == .expanded)
        host.present(Takeover(duration: .seconds(3)) { Text("안녕하세요") }, from: "com.example.hello")
        #expect(host.state == .takeover)
        clock.advance(by: .seconds(3))
        host.expireDue()
        #expect(host.state == .collapsed)
    }

    @Test func R02__hover_expands_and_collapses() {
        host.setHovering(true)
        #expect(host.state == .expanded)
        host.setHovering(false)
        #expect(host.state == .collapsed)
    }

    @Test func R02__expand_selects_the_plugins_tab() {
        host.tabs = [
            NotchHostModel.Tab(pluginID: "com.example.a", tab: PluginTab(title: "A", symbol: "a.circle") { EmptyView() }),
            NotchHostModel.Tab(pluginID: "com.example.b", tab: PluginTab(title: "B", symbol: "b.circle") { EmptyView() }),
        ]
        #expect(host.selectedTabID == "com.example.a")
        host.expand(toTabOf: "com.example.b")
        #expect(host.state == .expanded)
        #expect(host.selectedTabID == "com.example.b")
        host.collapse(from: "com.example.b")
        #expect(host.state == .collapsed)
    }

    @Test func R02__pinned_state_ignores_hover_and_plugins() {
        let pinned = NotchHostModel(now: { .now }, pinnedExpansion: true)
        #expect(pinned.state == .expanded)
        pinned.setHovering(false)
        pinned.collapse(from: "com.example.a")
        #expect(pinned.state == .expanded)

        let pinnedCollapsed = NotchHostModel(now: { .now }, pinnedExpansion: false)
        pinnedCollapsed.setHovering(true)
        pinnedCollapsed.expand(toTabOf: "com.example.a")
        #expect(pinnedCollapsed.state == .collapsed)
    }
}
