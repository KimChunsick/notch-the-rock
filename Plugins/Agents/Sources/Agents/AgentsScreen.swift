import Observation
import SwiftUI

/// A permission request or a set of questions waiting on the Agents screen, where it is shown in
/// full: the notch only has room for short operations and a single free-text answer.
struct ScreenItem: Identifiable {
    enum Content {
        case permission(OperationDetail)
        /// The questions, with the options already picked in the notch by question index.
        case questions([Question], picked: [Int: [String]])
    }

    let id: Int
    let title: String
    let content: Content
    /// When the request goes back to the terminal.
    let expires: Date
}

enum ScreenResponse: Equatable {
    case allow
    case deny(reason: String)
    /// Picked options and typed answers by question index.
    case answers(picked: [Int: [String]], typed: [Int: String])
    /// 터미널에서 답하기.
    case released
    case timedOut
    case cancelled
}

/// What the Agents screen shows, and the requests waiting for an answer there.
@MainActor
@Observable
final class AgentsScreenModel {
    /// Oldest first; the screen shows the first.
    private(set) var items: [ScreenItem] = []
    @ObservationIgnored private var waiting: [Int: CheckedContinuation<ScreenResponse, Never>] = [:]
    @ObservationIgnored private var count = 0

    /// Shows `content` until the user answers on the screen, the deadline passes or the calling task
    /// is cancelled (the hook went away); the item leaves the screen in every case.
    func show(title: String, content: ScreenItem.Content, until deadline: ContinuousClock.Instant) async -> ScreenResponse {
        guard !Task.isCancelled else { return .cancelled }
        count += 1
        let id = count
        let left = deadline - .now
        let expires = Date.now.addingTimeInterval(Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18)
        let timer = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            if !Task.isCancelled { self?.respond(to: id, with: .timedOut) }
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiting[id] = continuation
                items.append(ScreenItem(id: id, title: title, content: content, expires: expires))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.respond(to: id, with: .cancelled) }
        }
    }

    /// Answers the item `id`; an item already answered is ignored.
    func respond(to id: Int, with response: ScreenResponse) {
        guard let continuation = waiting.removeValue(forKey: id) else { return }
        items.removeAll { $0.id == id }
        continuation.resume(returning: response)
    }

    func cancelAll() {
        for id in waiting.keys {
            respond(to: id, with: .cancelled)
        }
    }
}

/// The plugin's screen in the expanded notch: the oldest waiting request, in full. The title and the
/// controls always stay in view; the request itself scrolls in the height left between them, so the
/// screen fits whatever size the host offers (on main up to 390 × 400 points, often less). Measured
/// without a limit it asks for all of its content.
struct AgentsScreen: View {
    /// The scrolling body never gets less than this, however little height the host offers.
    static let minimumBodyHeight: CGFloat = 56
    let model: AgentsScreenModel

    var body: some View {
        Group {
            if let item = model.items.first {
                ScreenItemView(item: item, others: model.items.count - 1) { model.respond(to: item.id, with: $0) }
                    .id(item.id)
            } else {
                Text("기다리는 요청이 없어요.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct ScreenItemView: View {
    let item: ScreenItem
    let others: Int
    let respond: (ScreenResponse) -> Void
    @State private var reason = ""
    @State private var draft: AnswerDraft

    init(item: ScreenItem, others: Int, respond: @escaping (ScreenResponse) -> Void) {
        self.item = item
        self.others = others
        self.respond = respond
        if case .questions(let questions, let picked) = item.content {
            _draft = State(initialValue: AnswerDraft(questions, picked: picked))
        } else {
            _draft = State(initialValue: AnswerDraft([], picked: [:]))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if others > 0 {
                    Text("\(others)개 더 기다려요")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Label {
                    Text(timerInterval: Date.now...max(item.expires, .now), countsDown: true)
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "timer")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ClaudeBridge.accent)
            }
            switch item.content {
            case .permission(let detail):
                permission(detail)
            case .questions(let questions, _):
                form(questions)
            }
        }
        .padding(.vertical, 8)
    }

    private func permission(_ detail: OperationDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(detail.sections, id: \.self) { section in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.label)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(verbatim: section.body)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(minHeight: AgentsScreen.minimumBodyHeight, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
            TextField("거부하는 이유 (비워 두면 이유 없이 거부해요)", text: $reason)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Button(ClaudeBridge.releaseTitle) { respond(.released) }
                    .buttonStyle(.bordered)
                Spacer(minLength: 0)
                Button("거부") { respond(.deny(reason: reason)) }
                    .tint(.red)
                Button("허용") { respond(.allow) }
                    .tint(ClaudeBridge.accent)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func form(_ questions: [Question]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(question.text)
                                .font(.system(size: 12, weight: .medium))
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(question.options, id: \.self) { option in
                                Button {
                                    draft.pick(option, at: index)
                                } label: {
                                    Label(option, systemImage: symbol(option, of: question, at: index))
                                        .font(.system(size: 12))
                                }
                                .buttonStyle(.plain)
                            }
                            TextField("직접 입력", text: Binding(
                                get: { draft.typed[index] ?? "" },
                                set: { draft.type($0, at: index) }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(minHeight: AgentsScreen.minimumBodyHeight, maxHeight: .infinity)
            HStack(spacing: 8) {
                Button(ClaudeBridge.releaseTitle) { respond(.released) }
                    .buttonStyle(.bordered)
                Spacer(minLength: 0)
                Button("보내기") { respond(draft.response) }
                    .tint(ClaudeBridge.accent)
                    .disabled(draft.answers == nil)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func symbol(_ option: String, of question: Question, at index: Int) -> String {
        let chosen = draft.isPicked(option, at: index)
        return question.multiple ? (chosen ? "checkmark.square.fill" : "square") : (chosen ? "largecircle.fill.circle" : "circle")
    }
}
