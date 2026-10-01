import Foundation

/// What `notch-hook` prints for Claude Code: the `hookSpecificOutput` object of the hooks reference,
/// or nothing. Empty output with exit 0 means "no decision", so Claude Code goes on in the terminal.
public enum HookOutput {
    public static func render(_ decision: HookDecision?, for message: HookMessage) -> Data {
        let output: [String: JSONValue]
        switch (message.event, decision) {
        case (.permissionRequest, .allow):
            output = [
                "hookEventName": .string("PermissionRequest"),
                "decision": .object(["behavior": .string("allow")]),
            ]
        case (.permissionRequest, .deny(let text)):
            output = [
                "hookEventName": .string("PermissionRequest"),
                "decision": .object(["behavior": .string("deny"), "message": .string(text)]),
            ]
        case (.preToolUse, .answers(let answers)):
            // The tool's own input, questions included, unchanged, with the answers added.
            guard case .object(var input) = message.payload["tool_input"] ?? .null else { return Data() }
            input["answers"] = .object(answers)
            output = [
                "hookEventName": .string("PreToolUse"),
                "permissionDecision": .string("allow"),
                "updatedInput": .object(input),
            ]
        default:
            return Data()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(JSONValue.object(["hookSpecificOutput": .object(output)]))) ?? Data()
    }
}
