import Darwin
import Foundation
import HookBridge
import Testing
@testable import Agents

func json(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

let ghostty = TerminalLocation(bundleID: "com.mitchellh.ghostty", tty: "/dev/ttys004")

/// A server on a fresh temporary socket that collects every message it accepts.
struct TestServer {
    let folder: String
    let path: String
    let server: HookServer
    let inbox = Inbox()
    let rejections = Inbox()

    init(peerUID: @escaping @Sendable (Int32) -> uid_t? = HookServer.peerUID(of:)) throws {
        (folder, path) = makeSocketPath()
        let inbox = inbox
        server = HookServer(path: path, peerUID: peerUID, log: { _ in }) { message in
            inbox.append(message)
        }
        try server.start()
    }

    func stop() {
        server.stop()
        try? FileManager.default.removeItem(atPath: folder)
    }

    func runner(input: String, terminal: TerminalLocation? = ghostty, environment: [String: String] = [:]) -> HookRunner {
        HookRunner(socketPath: path, environment: environment, readInput: { Data(input.utf8) }, findTerminal: { terminal })
    }
}

/// Runs the blocking hook off the main actor, as the helper process would.
func run(_ runner: HookRunner, _ arguments: [String]) async -> Data {
    await Task.detached { runner.run(arguments: arguments) }.value
}

@Suite struct HookBridgeTests {
    @Test func R05__hook_messages_reach_the_plugin_socket() async throws {
        let server = try TestServer()
        defer { server.stop() }
        let payloads: [(HookEvent, String)] = [
            (.sessionStart, #"{"session_id":"s1","cwd":"/Users/me/notch-the-rock","hook_event_name":"SessionStart","source":"startup"}"#),
            (.stop, #"{"session_id":"s1","cwd":"/Users/me/notch-the-rock","hook_event_name":"Stop","stop_reason":"end_turn","stop_hook_active":true}"#),
            (.notification, #"{"session_id":"s1","cwd":"/Users/me/notch-the-rock","hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting for your input","future_field":{"x":[1,2.5,null]}}"#),
        ]
        for (event, payload) in payloads {
            let output = await run(server.runner(input: payload, environment: ["CLAUDE_PROJECT_DIR": "/Users/me/notch-the-rock"]), [event.rawValue])
            #expect(output.isEmpty)
        }

        let received = await server.inbox.wait(for: 3)
        #expect(received.map(\.event) == [.sessionStart, .stop, .notification])
        for (message, (_, payload)) in zip(received, payloads) {
            #expect(message.payload == (try json(payload)))
            #expect(message.context.terminal == ghostty)
            #expect(message.context.projectDir == "/Users/me/notch-the-rock")
        }
        #expect(received.last?.payload["message"]?.string == "Claude is waiting for your input")
    }

    @Test func R05__unknown_events_and_unreadable_input_send_nothing() async throws {
        let server = try TestServer()
        defer { server.stop() }
        #expect(await run(server.runner(input: "{}"), ["Bogus"]).isEmpty)
        #expect(await run(server.runner(input: "{}"), []).isEmpty)
        #expect(await run(server.runner(input: "not json"), ["Stop"]).isEmpty)
        #expect(await run(server.runner(input: "[1]"), ["Stop"]).isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.inbox.all.isEmpty)
    }

    @Test func R05__socket_folder_and_socket_are_user_only() throws {
        let server = try TestServer()
        var info = stat()
        #expect(lstat(server.folder, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFDIR)
        #expect(info.st_mode & 0o777 == 0o700)
        #expect(lstat(server.path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFSOCK)
        #expect(info.st_mode & 0o777 == 0o600)
        server.stop()
        #expect(lstat(server.path, &info) != 0)
    }

    @Test func R05__a_connection_from_another_user_is_closed_unread() async throws {
        let server = try TestServer(peerUID: { _ in getuid() + 1 })
        defer { server.stop() }
        let output = await run(server.runner(input: #"{"session_id":"s1"}"#), ["Stop"])
        #expect(output.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.inbox.all.isEmpty)
    }

    @Test(arguments: [false, true])
    func R05__offline_hook_exits_at_once_with_empty_output(staleSocket: Bool) throws {
        let paths = makeSocketPath()
        defer { try? FileManager.default.removeItem(atPath: paths.folder) }
        if staleSocket {
            // A socket file nothing listens on, as after a crash of the app.
            try FileManager.default.createDirectory(atPath: paths.folder, withIntermediateDirectories: true)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = try #require(HookSocket.address(paths.socket))
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            #expect(bound == 0)
            close(fd)
        }
        let result = try runProcess(
            builtHook, ["Stop"],
            input: Data(#"{"session_id":"s1","hook_event_name":"Stop"}"#.utf8),
            environment: [HookSocket.pathEnvironmentKey: paths.socket]
        )
        print("R05 offline notch-hook (stale socket: \(staleSocket)): exit \(result.status), \(result.stdout.count) bytes on stdout, \(result.elapsed)")
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.elapsed < .seconds(1))
    }
}

/// A process table given as a dictionary.
struct FakeProcessTable: ProcessTable {
    let entries: [pid_t: ProcessEntry]
    func entry(for pid: pid_t) -> ProcessEntry? { entries[pid] }
}

@Suite struct TerminalFinderTests {
    static let apps = [
        "/Applications/Ghostty.app": "com.mitchellh.ghostty",
        "/System/Applications/Utilities/Terminal.app": "com.apple.Terminal",
        "/Applications/Visual Studio Code.app": "com.microsoft.VSCode",
        "/Applications/Other.app": "com.example.other",
    ]

    func finder(_ entries: [pid_t: ProcessEntry]) -> TerminalFinder {
        TerminalFinder(table: FakeProcessTable(entries: entries), bundleIdentifier: { Self.apps[$0] })
    }

    /// hook's shell (500) → claude (400) → login shell (300) → login (200) → `app` (100) → launchd.
    func chain(app: String, shellParent: String = "/usr/bin/login") -> [pid_t: ProcessEntry] {
        [
            500: ProcessEntry(parent: 400, tty: nil, executablePath: "/bin/sh"),
            400: ProcessEntry(parent: 300, tty: "/dev/ttys004", executablePath: "/Users/me/.local/share/claude/versions/2.1.286"),
            300: ProcessEntry(parent: 200, tty: "/dev/ttys004", executablePath: "/bin/zsh"),
            200: ProcessEntry(parent: 100, tty: "/dev/ttys004", executablePath: shellParent),
            100: ProcessEntry(parent: 1, tty: nil, executablePath: app),
            1: ProcessEntry(parent: 0, tty: nil, executablePath: "/sbin/launchd"),
        ]
    }

    @Test func R05__parent_walk_finds_the_terminal_app_and_tty() {
        #expect(finder(chain(app: "/Applications/Ghostty.app/Contents/MacOS/ghostty")).find(startingAt: 500) == ghostty)
        #expect(
            finder(chain(app: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")).find(startingAt: 500)
                == TerminalLocation(bundleID: "com.apple.Terminal", tty: "/dev/ttys004")
        )
        // VS Code's integrated terminal runs under a helper app nested in the main app.
        let code = "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
        #expect(
            finder(chain(app: "/sbin/launchd", shellParent: code)).find(startingAt: 500)
                == TerminalLocation(bundleID: "com.microsoft.VSCode", tty: "/dev/ttys004")
        )
    }

    @Test func R05__parent_walk_without_a_known_terminal_finds_nothing() {
        #expect(finder(chain(app: "/Applications/Other.app/Contents/MacOS/Other")).find(startingAt: 500) == nil)
        #expect(finder([:]).find(startingAt: 500) == nil)
        let loop: [pid_t: ProcessEntry] = [
            10: ProcessEntry(parent: 11, tty: nil, executablePath: "/bin/sh"),
            11: ProcessEntry(parent: 10, tty: nil, executablePath: "/bin/zsh"),
        ]
        #expect(finder(loop).find(startingAt: 10) == nil)
    }

    @Test func R05__system_process_table_reads_this_process() throws {
        let entry = try #require(SystemProcessTable().entry(for: getpid()))
        #expect(entry.parent == getppid())
        #expect(entry.executablePath?.isEmpty == false)
    }
}
