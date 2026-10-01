import Darwin
import Foundation

/// What `notch-hook <event>` does, apart from the process plumbing: forwards Claude Code's input to
/// the Agents plugin and returns what to print. It never blocks Claude Code when the app is not
/// running: when nothing listens on the socket it returns at once with empty output, which Claude
/// Code reads as "no decision".
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
        let message = HookMessage(
            event: event,
            payload: payload,
            context: HookContext(terminal: findTerminal(), projectDir: environment["CLAUDE_PROJECT_DIR"])
        )
        guard let line = try? HookWire.line(message) else { return Data() }
        // Notifications need no answer: Claude Code goes on as soon as the hook exits.
        _ = HookSocket.write(line, to: fd)
        return Data()
    }
}
