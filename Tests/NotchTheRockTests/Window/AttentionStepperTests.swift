import AppKit
import Foundation
import NotchKit
import SwiftUI
import Testing
@testable import NotchTheRock

/// A request with several choice groups asks them one at a time, through the host model the card's
/// controls call and drawn offscreen by the app's root view (`AttentionBandRenderTests.render`).
/// A request with one group is answered as before, and a card too tall for the notch scrolls with a
/// cue that more is below.
@MainActor
@Suite struct AttentionStepperTests {
    static let groups = [
        AttentionChoices(
            id: "scope", prompt: "이번 변경을 어디까지 적용할지 골라 주세요. 범위가 넓으면 검토할 파일도 그만큼 늘어나요.",
            options: ["이 파일만", "이 폴더 전체", "저장소 전체", "나중에 정할게요"]
        ),
        AttentionChoices(id: "tests", prompt: "테스트는 어떻게 할까요?", options: ["새로 추가", "기존 것만 실행", "건너뛰기"]),
        AttentionChoices(
            id: "branch", prompt: "브랜치 이름을 골라 주세요.", options: ["feature/stepper", "fix/question-card"],
            textField: AttentionTextField(placeholder: "직접 입력")
        ),
        AttentionChoices(id: "extras", prompt: "함께 할 일을 모두 골라 주세요.", options: ["문서 고치기", "변경 기록 쓰기", "리뷰 요청"], allowsMultiple: true),
    ]

    /// Four questions with the plugin's own buttons, one of them destructive, so its red fill tells
    /// when the buttons are drawn.
    static func request(_ choices: [AttentionChoices] = groups) -> AttentionRequest {
        AttentionRequest(
            title: "질문", message: "Claude가 몇 가지를 물어봐요.", accent: AttentionBandRenderTests.accent,
            sourceIcon: AttentionBandRenderTests.icon,
            buttons: [AttentionButton(id: "deny", title: "거절", role: .destructive), AttentionButton(id: "send", title: "보내기", role: .primary)],
            choices: choices, releaseTitle: "터미널에서 답하기"
        )
    }

    /// Pixels inside `rect` (points from the canvas's top-left) that `matches` takes.
    nonisolated static func count(_ image: CGImage, scale: CGFloat, in rect: CGRect, _ matches: (Int, Int, Int) -> Bool) -> Int {
        let pixels = AttentionBandRenderTests.rgba(image)
        let x0 = max(0, Int(rect.minX * scale)), x1 = min(image.width, Int(rect.maxX * scale))
        let y0 = max(0, Int(rect.minY * scale)), y1 = min(image.height, Int(rect.maxY * scale))
        var found = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = (y * image.width + x) * 4
                if matches(Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2])) { found += 1 }
            }
        }
        return found
    }

    /// A destructive button's red fill.
    nonisolated static func isRed(_ r: Int, _ g: Int, _ b: Int) -> Bool { r - max(g, b) > 100 }
    /// Text and symbols: a channel of at least 60, where option rows and fields stay darker.
    nonisolated static func isInk(_ r: Int, _ g: Int, _ b: Int) -> Bool { max(r, g, b) >= 60 }

    /// The button row, 28 pt at the content's bottom.
    nonisolated static func buttonRow(_ content: CGRect) -> CGRect {
        CGRect(x: content.minX, y: content.maxY - 28, width: content.width, height: 28)
    }

    /// The middle of the lower half of the details above the button row, where the cue that more is
    /// below sits and a choice's left-aligned option labels do not reach.
    nonisolated static func cueArea(_ content: CGRect) -> CGRect {
        CGRect(x: content.midX - 40, y: content.midY, width: 80, height: content.maxY - 40 - content.midY)
    }

    func waitForAttention(_ host: NotchHostModel) async throws -> NotchHostModel.PendingAttention {
        for _ in 0..<100 where host.state != .attention { await Task.yield() }
        return try #require(host.attention)
    }

    @Test func R62__four_questions_show_one_at_a_time_and_send_every_answer_from_the_last() async throws {
        let host = NotchHostModel()
        let answer = Task { await host.requestAttention(Self.request(), from: "com.example.agents") }
        defer { answer.cancel() }
        let id = try await waitForAttention(host).id
        func form() throws -> AttentionForm { try #require(host.attention?.form, "the request is no longer shown") }
        let render = AttentionBandRenderTests()

        /// Draws the step, checks its height against the same question asked alone, the plugin's
        /// buttons against whether it is the last step, and the release button.
        func drawStep(_ index: Int, file: String? = nil) async throws {
            #expect(try form().progress == "\(index + 1)/4")
            #expect(try form().shownGroups.map(\.id) == [Self.groups[index].id], "step \(index + 1) shows other groups")
            let (image, scale, metrics) = try await render.render(host, file: file)
            let alone = try await render.draw("alone-\(index)", Self.request([Self.groups[index]]), file: "P71-render-alone-\(index + 1)").metrics
            let content = AttentionBandRenderTests.content(of: metrics)
            let red = Self.count(image, scale: scale, in: Self.buttonRow(content), Self.isRed)
            let release = Self.count(image, scale: scale, in: CGRect(x: content.minX, y: content.maxY - 28, width: 80, height: 28), Self.isInk)
            print("R62 step \(index + 1)/4: shape \(metrics.size), content \(metrics.content.size), alone \(alone.size), red \(red), release ink \(release)")
            #expect(metrics.size.height <= alone.size.height + 1, "step \(index + 1) is taller than its question alone: \(metrics.size) vs \(alone.size)")
            #expect(metrics.content.height < NotchSizing.maxContentSize.height, "step \(index + 1) needs the scroll fallback")
            #expect(release > 0, "step \(index + 1): no release button")
            if index < 3 {
                #expect(red == 0, "step \(index + 1) shows the plugin's buttons")
            } else {
                #expect(red > 0, "the last step does not show the plugin's buttons")
            }
        }

        try await drawStep(0)
        #expect(try !form().canAdvance)
        host.pickAttention("저장소 전체", in: Self.groups[0], of: id)
        #expect(try form().progress == "2/4", "a pick did not move to the next question")
        host.editAttention(id) { $0.back() }
        #expect(try form().progress == "1/4")
        #expect(try form().selections["scope"] == ["저장소 전체"], "going back lost the pick")
        host.editAttention(id) { $0.advance() }
        try await drawStep(1, file: "R62-render-step-T188")

        host.pickAttention("기존 것만 실행", in: Self.groups[1], of: id)
        try await drawStep(2)
        #expect(try !form().canAdvance)
        host.editAttention(id) { $0.texts["branch"] = "   " }
        #expect(try !form().canAdvance, "blank text counts as an answer")
        host.editAttention(id) { $0.texts["branch"] = "feature/ask-stepper" }
        #expect(try form().canAdvance, "typed text does not count as an answer")
        host.editAttention(id) { $0.advance() }

        #expect(try form().isLastStep)
        #expect(try !form().canSend)
        host.sendAttention(buttonID: "send", of: id)
        #expect(host.attention?.id == id, "sent with the last question unanswered")
        host.pickAttention("문서 고치기", in: Self.groups[3], of: id)
        host.pickAttention("리뷰 요청", in: Self.groups[3], of: id)
        #expect(try form().selections["extras"] == ["문서 고치기", "리뷰 요청"])
        #expect(host.state == .attention && host.attention?.id == id, "a step sent the request by itself")
        try await drawStep(3, file: "R62-render-last-T188")

        host.sendAttention(buttonID: "send", of: id)
        let expected = AttentionAnswer(
            buttonID: "send",
            choices: ["scope": ["저장소 전체"], "tests": ["기존 것만 실행"], "extras": ["문서 고치기", "리뷰 요청"]],
            text: nil, texts: ["branch": "feature/ask-stepper"]
        )
        #expect(await answer.value == .answered(expected))
    }

    @Test func R62__a_single_question_is_still_sent_by_picking_an_option() async throws {
        let host = NotchHostModel()
        let request = AttentionBandRenderTests.approval
        let answer = Task { await host.requestAttention(request, from: "com.example.agents") }
        defer { answer.cancel() }
        let pending = try await waitForAttention(host)
        #expect(pending.form.progress == nil)
        #expect(pending.form.isLastStep)
        #expect(pending.form.shownGroups.map(\.id) == ["answer"])
        host.pickAttention("허용", in: request.choices[0], of: pending.id)
        #expect(await answer.value == .answered(AttentionAnswer(buttonID: nil, choices: ["answer": ["허용"]])))
    }

    /// A card taller than the notch offers scrolls, and shows that more is below; a short one shows
    /// everything without the cue. The host leaves it to the plugin whether a button needs a pick.
    @Test func R61__a_card_too_tall_for_the_notch_scrolls_with_a_cue_that_more_is_below() async throws {
        let render = AttentionBandRenderTests()
        func ask(_ count: Int) -> AttentionRequest {
            AttentionRequest(
                title: "질문", message: "", accent: AttentionBandRenderTests.accent,
                choices: [AttentionChoices(id: "pick", prompt: "하나 골라 주세요.", options: (1...count).map { "선택지 \($0)" })],
                releaseTitle: "터미널에서 답하기"
            )
        }
        let (long, longScale, longMetrics) = try await render.draw("overflow", ask(18), file: "R61-render-overflow-T188")
        let (short, shortScale, shortMetrics) = try await render.draw("short", ask(3), file: "P71-render-short")
        let longCue = Self.count(long, scale: longScale, in: Self.cueArea(AttentionBandRenderTests.content(of: longMetrics)), Self.isInk)
        let shortCue = Self.count(short, scale: shortScale, in: Self.cueArea(AttentionBandRenderTests.content(of: shortMetrics)), Self.isInk)
        print("R61 overflow: content \(longMetrics.content.size), cue ink \(longCue); short: content \(shortMetrics.content.size), cue ink \(shortCue)")
        #expect(abs(longMetrics.content.height - NotchSizing.maxContentSize.height) <= 1, "the long card does not fill the notch's height")
        #expect(longCue > 0, "the scrolling card shows no cue that more is below")
        #expect(shortMetrics.content.height < NotchSizing.maxContentSize.height)
        #expect(shortCue == 0, "the short card shows the cue")

        let host = NotchHostModel()
        var request = ask(3)
        request.buttons = [AttentionButton(id: "ok", title: "확인", role: .primary)]
        let answer = Task { [request] in await host.requestAttention(request, from: "com.example.agents") }
        defer { answer.cancel() }
        let pending = try await waitForAttention(host)
        host.sendAttention(buttonID: "ok", of: pending.id)
        #expect(await answer.value == .answered(AttentionAnswer(buttonID: "ok")), "the host required a pick for the plugin's button")
    }
}
