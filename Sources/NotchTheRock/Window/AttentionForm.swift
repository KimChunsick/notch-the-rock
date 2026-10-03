import Foundation
import NotchKit

/// What the user has filled in on an attention request so far: the options picked and the text
/// typed in each choice group, and the request's own text field.
///
/// A request with more than one choice group shows one group per step, with its place among them
/// ("2/4"). Picking an option in a single-choice group moves to the next step; 다음 moves on once
/// the shown group has a pick or text, 이전 goes back, and picks and text stay through both. The
/// request is sent from the last step, once every group is answered, never by a pick. A request
/// with one group or none shows everything at once, as before.
struct AttentionForm {
    let groups: [AttentionChoices]
    private let hasButtons: Bool
    private let hasTextField: Bool
    /// The shown group's index while the request steps through its groups.
    private(set) var step = 0
    /// Picked options keyed by `AttentionChoices.id`, in the group's order.
    private(set) var selections: [String: [String]] = [:]
    /// Text typed into the groups' own fields, keyed by `AttentionChoices.id`.
    var texts: [String: String]
    /// The request's own text field.
    var text: String

    init(_ request: AttentionRequest) {
        groups = request.choices
        hasButtons = !request.buttons.isEmpty
        hasTextField = request.textField != nil
        texts = Dictionary(
            request.choices.compactMap { group in group.textField.map { (group.id, $0.initialText) } },
            uniquingKeysWith: { first, _ in first }
        )
        text = request.textField?.initialText ?? ""
    }

    /// More than one group: one per step.
    var isStepping: Bool { groups.count > 1 }

    /// The groups shown now: the step's own, or every group of a request that does not step.
    var shownGroups: [AttentionChoices] { isStepping ? [groups[step]] : groups }

    /// The step's place among them, like "2/4", or nil when the request does not step.
    var progress: String? { isStepping ? "\(step + 1)/\(groups.count)" : nil }

    var isFirstStep: Bool { step == 0 }

    /// Whether the request's buttons and its own text field show: on the last step, or always when
    /// the request does not step.
    var isLastStep: Bool { !isStepping || step == groups.count - 1 }

    /// A lone single choice with nothing else to fill in is answered by picking an option.
    var picksAnswerDirectly: Bool {
        !hasButtons && !hasTextField && groups.count == 1 && !groups[0].allowsMultiple && groups[0].textField == nil
    }

    /// Whether `group` has a pick or text other than blanks.
    func isAnswered(_ group: AttentionChoices) -> Bool {
        !(selections[group.id] ?? []).isEmpty
            || !(texts[group.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 다음 is offered before the last step and moves on once the shown group is answered.
    var canAdvance: Bool { isStepping && !isLastStep && isAnswered(groups[step]) }

    /// A stepping request is sent once every group is answered. Whether a request that does not step
    /// needs anything filled in is up to the plugin that asked.
    var canSend: Bool { !isStepping || groups.allSatisfy(isAnswered) }

    /// Picks or, in a multiple-choice group, toggles `option`. Returns whether the pick answers the
    /// request (`picksAnswerDirectly`); a pick in a single-choice group of a stepping request moves
    /// to the next step instead.
    mutating func pick(_ option: String, in group: AttentionChoices) -> Bool {
        var chosen = selections[group.id] ?? []
        if group.allowsMultiple {
            if let index = chosen.firstIndex(of: option) { chosen.remove(at: index) } else { chosen.append(option) }
            chosen.sort { group.options.firstIndex(of: $0) ?? 0 < group.options.firstIndex(of: $1) ?? 0 }
        } else {
            chosen = [option]
        }
        selections[group.id] = chosen
        if picksAnswerDirectly { return true }
        if isStepping && !group.allowsMultiple { advance() }
        return false
    }

    mutating func advance() {
        if canAdvance { step += 1 }
    }

    mutating func back() {
        if step > 0 { step -= 1 }
    }

    /// The answer submitted by `buttonID`: every group's picks and every group's text but blanks.
    func answer(buttonID: String?) -> AttentionAnswer {
        AttentionAnswer(
            buttonID: buttonID,
            choices: selections.filter { !$0.value.isEmpty },
            text: hasTextField ? text : nil,
            texts: texts.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        )
    }
}
