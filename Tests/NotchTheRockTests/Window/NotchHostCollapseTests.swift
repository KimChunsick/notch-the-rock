import NotchKit
import Testing
@testable import NotchTheRock

/// A plugin that folds the notch after the user answers its attention request (the Agents
/// plugin's "터미널로 이동") leaves the notch folded for a moment before the rest of the queue shows.
/// Nothing is dropped, and a fold without an answer works as before.
@MainActor
struct NotchHostCollapseTests {
    let clock = ManualClock()
    let host: NotchHostModel
    let agents = "com.example.agents"
    let hold = NotchHostModel.collapseHold

    init() {
        let clock = clock
        host = NotchHostModel(now: { clock.now })
    }

    /// An agent alert: a title and a jump button, gone five seconds after it shows (R45).
    func notice(_ title: String) -> AttentionRequest {
        AttentionRequest(title: title, message: "", buttons: [AttentionButton(id: "jump", title: "터미널로 이동", role: .primary)], timeout: .seconds(5))
    }

    /// A request that waits for an answer, like an approval handed over from the terminal.
    func approval(_ title: String) -> AttentionRequest {
        AttentionRequest(title: title, message: "", buttons: [AttentionButton(id: "allow", title: "허용", role: .primary)], releaseTitle: "터미널에서 답하기", timeout: .seconds(60))
    }

    /// Lets queued `requestAttention` tasks reach the host.
    func drain() async {
        for _ in 0..<100 { await Task.yield() }
    }

    func advance(by duration: Duration) {
        clock.advance(by: duration)
        host.expireDue()
    }

    /// The user presses the shown alert's jump button and the plugin receives the answer.
    func pressJump(on task: Task<AttentionResponse, Never>) async throws {
        let jump = AttentionResponse.answered(AttentionAnswer(buttonID: "jump"))
        host.respond(jump, to: try #require(host.attention).id)
        #expect(await task.value == jump)
    }

    @Test func R51__jump_from_one_of_two_alerts_folds_the_notch_and_holds_the_other() async throws {
        let first = Task { await host.requestAttention(notice("세션 1 작업을 마쳤어요"), from: agents) }
        await drain()
        let second = Task { await host.requestAttention(notice("세션 2 작업을 마쳤어요"), from: agents) }
        await drain()
        host.setHovering(true)
        #expect(host.state == .attention)

        try await pressJump(on: first)
        // The terminal takes a moment to come forward; the second alert shows meanwhile.
        advance(by: .milliseconds(300))
        #expect(host.attention?.request.title == "세션 2 작업을 마쳤어요")
        host.collapse(from: agents)
        #expect(host.state == .collapsed)

        advance(by: hold - .milliseconds(100))
        #expect(host.state == .collapsed)
        advance(by: .milliseconds(100))
        #expect(host.state == .attention)
        #expect(host.attention?.request.title == "세션 2 작업을 마쳤어요")

        // It shows for its full five seconds from now on.
        advance(by: .milliseconds(4900))
        #expect(host.state == .attention)
        advance(by: .milliseconds(100))
        #expect(await second.value == .timedOut)
        #expect(host.state == .collapsed)
    }

    @Test func R51__request_behind_the_jump_shows_after_the_hold_with_its_asked_deadline() async throws {
        let alert = Task { await host.requestAttention(notice("세션 1 작업을 마쳤어요"), from: agents) }
        await drain()
        let askedAt = clock.now
        let request = Task { await host.requestAttention(approval("허용할까요?"), from: agents) }
        await drain()

        advance(by: .seconds(1))
        try await pressJump(on: alert)
        host.collapse(from: agents)
        #expect(host.state == .collapsed)
        advance(by: hold)
        #expect(host.state == .attention)
        #expect(host.attention?.request.title == "허용할까요?")
        #expect(host.attention?.deadline == askedAt + .seconds(60))

        advance(by: .seconds(60) - .seconds(1) - hold - .milliseconds(100))
        #expect(host.state == .attention)
        advance(by: .milliseconds(100))
        #expect(await request.value == .timedOut)
        #expect(host.state == .collapsed)
    }

    @Test func R51__collapse_without_an_answer_leaves_the_queue_as_it_was() async throws {
        let first = Task { await host.requestAttention(notice("세션 1 작업을 마쳤어요"), from: agents) }
        await drain()
        let second = Task { await host.requestAttention(notice("세션 2 작업을 마쳤어요"), from: agents) }
        await drain()
        host.setHovering(true)

        // Nothing answered: only the expansion folds and the alert stays.
        host.collapse(from: agents)
        #expect(host.isExpanded == false)
        #expect(host.state == .attention)
        #expect(host.attention?.request.title == "세션 1 작업을 마쳤어요")

        // Another plugin folding right after the answer does not hold the next alert either.
        host.respond(.dismissed, to: try #require(host.attention).id)
        #expect(await first.value == .dismissed)
        host.collapse(from: "com.example.other")
        #expect(host.state == .attention)
        #expect(host.attention?.request.title == "세션 2 작업을 마쳤어요")

        advance(by: .seconds(5))
        #expect(await second.value == .timedOut)
        #expect(host.state == .collapsed)
    }

    @Test func R51__jump_that_takes_three_seconds_still_folds_the_notch_and_holds_the_next_alert() async throws {
        let first = Task { await host.requestAttention(notice("세션 1 작업을 마쳤어요"), from: agents) }
        await drain()
        let second = Task { await host.requestAttention(notice("세션 2 작업을 마쳤어요"), from: agents) }
        await drain()
        host.setHovering(true)

        try await pressJump(on: first)
        // A slow terminal comes forward three seconds later; the second alert has been showing since.
        advance(by: .seconds(3))
        #expect(host.state == .attention)
        #expect(host.attention?.request.title == "세션 2 작업을 마쳤어요")
        host.collapse(from: agents)
        #expect(host.state == .collapsed)

        advance(by: hold - .milliseconds(100))
        #expect(host.state == .collapsed)
        advance(by: .milliseconds(100))
        #expect(host.state == .attention)
        #expect(host.attention?.request.title == "세션 2 작업을 마쳤어요")

        // Hidden after three of its five seconds, it shows for all five again.
        advance(by: .milliseconds(4900))
        #expect(host.state == .attention)
        advance(by: .milliseconds(100))
        #expect(await second.value == .timedOut)
        #expect(host.state == .collapsed)
    }

    @Test func R51__another_answer_ends_the_fold_of_the_earlier_one() async throws {
        let first = Task { await host.requestAttention(notice("세션 1 작업을 마쳤어요"), from: agents) }
        await drain()
        let other = Task { await host.requestAttention(notice("배터리가 부족해요"), from: "com.example.other") }
        await drain()
        let next = Task { await host.requestAttention(notice("세션 2 작업을 마쳤어요"), from: agents) }
        await drain()

        try await pressJump(on: first)
        host.respond(.dismissed, to: try #require(host.attention).id)
        #expect(await other.value == .dismissed)
        host.collapse(from: agents)
        #expect(host.state == .attention)
        #expect(host.attention?.request.title == "세션 2 작업을 마쳤어요")

        host.respond(.dismissed, to: try #require(host.attention).id)
        #expect(await next.value == .dismissed)
    }

    @Test func R51__alert_timing_out_during_the_jump_keeps_the_fold() async throws {
        let first = Task { await host.requestAttention(notice("세션 1 작업을 마쳤어요"), from: agents) }
        await drain()
        let short = AttentionRequest(title: "배터리가 부족해요", message: "", buttons: [], timeout: .seconds(1))
        let other = Task { await host.requestAttention(short, from: "com.example.other") }
        await drain()
        let next = Task { await host.requestAttention(notice("세션 2 작업을 마쳤어요"), from: agents) }
        await drain()

        try await pressJump(on: first)
        // The other alert times out while the terminal comes forward, and the next one shows.
        advance(by: .seconds(1))
        #expect(await other.value == .timedOut)
        #expect(host.attention?.request.title == "세션 2 작업을 마쳤어요")
        advance(by: .seconds(2))
        host.collapse(from: agents)
        #expect(host.state == .collapsed)

        advance(by: hold - .milliseconds(100))
        #expect(host.state == .collapsed)
        advance(by: .milliseconds(100))
        #expect(host.state == .attention)
        #expect(host.attention?.request.title == "세션 2 작업을 마쳤어요")

        // Hidden after two of its five seconds, it shows for all five again.
        advance(by: .milliseconds(4900))
        #expect(host.state == .attention)
        advance(by: .milliseconds(100))
        #expect(await next.value == .timedOut)
        #expect(host.state == .collapsed)
    }

    @Test func R51__hover_intent_from_before_the_answer_keeps_the_fold() async throws {
        let first = Task { await host.requestAttention(notice("세션 1 작업을 마쳤어요"), from: agents) }
        await drain()
        let second = Task { await host.requestAttention(notice("세션 2 작업을 마쳤어요"), from: agents) }
        await drain()
        #expect(host.isExpanded == false)

        // The pointer enters the folded notch's alert and presses the jump button within the open
        // intent; the hover scheduled before the press comes after it, over the second alert.
        try await pressJump(on: first)
        host.setHovering(true)
        #expect(host.state == .attention)
        advance(by: .milliseconds(300))
        host.collapse(from: agents)
        #expect(host.state == .collapsed)

        advance(by: hold - .milliseconds(100))
        #expect(host.state == .collapsed)
        advance(by: .milliseconds(100))
        #expect(host.state == .attention)
        #expect(host.attention?.request.title == "세션 2 작업을 마쳤어요")

        advance(by: .milliseconds(4900))
        #expect(host.state == .attention)
        advance(by: .milliseconds(100))
        #expect(await second.value == .timedOut)
        #expect(host.state == .collapsed)
    }

    @Test func R51__hover_intent_from_before_the_answer_keeps_the_fold_with_no_alert_showing() async throws {
        let first = Task { await host.requestAttention(notice("세션 1 작업을 마쳤어요"), from: agents) }
        await drain()
        #expect(host.isExpanded == false)

        // The pointer enters the folded notch's only alert and presses the jump button within the
        // open intent; the hover comes after the answer, with nothing on screen, and opens the notch.
        let entered = clock.now
        advance(by: .milliseconds(80))
        try await pressJump(on: first)
        advance(by: .milliseconds(40))
        host.setHovering(true, intentBegan: entered)
        #expect(host.state == .expanded)
        // An alert arrives before the terminal comes forward.
        let next = Task { await host.requestAttention(notice("세션 2 작업을 마쳤어요"), from: agents) }
        await drain()
        advance(by: .milliseconds(300))
        host.collapse(from: agents)
        #expect(host.state == .collapsed)

        advance(by: hold - .milliseconds(100))
        #expect(host.state == .collapsed)
        advance(by: .milliseconds(100))
        #expect(host.state == .attention)
        #expect(host.attention?.request.title == "세션 2 작업을 마쳤어요")

        // Hidden after a moment, it shows for its full five seconds.
        advance(by: .milliseconds(4900))
        #expect(host.state == .attention)
        advance(by: .milliseconds(100))
        #expect(await next.value == .timedOut)
        #expect(host.state == .collapsed)
    }

    @Test func R51__user_opening_the_notch_with_no_alert_showing_ends_the_fold() async throws {
        let first = Task { await host.requestAttention(notice("세션 1 작업을 마쳤어요"), from: agents) }
        await drain()

        try await pressJump(on: first)
        #expect(host.state == .collapsed)
        // The user enters the folded notch after the answer, while the terminal comes forward, and
        // it opens; then an alert arrives.
        advance(by: .milliseconds(100))
        let entered = clock.now
        advance(by: .milliseconds(120))
        host.setHovering(true, intentBegan: entered)
        #expect(host.state == .expanded)
        let next = Task { await host.requestAttention(notice("세션 2 작업을 마쳤어요"), from: agents) }
        await drain()
        host.collapse(from: agents)
        #expect(host.isExpanded == false)
        #expect(host.state == .attention)
        #expect(host.attention?.request.title == "세션 2 작업을 마쳤어요")

        advance(by: .seconds(5))
        #expect(await next.value == .timedOut)
        #expect(host.state == .collapsed)
    }

    @Test func R45__five_second_alert_is_gone_five_seconds_after_it_appears() async throws {
        let request = Task { await host.requestAttention(approval("허용할까요?"), from: agents) }
        await drain()
        let alert = Task { await host.requestAttention(notice("작업을 마쳤어요"), from: agents) }
        await drain()

        advance(by: .seconds(10))
        host.respond(.released, to: try #require(host.attention).id)
        #expect(await request.value == .released)
        #expect(host.attention?.request.title == "작업을 마쳤어요")

        advance(by: .milliseconds(4900))
        #expect(host.state == .attention)
        advance(by: .milliseconds(100))
        #expect(await alert.value == .timedOut)
        #expect(host.state == .collapsed)
    }
}
