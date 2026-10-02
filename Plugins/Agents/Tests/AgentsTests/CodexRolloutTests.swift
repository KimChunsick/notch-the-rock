import Foundation
import HookBridge
import NotchKit
import SwiftUI
import Testing
@testable import Agents

/// A made-up `$CODEX_HOME/sessions` tree in a temporary folder.
struct RolloutTree {
    let root: URL

    init() throws {
        root = try makeDirectory("agents-rollouts").appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    }

    /// Today's folder, as codex names it: the watcher's fast passes look in recent date folders only.
    var day: URL { root.appendingPathComponent(Self.folder(Date())) }

    static func folder(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter.string(from: date)
    }

    func url(_ id: String, in folder: URL? = nil) -> URL { (folder ?? day).appendingPathComponent("rollout-2026-10-02T09-00-00-\(id).jsonl") }

    func write(_ id: String, _ lines: [String], modified: Date? = nil, in folder: URL? = nil) throws {
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url(id, in: folder))
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url(id, in: folder).path)
        }
    }

    func append(_ id: String, _ text: String, in folder: URL? = nil) throws {
        let handle = try FileHandle(forWritingTo: url(id, in: folder))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    static func meta(_ id: String, cwd: String, originator: String = "Codex Desktop", source: String = #""vscode""#, extra: String = "") -> String {
        #"{"timestamp":"2026-10-02T09:00:00.000Z","type":"session_meta","payload":{"id":"\#(id)","timestamp":"2026-10-02T09:00:00.000Z","cwd":"\#(cwd)","originator":"\#(originator)","cli_version":"0.153.4","source":\#(source)\#(extra)}}"#
    }

    static func event(_ type: String, turn: String) -> String {
        #"{"timestamp":"2026-10-02T09:01:00.000Z","type":"event_msg","payload":{"type":"\#(type)","turn_id":"\#(turn)"}}"#
    }
}

/// The processes the watcher looks at and the session list checks: `cli`, a `codex` process with every
/// rollout of the tree open but the `closed` sessions' and those `owners` gives to another process, and
/// the `others` that run, such as the desktop app and its app-server. A process that is gone has nothing
/// open.
@MainActor
final class FakeCodexProcesses {
    static let desktopApp: pid_t = 4000
    static let appServer: pid_t = 4010
    let tree: RolloutTree
    var cli: pid_t? = 4001
    var closed: Set<String> = []
    /// Sessions whose rollout a process other than `cli` has open, by session id.
    var owners: [String: pid_t] = [:]
    var others: Set<pid_t> = []

    init(tree: RolloutTree) {
        self.tree = tree
    }

    func isAlive(_ pid: pid_t) -> Bool { pid == cli || others.contains(pid) }

    func snapshot() -> CodexProcesses {
        var processes = CodexProcesses()
        guard let walker = FileManager.default.enumerator(atPath: tree.root.path) else { return processes }
        for case let name as String in walker where name.hasSuffix(".jsonl") && !closed.contains(where: { name.contains($0) }) {
            guard let holder = owners.first(where: { name.contains($0.key) })?.value ?? cli, isAlive(holder) else { continue }
            var info = stat()
            guard stat(tree.root.appendingPathComponent(name).path, &info) == 0 else { continue }
            processes.holders[CodexProcesses.File(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))] = holder
        }
        return processes
    }
}

@MainActor
@Suite struct CodexRolloutTests {
    static let desktop = "019b0000-0000-7000-8000-00000000d001"
    let host = FakeHost()
    let activator = FakeActivator()
    let outbox = Outbox()
    let clock = TestClock()
    let tree: RolloutTree
    let processes: FakeCodexProcesses
    /// The terminal of the TUI working in each folder, as the bridge and the watcher look it up.
    let terminals: FakeTerminals
    let bridge: CodexBridge
    let watcher: CodexRollouts

    init() throws {
        tree = try RolloutTree()
        processes = FakeCodexProcesses(tree: tree)
        let context = try makeContext(host: host, directory: try makeDirectory())
        let terminals = FakeTerminals(["/Users/me/notch-the-rock": ghostty, "/Users/me/rock-garden": ghostty])
        self.terminals = terminals
        let lookup: @MainActor (String?) -> TerminalLocation? = { cwd in cwd.flatMap { terminals.byFolder[$0] } }
        bridge = CodexBridge(context: context, activator: activator, terminal: lookup)
        watcher = CodexRollouts(
            root: tree.root, context: context, bridge: bridge, activator: activator, terminal: lookup,
            now: { [clock] in clock.now }, processes: processes.snapshot
        )
        bridge.screen.sessions.isAlive = processes.isAlive
        bridge.open { [outbox] in outbox.messages.append($0) }
    }

    var list: AgentSessionList { bridge.screen.sessions }

    func session(_ id: String) -> AgentSession? {
        list[AgentSession.Key(agent: .codex, id: id)]
    }

    /// One pass, waiting for the alerts it raised to be answered.
    func scan() async {
        for task in await watcher.scan() { await task.value }
    }

    @Test func R55__a_desktop_session_lists_and_alerts_once_per_finished_turn() async throws {
        await scan()
        try tree.write(Self.desktop, [RolloutTree.meta(Self.desktop, cwd: "/Users/me/tide-pool"), RolloutTree.event("task_started", turn: "t1")])
        await scan()
        let row = try #require(session(Self.desktop))
        #expect(row.folder == "tide-pool" && row.state == .working && row.terminal == CodexRollouts.desktopApp)

        try tree.append(Self.desktop, RolloutTree.event("task_complete", turn: "t1") + "\n")
        await scan()
        #expect(session(Self.desktop)?.state == .idle)
        #expect(host.requests.count == 1)
        let alert = try #require(host.requests.first)
        #expect(alert.title == "tide-pool" && alert.message == "Codex가 작업을 마쳤어요.")
        #expect(alert.buttons.map(\.title) == ["Codex 앱으로 이동"] && alert.timeout == .seconds(5))

        // Nothing new: no second alert. The next turn alerts once more.
        await scan()
        #expect(host.requests.count == 1)
        try tree.append(Self.desktop, RolloutTree.event("task_started", turn: "t2") + "\n")
        await scan()
        #expect(session(Self.desktop)?.state == .working)
        try tree.append(Self.desktop, RolloutTree.event("task_complete", turn: "t2") + "\n")
        await scan()
        #expect(host.requests.count == 2 && session(Self.desktop)?.state == .idle)

        // A stopped turn goes back to waiting without an alert.
        try tree.append(Self.desktop, [RolloutTree.event("task_started", turn: "t3"), RolloutTree.event("turn_aborted", turn: "t3")].map { $0 + "\n" }.joined())
        await scan()
        #expect(host.requests.count == 2 && session(Self.desktop)?.state == .idle)
    }

    @Test func R40__the_desktop_alert_jumps_to_the_desktop_app_and_folds_the_notch() async throws {
        await scan()
        try tree.write(Self.desktop, [RolloutTree.meta(Self.desktop, cwd: "/Users/me/tide-pool"), RolloutTree.event("task_started", turn: "t1")])
        await scan()
        host.responses = [.answered(AttentionAnswer(buttonID: CodexBridge.jumpButtonID, choices: [:], text: nil))]
        try tree.append(Self.desktop, RolloutTree.event("task_complete", turn: "t1") + "\n")
        await scan()
        #expect(activator.activated == [CodexRollouts.desktopApp])
        #expect(CodexRollouts.desktopApp.bundleID == "com.openai.codex" && host.collapses == 1 && host.expansions == 0)
    }

    @Test func R55__a_partial_line_waits_until_it_is_complete() async throws {
        await scan()
        try tree.write(Self.desktop, [RolloutTree.meta(Self.desktop, cwd: "/Users/me/tide-pool"), RolloutTree.event("task_started", turn: "t1")])
        await scan()
        let line = RolloutTree.event("task_complete", turn: "t1")
        let cut = line.index(line.startIndex, offsetBy: 30)
        try tree.append(Self.desktop, String(line[..<cut]))
        await scan()
        #expect(session(Self.desktop)?.state == .working && host.requests.isEmpty)
        try tree.append(Self.desktop, String(line[cut...]) + "\n")
        await scan()
        #expect(session(Self.desktop)?.state == .idle && host.requests.count == 1)
    }

    @Test func R55__a_restart_indexes_the_history_without_alerts() async throws {
        let hourAgo = Date(timeIntervalSinceNow: -3600).rounded
        let finished = "019b0000-0000-7000-8000-00000000d002"
        let old = "019b0000-0000-7000-8000-00000000d003"
        let ended = "019b0000-0000-7000-8000-00000000d004"
        try tree.write(finished, [RolloutTree.meta(finished, cwd: "/Users/me/tide-pool"), RolloutTree.event("task_started", turn: "t1"), RolloutTree.event("task_complete", turn: "t1")], modified: hourAgo)
        try tree.write(old, [RolloutTree.meta(old, cwd: "/Users/me/old-shell"), RolloutTree.event("task_started", turn: "t1")], modified: Date(timeIntervalSinceNow: -10 * 3600))
        try tree.write(ended, [RolloutTree.meta(ended, cwd: "/Users/me/done"), RolloutTree.event("task_complete", turn: "t1"), #"{"type":"event_msg","payload":{"type":"shutdown_complete"}}"#], modified: hourAgo)
        await scan()
        #expect(host.requests.isEmpty)
        #expect(list.sessions.map(\.id.id) == [finished])
        #expect(session(finished)?.state == .idle && session(finished)?.changed == hourAgo)

        // Followed from where the index left off: only what comes next alerts, the old file's included.
        try tree.append(finished, [RolloutTree.event("task_started", turn: "t2"), RolloutTree.event("task_complete", turn: "t2")].map { $0 + "\n" }.joined())
        try tree.append(old, RolloutTree.event("task_complete", turn: "t1") + "\n")
        await scan()
        #expect(Set(host.requests.map(\.title)) == ["tide-pool", "old-shell"] && host.requests.count == 2)
        #expect(session(old)?.folder == "old-shell" && session(old)?.state == .idle)
    }

    @Test func R55__a_thread_the_bridge_follows_alerts_once() async throws {
        await scan()
        bridge.receive(try codexFixture("initializeResponse"))
        bridge.receive(try codexFixture("loadedListPage1"))
        bridge.receive(try codexFixture("resumeResponse"))
        let followed = CodexBridgeTests.thread1
        let turn = "019a0000-0000-7000-8000-0000000000a1"
        try tree.write(followed, [RolloutTree.meta(followed, cwd: "/Users/me/notch-the-rock", originator: "codex_cli_rs", source: #""cli""#), RolloutTree.event("task_complete", turn: turn)])
        await scan()
        #expect(host.requests.isEmpty)
        await bridge.receive(try codexFixture("turnCompleted"))?.value
        #expect(host.requests.count == 1)

        // Seen in the rollout first, then by the bridge: the bridge's alert for that turn does not come.
        let other = "019a0000-0000-7000-8000-000000000005"
        try tree.write(other, [RolloutTree.meta(other, cwd: "/Users/me/rock-garden", originator: "codex_cli_rs", source: #""cli""#), RolloutTree.event("task_complete", turn: "turn-5")])
        await scan()
        #expect(host.requests.count == 2 && session(other)?.terminal == ghostty)
        bridge.receive(try jsonValue(#"{"method":"thread/started","params":{"thread":{"id":"\#(other)","cwd":"/Users/me/rock-garden"}}}"#))
        let late = bridge.receive(try jsonValue(#"{"method":"turn/completed","params":{"threadId":"\#(other)","turn":{"id":"turn-5","items":[],"status":"completed"}}}"#))
        #expect(late == nil && host.requests.count == 2)

        // The bridge's connection going away drops its own rows only.
        try tree.write(Self.desktop, [RolloutTree.meta(Self.desktop, cwd: "/Users/me/tide-pool")])
        await scan()
        bridge.close()
        #expect(list.sessions.map(\.id.id) == [Self.desktop])
    }

    /// A rollout row lasts as long as a process has its file open. Checked through the list the screen
    /// and the tile read, with the same `prune` the plugin runs every 10 s.
    @Test func R33__a_rollout_only_session_leaves_the_list_once_its_process_is_gone() async throws {
        // A TUI session from before the app started whose process already exited is history.
        let exited = "019b0000-0000-7000-8000-00000000f001"
        processes.closed = [exited]
        try tree.write(exited, Self.cli(exited, "old-shell"), modified: Date(timeIntervalSinceNow: -600))
        await scan()
        #expect(list.sessions.isEmpty)

        // A running TUI session lists with its process; a recent rollout no process has open does not.
        let running = "019b0000-0000-7000-8000-00000000f002"
        let stale = "019b0000-0000-7000-8000-00000000f003"
        processes.closed.insert(stale)
        try tree.write(running, Self.cli(running, "rock-garden"))
        try tree.write(stale, Self.cli(stale, "tide-pool"))
        await scan()
        #expect(list.sessions.map(\.id.id) == [running])
        #expect(session(running)?.pid == 4001 && session(running)?.state == .working && session(running)?.terminal == ghostty)
        list.prune()
        #expect(session(running) != nil)

        // Its process is killed without a shutdown record: one liveness check takes the row away.
        processes.cli = nil
        list.prune()
        #expect(list.sessions.isEmpty)
    }

    /// A desktop thread is listed while the desktop app's app-server has its rollout open, not merely
    /// while the app runs, and leaves on the first pass after the thread is unloaded.
    @Test func R33__a_desktop_thread_lists_only_while_the_app_server_has_it_open() async throws {
        processes.cli = nil
        processes.others = [FakeCodexProcesses.desktopApp, FakeCodexProcesses.appServer]
        await scan()
        // A recent thread the app no longer has loaded: the running app alone does not list it.
        let unloaded = "019b0000-0000-7000-8000-00000000f005"
        processes.closed = [unloaded]
        try tree.write(unloaded, [RolloutTree.meta(unloaded, cwd: "/Users/me/old-shell"), RolloutTree.event("task_started", turn: "t1")])
        await scan()
        #expect(list.sessions.isEmpty)

        // A loaded thread lists with the app-server that has its rollout open.
        processes.owners[Self.desktop] = FakeCodexProcesses.appServer
        try tree.write(Self.desktop, [RolloutTree.meta(Self.desktop, cwd: "/Users/me/tide-pool"), RolloutTree.event("task_started", turn: "t1")])
        await scan()
        #expect(list.sessions.map(\.id.id) == [Self.desktop])
        #expect(session(Self.desktop)?.pid == FakeCodexProcesses.appServer && session(Self.desktop)?.terminal == CodexRollouts.desktopApp)
        list.prune()
        #expect(session(Self.desktop) != nil)

        // Unloaded while the app and its app-server keep running: the next pass takes the row away.
        processes.closed.insert(Self.desktop)
        await scan()
        #expect(list.sessions.isEmpty)
        list.prune()
        await scan()
        #expect(list.sessions.isEmpty)
    }

    /// A TUI that closes its session's rollout (a new session in the same process) ends that session's row,
    /// though the process runs on.
    @Test func R33__a_session_whose_rollout_closes_leaves_while_its_process_runs() async throws {
        await scan()
        let closing = "019b0000-0000-7000-8000-00000000f006"
        try tree.write(closing, Self.cli(closing, "rock-garden"))
        await scan()
        #expect(session(closing)?.pid == 4001)

        processes.closed = [closing]
        await scan()
        #expect(processes.isAlive(4001) && list.sessions.isEmpty)
        list.prune()
        await scan()
        #expect(list.sessions.isEmpty)
    }

    /// A session resumed by another process before the next liveness check moves to that process and
    /// stays as long as it runs, though its file did not change.
    @Test func R33__a_resumed_session_moves_to_the_process_that_has_it_open_now() async throws {
        let first: pid_t = 5001, second: pid_t = 5002
        let resumed = "019b0000-0000-7000-8000-00000000f007"
        processes.cli = nil
        processes.others = [first]
        processes.owners[resumed] = first
        await scan()
        try tree.write(resumed, Self.cli(resumed, "rock-garden"))
        await scan()
        let row = try #require(session(resumed))
        #expect(row.pid == first && row.state == .working)

        // The first process exits and the second resumes the session before the list checks either.
        processes.others = [second]
        processes.owners[resumed] = second
        await scan()
        #expect(session(resumed)?.pid == second && session(resumed)?.state == .working && session(resumed)?.changed == row.changed)
        list.prune()
        #expect(session(resumed)?.pid == second)

        // Its next turn keeps it with the second process; it leaves once that one exits too.
        try tree.append(resumed, RolloutTree.event("task_complete", turn: "t1") + "\n")
        await scan()
        list.prune()
        #expect(session(resumed)?.pid == second && session(resumed)?.state == .idle)
        processes.others = []
        list.prune()
        #expect(list.sessions.isEmpty)
    }

    /// The liveness check may drop a resumed session before a pass sees its new process: the next pass
    /// lists it again as it was, with the new process, though its file did not change, and it stays.
    @Test func R33__a_session_pruned_before_a_pass_sees_its_new_process_comes_back() async throws {
        let first: pid_t = 5001, second: pid_t = 5002
        let resumed = "019b0000-0000-7000-8000-00000000f008"
        processes.cli = nil
        processes.others = [first]
        processes.owners[resumed] = first
        await scan()
        try tree.write(resumed, Self.cli(resumed, "rock-garden") + [ContextTests.tokenCount(last: 50_000, total: 50_000, window: "200000")])
        await scan()
        let row = try #require(session(resumed))
        #expect(row.pid == first && row.state == .working && row.contextPercent != nil)

        // The first process exits, the second opens the file, and the liveness check runs first.
        processes.others = [second]
        processes.owners[resumed] = second
        list.prune()
        #expect(list.sessions.isEmpty)
        for _ in 0..<3 {
            await scan()
            let back = try #require(session(resumed))
            #expect(back.pid == second && back.state == row.state && back.changed == row.changed)
            #expect(back.folder == row.folder && back.terminal == row.terminal && back.contextPercent == row.contextPercent)
            list.prune()
        }
        #expect(host.requests.isEmpty)

        // Once no process has it open, no pass brings it back.
        processes.others = []
        list.prune()
        for _ in 0..<3 {
            await scan()
            #expect(list.sessions.isEmpty)
        }
    }

    /// A session no process has open is not listed however many passes look at it; once a process opens
    /// it without writing to it, it lists as its records tell (here a turn they left open), without an alert.
    @Test func R33__a_rollout_nobody_has_open_is_listed_only_once_a_process_opens_it() async throws {
        let unheld = "019b0000-0000-7000-8000-00000000f009"
        let written = Date(timeIntervalSinceNow: -600).rounded
        processes.closed = [unheld]
        await scan()
        try tree.write(unheld, Self.cli(unheld, "tide-pool"), modified: written)
        for _ in 0..<3 {
            await scan()
            list.prune()
            #expect(list.sessions.isEmpty)
        }

        processes.closed = []
        await scan()
        let row = try #require(session(unheld))
        #expect(row.pid == 4001 && row.state == .working && row.changed > written && row.folder == "tide-pool")
        #expect(host.requests.isEmpty)
    }

    /// A turn that ends while no process has the session's rollout open, after the list dropped its row,
    /// is what the next process to open the file finds: the session comes back waiting, not working.
    @Test func R33__a_turn_that_ends_while_nobody_has_the_rollout_open_lists_again_idle() async throws {
        let first: pid_t = 5001, second: pid_t = 5002
        let resumed = "019b0000-0000-7000-8000-00000000f00a"
        processes.cli = nil
        processes.others = [first]
        processes.owners[resumed] = first
        await scan()
        try tree.write(resumed, Self.cli(resumed, "rock-garden"))
        await scan()
        #expect(session(resumed)?.state == .working)

        // The first process ends the turn and exits; the liveness check runs before the pass that reads the end.
        try tree.append(resumed, RolloutTree.event("task_complete", turn: "t1") + "\n")
        processes.others = []
        list.prune()
        await scan()
        #expect(list.sessions.isEmpty)
        let alerts = host.requests.count

        // A second process opens the file without writing to it.
        processes.others = [second]
        processes.owners[resumed] = second
        for _ in 0..<3 {
            await scan()
            let row = try #require(session(resumed))
            #expect(row.pid == second && row.state == .idle)
            list.prune()
        }
        #expect(host.requests.count == alerts)
    }

    /// What the rollout of a thread the bridge follows tells is kept: once the bridge's connection goes
    /// away while a process still has the rollout open, the watcher lists the thread with its turn as it is.
    @Test func R33__a_thread_the_bridge_let_go_lists_as_its_rollout_tells() async throws {
        await scan()
        bridge.receive(try codexFixture("initializeResponse"))
        bridge.receive(try codexFixture("loadedListPage1"))
        bridge.receive(try codexFixture("resumeResponse"))
        let followed = CodexBridgeTests.thread1
        try tree.write(followed, [RolloutTree.meta(followed, cwd: "/Users/me/notch-the-rock", originator: "codex_cli_rs", source: #""cli""#), RolloutTree.event("task_started", turn: "t1")])
        await scan()
        #expect(bridge.owns(followed))

        bridge.close()
        await scan()
        let row = try #require(session(followed))
        #expect(row.pid == 4001 && row.state == .working && row.folder == "notch-the-rock")
        #expect(host.requests.isEmpty)
    }

    /// A session another process takes over goes with it to that process's terminal: its row and its next
    /// alert, whether the row moved before the liveness check or the session was listed again after it.
    @Test func R33__a_session_another_process_takes_over_goes_to_that_process_terminal() async throws {
        let first: pid_t = 5001, second: pid_t = 5002, third: pid_t = 5003
        let terminal = TerminalLocation(bundleID: "com.apple.Terminal", tty: "/dev/ttys001")
        let vscode = TerminalLocation(bundleID: "com.microsoft.VSCode", tty: "/dev/ttys002")
        let jump = AttentionResponse.answered(AttentionAnswer(buttonID: CodexBridge.jumpButtonID, choices: [:], text: nil))
        let resumed = "019b0000-0000-7000-8000-00000000f00b"
        processes.cli = nil
        processes.others = [first]
        processes.owners[resumed] = first
        terminals.byFolder["/Users/me/tide-pool"] = terminal
        await scan()
        try tree.write(resumed, Self.cli(resumed, "tide-pool"))
        await scan()
        #expect(session(resumed)?.terminal == terminal)

        // A second process in another terminal resumes it before the list checks the first.
        processes.others = [second]
        processes.owners[resumed] = second
        terminals.byFolder["/Users/me/tide-pool"] = ghostty
        await scan()
        #expect(session(resumed)?.pid == second && session(resumed)?.terminal == ghostty)
        host.responses = [jump]
        try tree.append(resumed, RolloutTree.event("task_complete", turn: "t1") + "\n")
        await scan()
        #expect(host.requests.count == 1 && activator.activated == [ghostty])

        // A third one, in yet another terminal, opens it after the list dropped it.
        processes.others = [third]
        processes.owners[resumed] = third
        terminals.byFolder["/Users/me/tide-pool"] = vscode
        list.prune()
        #expect(list.sessions.isEmpty)
        await scan()
        #expect(session(resumed)?.pid == third && session(resumed)?.terminal == vscode)
        host.responses = [jump]
        try tree.append(resumed, [RolloutTree.event("task_started", turn: "t2"), RolloutTree.event("task_complete", turn: "t2")].map { $0 + "\n" }.joined())
        await scan()
        #expect(host.requests.count == 2 && activator.activated == [ghostty, vscode])
    }

    static func cli(_ id: String, _ folder: String) -> [String] {
        [RolloutTree.meta(id, cwd: "/Users/me/\(folder)", originator: "codex_cli_rs", source: #""cli""#), RolloutTree.event("task_started", turn: "t1")]
    }

    @Test func R55__exec_and_subagent_sessions_are_ignored() async throws {
        await scan()
        let exec = "019b0000-0000-7000-8000-00000000e001"
        let subagent = "019b0000-0000-7000-8000-00000000e002"
        try tree.write(exec, [RolloutTree.meta(exec, cwd: "/Users/me/tide-pool", source: #""exec""#), RolloutTree.event("task_started", turn: "t1"), RolloutTree.event("task_complete", turn: "t1")])
        try tree.write(subagent, [
            RolloutTree.meta(subagent, cwd: "/Users/me/tide-pool", source: #"{"subagent":{"thread_spawn":{"parent_thread_id":"\#(Self.desktop)","depth":1}}}"#, extra: #","parent_thread_id":"\#(Self.desktop)""#),
            RolloutTree.event("task_started", turn: "t1"), RolloutTree.event("task_complete", turn: "t1"),
        ])
        await scan()
        #expect(list.sessions.isEmpty && host.requests.isEmpty)
    }
}

/// The terminal each folder's TUI runs in; a test moves a folder to another terminal.
@MainActor
final class FakeTerminals {
    var byFolder: [String: TerminalLocation]

    init(_ byFolder: [String: TerminalLocation]) {
        self.byFolder = byFolder
    }
}

/// The watcher's clock: now, moved on by `offset`.
final class TestClock {
    var offset: TimeInterval = 0
    var now: Date { Date().addingTimeInterval(offset) }
}

extension Date {
    /// Whole seconds, as a file's modification date keeps them.
    var rounded: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded()) }
}
