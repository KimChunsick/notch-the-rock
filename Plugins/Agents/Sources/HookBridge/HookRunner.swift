import Darwin
import Foundation

/// What `notch-hook <event>` does, apart from the process plumbing: forwards Claude Code's input to
/// the Agents plugin and returns what to print. For a permission request or a question it waits
/// for the user's decision in the notch; for a notice it returns right after sending. It never
/// blocks Claude Code when the app is not running: when nothing listens on the socket it returns at
/// once with empty output, which Claude Code reads as "no decision".
public struct HookRunner: Sendable {
    public var socketPath: String
    public var environment: [String: String]
    public var readInput: @Sendable () -> Data
    public var findTerminal: @Sendable () -> TerminalLocation?

    public init(
        socketPath: String,
        environment: [String: String],
        readInput: @escaping @Sendable () -> Data,
        findTerminal: @escaping @Sendable () -> TerminalLocation?
    ) {
        self.socketPath = socketPath
        self.environment = environment
        self.readInput = readInput
        self.findTerminal = findTerminal
    }

    /// The bytes to print on stdout for `arguments` (`[<event>]`); always exit 0.
    public func run(arguments: [String]) -> Data {
        guard let name = arguments.first, let event = HookEvent(rawValue: name) else { return Data() }
        // Connect before reading stdin: when the app is not running the hook is done right away.
        guard let fd = HookSocket.connect(to: socketPath) else { return Data() }
        defer { close(fd) }
        guard let payload = HookWire.decode(JSONValue.self, from: readInput()), case .object = payload else { return Data() }
        // The installed matcher sends only AskUserQuestion; any other tool goes on untouched.
        if event == .preToolUse && payload["tool_name"]?.string != "AskUserQuestion" { return Data() }
        let message = HookMessage(
            event: event,
            payload: payload,
            context: HookContext(terminal: findTerminal(), projectDir: environment["CLAUDE_PROJECT_DIR"])
        )
        guard let line = try? HookWire.line(message) else { return Data() }
        guard HookSocket.write(line, to: fd), event.awaitsDecision else { return Data() }
        // Waits until the plugin answers or closes the connection (the user released the request,
        // it timed out, or the app quit). Claude Code's own hook timeout bounds the wait.
        guard let reply = HookSocket.readLine(from: fd),
              let response = HookWire.decode(HookResponse.self, from: reply) else { return Data() }
        return HookOutput.render(response.decision, for: message)
    }
}
