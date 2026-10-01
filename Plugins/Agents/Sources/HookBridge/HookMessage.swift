import Foundation

/// The Claude Code hook events the helper forwards; the raw value is both the event name Claude Code
/// uses and the argument the installed command passes to `notch-hook`.
public enum HookEvent: String, Codable, Sendable, CaseIterable {
    case sessionStart = "SessionStart"
    /// The user sent a prompt: the session starts working.
    case userPromptSubmit = "UserPromptSubmit"
    case stop = "Stop"
    case notification = "Notification"
    case permissionRequest = "PermissionRequest"
    /// Installed for `AskUserQuestion` only.
    case preToolUse = "PreToolUse"
    /// The session ended: it leaves the Agents screen.
    case sessionEnd = "SessionEnd"

    /// Whether the hook waits for the plugin's decision. The other events are notices: the hook
    /// returns as soon as it has sent them.
    public var awaitsDecision: Bool {
        self == .permissionRequest || self == .preToolUse
    }
}

/// The terminal app a Claude Code session runs in, found by walking up the hook's parent processes.
public struct TerminalLocation: Codable, Hashable, Sendable {
    /// Bundle identifier of the terminal app, e.g. `com.apple.Terminal`.
    public var bundleID: String
    /// The session's terminal device, e.g. `/dev/ttys004`, when an ancestor has one.
    public var tty: String?

    public init(bundleID: String, tty: String?) {
        self.bundleID = bundleID
        self.tty = tty
    }
}

/// What the helper adds to Claude Code's input: facts only the hook's process can see.
public struct HookContext: Codable, Hashable, Sendable {
    public var terminal: TerminalLocation?
    /// `CLAUDE_PROJECT_DIR` from the hook's environment: the folder the session started in.
    public var projectDir: String?
    /// The Claude Code process the hook runs for, when the helper found it. The session is over
    /// once this process is gone.
    public var claudePID: pid_t?

    public init(terminal: TerminalLocation?, projectDir: String?, claudePID: pid_t? = nil) {
        self.terminal = terminal
        self.projectDir = projectDir
        self.claudePID = claudePID
    }
}

/// The one message the helper sends per connection.
public struct HookMessage: Codable, Hashable, Sendable {
    public var event: HookEvent
    /// Claude Code's hook input (stdin JSON), unchanged.
    public var payload: JSONValue
    public var context: HookContext

    public init(event: HookEvent, payload: JSONValue, context: HookContext) {
        self.event = event
        self.payload = payload
        self.context = context
    }
}

/// What the user decided in the notch about a request the hook waits on.
public enum HookDecision: Codable, Hashable, Sendable {
    /// PermissionRequest: run the tool.
    case allow
    /// PermissionRequest: do not run it; `message` goes to Claude.
    case deny(message: String)
    /// AskUserQuestion: answers keyed by question text, each an option label, an array of labels
    /// (multiple choice) or typed text.
    case answers([String: JSONValue])
}

/// The plugin's one reply to a hook that waits. No decision (released, timed out, closed in the
/// notch) leaves the request to the terminal.
public struct HookResponse: Codable, Hashable, Sendable {
    public var decision: HookDecision?

    public init(decision: HookDecision?) {
        self.decision = decision
    }
}

/// Framing on the Agents socket: each direction carries at most one message, a single line of
/// compact JSON ended by `\n`. JSON escapes line breaks inside strings, so the first `\n` ends it.
public enum HookWire {
    /// Longer lines are refused. Claude Code's input can carry a whole file (a Write tool call).
    public static let maxLineLength = 8 << 20

    public static func line(_ value: some Encodable) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// The value in `line` (with or without its `\n`), or nil when it is not one.
    public static func decode<Value: Decodable>(_ type: Value.Type, from line: Data) -> Value? {
        try? JSONDecoder().decode(type, from: line)
    }
}
