import NotchKit
import Testing
@testable import NotchTheRock

/// A plugin that folds the notch right after the user answers its attention request (the Agents
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

        // Another plugin folding right after the answer, or this one folding long after it, does
        // not hold the next alert either.
        host.respond(.dismissed, to: try #require(host.attention).id)
        #expect(await first.value == .dismissed)
        host.collapse(from: "com.example.other")
        #expect(host.state == .attention)
        advance(by: NotchHostModel.answerCollapseWindow + .milliseconds(100))
        host.collapse(from: agents)
        #expect(host.state == .attention)
        #expect(host.attention?.request.title == "세션 2 작업을 마쳤어요")

        advance(by: .seconds(5))
        #expect(await second.value == .timedOut)
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
