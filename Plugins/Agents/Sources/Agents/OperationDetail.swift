import Foundation
import HookBridge

/// Everything a permission request asks to do, laid out for the user. Every member of the tool's
/// input appears in a section, so approving it never approves something the user did not see.
struct OperationDetail: Equatable {
    struct Section: Hashable {
        let label: String
        let body: String
    }

    let tool: String
    let sections: [Section]
    /// The whole operation as the notch shows it, when it is short enough to read there in full.
    /// Nil means the notch must not offer 허용: the user allows it on the Agents screen instead.
    let notchText: String?
    /// The notch's message when the operation does not fit there.
    let headline: String

    /// The notch's message area (580 × 300 points, 12-point text) shows this much without scrolling.
    static let notchCharacters = 160
    static let notchLines = 3

    init(tool: String, input: JSONValue?) {
        self.tool = tool
        var rest: [String: JSONValue]
        var unreadable: JSONValue?
        if case .object(let members) = input ?? .null {
            rest = members
        } else {
            rest = [:]
            unreadable = input
        }
        func take(_ key: String) -> String? {
            guard let value = rest[key]?.string else { return nil }
            rest[key] = nil
            return value
        }
        var sections: [Section] = []
        var notchText: String?
        switch tool {
        case "Bash":
            let command = take("command")
            if let command { sections.append(Section(label: "명령", body: command)) }
            if let description = take("description") { sections.append(Section(label: "설명", body: description)) }
            // A time limit does not change what runs; any other setting (sandbox, background) does.
            let settings = rest.keys.filter { $0 != "timeout" }
            if let command, settings.isEmpty, unreadable == nil, Self.fitsNotch(command) {
                notchText = command
            }
            headline = settings.isEmpty
                ? "명령이 길어서 노치에 다 보이지 않아요. 자세히 보기에서 전체 명령을 확인해 주세요."
                : "명령에 다른 설정이 함께 있어요. 자세히 보기에서 전체 내용을 확인해 주세요."
        case "Write":
            let path = take("file_path")
            if let path { sections.append(Section(label: "파일", body: path)) }
            if let content = take("content") { sections.append(Section(label: "새 내용", body: content)) }
            headline = (path.map { "\($0) 파일에" } ?? "파일에") + " 내용을 써요. 자세히 보기에서 전체 내용을 확인해 주세요."
        case "Edit":
            let path = take("file_path")
            if let path { sections.append(Section(label: "파일", body: path)) }
            if let old = take("old_string") { sections.append(Section(label: "바꾸기 전", body: old)) }
            if let new = take("new_string") { sections.append(Section(label: "바꾼 뒤", body: new)) }
            if rest["replace_all"]?.bool == true {
                rest["replace_all"] = nil
                sections.append(Section(label: "바꾸는 곳", body: "일치하는 곳을 모두 바꿔요"))
            }
            headline = (path.map { "\($0) 파일을" } ?? "파일을") + " 고쳐요. 자세히 보기에서 바뀌는 내용을 확인해 주세요."
        default:
            headline = "자세히 보기에서 \(tool) 도구의 전체 입력을 확인해 주세요."
        }
        if let leftover = unreadable ?? (rest.isEmpty ? nil : .object(rest)) {
            sections.append(Section(label: sections.isEmpty ? "입력" : "그 밖의 입력", body: Self.pretty(leftover)))
        }
        self.sections = sections
        self.notchText = notchText
    }

    static func fitsNotch(_ text: String) -> Bool {
        text.count <= notchCharacters
            && text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count <= notchLines
    }

    private static func pretty(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return String(describing: value) }
        return String(decoding: data, as: UTF8.self)
    }
}

/// One of AskUserQuestion's questions.
struct Question: Equatable {
    let text: String
    let options: [String]
    let multiple: Bool

    /// The tool input's questions, or nil when there are none or one cannot be read.
    static func parse(_ input: JSONValue?) -> [Question]? {
        guard let items = input?["questions"]?.array, !items.isEmpty else { return nil }
        let questions = items.compactMap { item -> Question? in
            guard let text = item["question"]?.string else { return nil }
            let options = item["options"]?.array?.compactMap { $0["label"]?.string } ?? []
            return Question(text: text, options: options, multiple: item["multiSelect"]?.bool ?? false)
        }
        return questions.count == items.count ? questions : nil
    }

    /// Each question's answer by its text: the picked option (labels when several may be picked),
    /// otherwise the text typed for that question. Nil while some question has neither.
    static func answers(_ questions: [Question], picked: [Int: [String]], typed: [Int: String]) -> [String: JSONValue]? {
        var answers: [String: JSONValue] = [:]
        for (index, question) in questions.enumerated() {
            let picks = picked[index] ?? []
            let text = typed[index]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let first = picks.first {
                answers[question.text] = question.multiple ? .array(picks.map(JSONValue.string)) : .string(first)
            } else if !text.isEmpty {
                answers[question.text] = .string(text)
            } else {
                return nil
            }
        }
        return answers
    }
}

/// The answers being filled in on the Agents screen. A question is answered by its options or by
/// typed text, never both: typing clears the question's picks and picking clears its text, so what
/// the form shows is what is sent.
struct AnswerDraft: Equatable {
    let questions: [Question]
    /// Picked options by question index.
    private(set) var picked: [Int: [String]]
    /// Typed answers by question index.
    private(set) var typed: [Int: String] = [:]

    init(_ questions: [Question], picked: [Int: [String]]) {
        self.questions = questions
        self.picked = picked
    }

    /// Picks `option` of the question at `index`, or unpicks it.
    mutating func pick(_ option: String, at index: Int) {
        let question = questions[index]
        var chosen = picked[index] ?? []
        if question.multiple {
            if let found = chosen.firstIndex(of: option) { chosen.remove(at: found) } else { chosen.append(option) }
            chosen.sort { (question.options.firstIndex(of: $0) ?? 0) < (question.options.firstIndex(of: $1) ?? 0) }
        } else {
            chosen = chosen == [option] ? [] : [option]
        }
        picked[index] = chosen.isEmpty ? nil : chosen
        if !chosen.isEmpty { typed[index] = nil }
    }

    mutating func type(_ text: String, at index: Int) {
        typed[index] = text
        if !text.isEmpty { picked[index] = nil }
    }

    func isPicked(_ option: String, at index: Int) -> Bool {
        picked[index]?.contains(option) == true
    }

    /// What 보내기 sends.
    var response: ScreenResponse { .answers(picked: picked, typed: typed) }

    /// Nil while some question has no answer yet.
    var answers: [String: JSONValue]? { Question.answers(questions, picked: picked, typed: typed) }
}
