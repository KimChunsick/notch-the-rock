import SwiftUI

/// A request that makes the notch glow and asks the user something.
///
/// The host shows the title and message with any buttons, choice groups and text field, and
/// answers with exactly one `AttentionResponse`. Cancelling the task that awaits
/// `NotchContext.requestAttention(_:)` withdraws the request (the response is `.cancelled`).
public struct AttentionRequest {
    public var title: String
    public var message: String
    /// Glow and accent color.
    public var accent: Color
    /// Icon of the source (for example the app that asked), shown next to the title.
    public var sourceIcon: Image?
    public var buttons: [AttentionButton]
    public var choices: [AttentionChoices]
    public var textField: AttentionTextField?
    /// When set, the host offers an action with this title that hands the question back to the
    /// surface it came from (for example "터미널에서 답하기"); the response is then `.released`.
    public var releaseTitle: String?
    /// The response is `.timedOut` when the user has not answered within this time.
    public var timeout: Duration?

    public init(
        title: String,
        message: String,
        accent: Color = .accentColor,
        sourceIcon: Image? = nil,
        buttons: [AttentionButton] = [],
        choices: [AttentionChoices] = [],
        textField: AttentionTextField? = nil,
        releaseTitle: String? = nil,
        timeout: Duration? = nil
    ) {
        self.title = title
        self.message = message
        self.accent = accent
        self.sourceIcon = sourceIcon
        self.buttons = buttons
        self.choices = choices
        self.textField = textField
        self.releaseTitle = releaseTitle
        self.timeout = timeout
    }
}

public struct AttentionButton: Hashable, Sendable {
    public enum Role: Hashable, Sendable {
        case normal
        case primary
        case destructive
        case cancel
    }

    public let id: String
    public let title: String
    public let role: Role

    public init(id: String, title: String, role: Role = .normal) {
        self.id = id
        self.title = title
        self.role = role
    }
}

/// One question with options; the user picks one, or several when `allowsMultiple` is true.
public struct AttentionChoices: Hashable, Sendable {
    public let id: String
    public let prompt: String
    public let options: [String]
    public let allowsMultiple: Bool

    public init(id: String, prompt: String, options: [String], allowsMultiple: Bool = false) {
        self.id = id
        self.prompt = prompt
        self.options = options
        self.allowsMultiple = allowsMultiple
    }
}

/// A free-text field under the message.
public struct AttentionTextField: Hashable, Sendable {
    public let placeholder: String
    public let initialText: String

    public init(placeholder: String, initialText: String = "") {
        self.placeholder = placeholder
        self.initialText = initialText
    }
}

/// What the user submitted.
public struct AttentionAnswer: Hashable, Sendable {
    /// The button that submitted the answer, or nil when choosing an option submitted it directly.
    public let buttonID: String?
    /// Chosen option labels keyed by `AttentionChoices.id`.
    public let choices: [String: [String]]
    /// Text field contents, or nil when the request had no text field.
    public let text: String?

    public init(buttonID: String?, choices: [String: [String]] = [:], text: String? = nil) {
        self.buttonID = buttonID
        self.choices = choices
        self.text = text
    }
}

public enum AttentionResponse: Hashable, Sendable {
    /// The user answered in the notch.
    case answered(AttentionAnswer)
    /// The user chose to answer on the surface the request came from (see `releaseTitle`).
    case released
    /// The user closed the request without answering.
    case dismissed
    /// `timeout` elapsed without an answer.
    case timedOut
    /// The requesting task was cancelled, so the host withdrew the request.
    case cancelled
}
