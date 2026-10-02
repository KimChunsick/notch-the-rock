import Darwin
import Foundation
import HookBridge
import NotchKit
import SwiftUI

/// Follows codex sessions through their rollout files (`$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`)
/// for the sessions the app-server bridge does not follow: the Codex desktop app runs its own
/// app-server over a private pipe, and a TUI may run without the shared one. Read only. codex appends
/// one JSON record per line; the watcher keeps each file's identity and the offset after its last
/// complete line, so a line still being written is read once it ends. Only what codex persists is
/// known: a turn starting (working), finishing (idle, with an alert) and being stopped (idle), and the
/// context use codex counted (`token_count`). A line longer than `RolloutReader.lineLimit` is skipped,
/// but a file's session is taken from the leading bytes of its first line however long it is, before
/// the records after it; what is read before the session is known waits for it. Requests for approval or input and errors are not persisted, so these rows never wait.
///
/// The first pass after `start` indexes the files without alerts, reading only the end of each file
/// written within `recentWindow`, and only those sessions get a row. Later passes look every
/// `interval` at the files written within `recentWindow` and the recent date folders only; the whole
/// tree is walked again every `discoveryInterval`. Exec runs and subagents are skipped. A thread the
/// bridge follows is left to it and a turn alerts once whichever of the two sees it end first, while
/// the row always takes the state the records tell. A thread the bridge closed stays closed whatever
/// is read of it later; a rollout that ended comes back only with a new turn. A session is listed only
/// while a process has its rollout open (`CodexProcesses`), the desktop app's threads too: every pass
/// gives each row the process that has its file open now, takes away the rows none has open and lists
/// again the sessions a process has open but the list dropped, whether or not their files changed. What
/// each session's records tell is kept whether or not it is listed, a process has its file open or the
/// bridge follows it, so a session listed again shows its turn as it is; a session given to another
/// process takes that process's terminal, for its row and its alerts. That terminal is the app the
/// process runs under, traced through its ancestors, so another TUI in the same folder does not hide it;
/// the folder's TUI is looked up only when the ancestors lead to no terminal. A terminal found through
/// the ancestors stays while that process has the session; one found by the folder, or none, is looked
/// up again every pass, and the process's own replaces it once found. A pass traces each process and
/// lists the `codex` processes at most once, however many records it reads.
@MainActor
final class CodexRollouts {
    static let interval: Duration = .seconds(2)
    static let recentWindow: TimeInterval = 3 * 60 * 60
    static let discoveryInterval: TimeInterval = 60
    /// How many records of a file wait for its session at most; the oldest go first.
    static let queueLimit = 64
    /// The Codex desktop app (`/Applications/ChatGPT.app`): its sessions' rows and alerts bring it forward.
    static let desktopApp = TerminalLocation(bundleID: "com.openai.codex", tty: nil)

    private let root: URL
    private let context: NotchContext
    private let bridge: CodexBridge
    private let activator: any TerminalActivating
    /// The terminal app a process runs under, found through its ancestors (`TerminalFinder`).
    private let processTerminal: @MainActor (pid_t) -> TerminalLocation?
    /// The `codex` processes running now with their working folders: a session whose process's own
    /// terminal is not found goes to the terminal of the TUI working in its folder.
    private let codexProcesses: @MainActor () -> [CodexProcess]
    private let logos: (any AgentLogoProviding)?
    private let now: () -> Date
    private let processes: @MainActor () -> CodexProcesses
    /// What `processes` gave in the current pass; looked at once, by the first session or row that needs it.
    private var running: CodexProcesses?
    /// The terminal each process traced in the current pass runs under, nil when none was found.
    private var traced: [pid_t: TerminalLocation?] = [:]
    /// What `codexProcesses` gave in the current pass; listed once, by the first session that needs it.
    private var tuis: [CodexProcess]?

    private var files: [String: Watched] = [:]
    /// What each session's records told last, by session id, whether or not it is listed, a process has
    /// its rollout open or the bridge follows it: a session the list takes again shows it.
    private var told: [String: Told] = [:]
    /// Where each session's row and alerts take the user, by session id: looked up for the process its
    /// row was given last.
    private var targets: [String: Destination] = [:]
    /// The sessions this watcher put on the list.
    private var listed: Set<String> = []
    /// Sessions whose rollout ended (`shutdown_complete`): only a new turn brings one back.
    private var ended = RecentIDs(capacity: CodexBridge.remembered)
    private var indexed = false
    /// When the whole tree was last walked.
    private var discovered: Date?
    /// Bumped by `stop`, so a pass that began before it changes nothing.
    private var generation = 0
    private var polling: Task<Void, Never>?
    private var notices: [String: (id: Int, task: Task<Void, Never>)] = [:]
    private var noticeCount = 0

    private struct Watched {
        var file: RolloutFile
        /// The file's session, once its `session_meta` line was read.
        var meta: RolloutMeta?
        /// What was read before `meta`, in order, each with its history date (nil when read live).
        var queued: [(record: RolloutRecord, at: Date?)] = []
        /// When the file was last seen written.
        var modified: Date
    }

    /// Where a session's row and alerts take the user, looked up for `pid`, the process that has it, and
    /// how it was found.
    private struct Destination: Equatable {
        enum Source: Equatable {
            /// The desktop app for its sessions, or the terminal app the process runs under, traced through
            /// its ancestors: kept while the process has the session.
            case process
            /// The one terminal of the TUIs working in the session's folder: looked up again every pass.
            case folder
            /// Nothing found: looked up again every pass.
            case none
        }

        let pid: pid_t
        let terminal: TerminalLocation?
        let source: Source
    }

    /// A session as its records tell it: its state, when that last changed and its context use.
    private struct Told {
        var state: AgentSessionState
        var changed: Date
        var contextPercent: Int?
    }

    init(
        root: URL,
        context: NotchContext,
        bridge: CodexBridge,
        activator: any TerminalActivating,
        processTerminal: @escaping @MainActor (pid_t) -> TerminalLocation? = { TerminalFinder.system.find(startingAt: $0) },
        codexProcesses: @escaping @MainActor () -> [CodexProcess] = CodexTerminals.systemProcesses,
        logos: (any AgentLogoProviding)? = nil,
        now: @escaping () -> Date = { .now },
        processes: @escaping @MainActor () -> CodexProcesses = CodexProcesses.system
    ) {
        self.root = root
        self.context = context
        self.bridge = bridge
        self.activator = activator
        self.processTerminal = processTerminal
        self.codexProcesses = codexProcesses
        self.logos = logos
        self.now = now
        self.processes = processes
    }

    private var list: AgentSessionList { bridge.screen.sessions }

    /// Indexes the files, then follows them every `interval`.
    func start() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard await self?.scan() != nil else { return }
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    /// Forgets the files and takes this watcher's rows and alerts away; the next `start` indexes again.
    func stop() {
        polling?.cancel()
        polling = nil
        generation += 1
        indexed = false
        discovered = nil
        files.removeAll()
        ended = RecentIDs(capacity: CodexBridge.remembered)
        for session in listed where !bridge.owns(session) {
            list.remove(AgentSession.Key(agent: .codex, id: session))
        }
        listed.removeAll()
        told.removeAll()
        targets.removeAll()
        for notice in notices.values {
            notice.task.cancel()
        }
        notices.removeAll()
    }

    /// One pass; the first indexes without alerts. Returns the alerts it raised.
    @discardableResult
    func scan() async -> [Task<Void, Never>] {
        let generation = generation
        let indexing = !indexed
        let started = now()
        let since = indexing ? started.addingTimeInterval(-Self.recentWindow) : nil
        let discovering = discovered.map { started.timeIntervalSince($0) >= Self.discoveryInterval } ?? true
        let recent = started.addingTimeInterval(-Self.recentWindow)
        let scope: RolloutScope = discovering ? .everything : .recent(now: started, active: files.filter { $0.value.modified >= recent }.map(\.key))
        let known = files.mapValues(\.file)
        let headless = Set(files.filter { $0.value.meta == nil }.keys)
        let root = root
        let reads = await Task.detached(priority: .utility) {
            RolloutReader.collect(root: root, scope: scope, known: known, headless: headless, since: since)
        }.value
        guard generation == self.generation else { return [] }
        indexed = true
        defer {
            running = nil
            traced.removeAll()
            tuis = nil
        }
        if discovering { discovered = started }
        var alerts: [Task<Void, Never>] = []
        for read in reads {
            var watched = files[read.path] ?? Watched(file: read.file, modified: read.modified)
            watched.modified = read.modified
            // A replaced or shortened file is read again from its start, as history.
            let silent = indexing || read.restarted
            if read.restarted {
                watched.meta = nil
                watched.queued.removeAll()
            }
            watched.file = read.file
            let date = silent ? read.modified : nil
            for record in read.records {
                if case .meta(let meta) = record {
                    guard watched.meta == nil else { continue }
                    watched.meta = meta
                    remember(record, meta, at: date)
                    show(meta, in: watched.file)
                    // What waited for the session, each as it was read: history stays silent.
                    for (queued, at) in watched.queued {
                        if let alert = apply(queued, meta, silent: at != nil, at: at, in: watched.file) { alerts.append(alert) }
                    }
                    watched.queued.removeAll()
                    continue
                }
                guard let meta = watched.meta else {
                    watched.queued.append((record, date))
                    if watched.queued.count > Self.queueLimit { watched.queued.removeFirst() }
                    continue
                }
                if let alert = apply(record, meta, silent: silent, at: date, in: watched.file) {
                    alerts.append(alert)
                }
            }
            files[read.path] = watched
        }
        reconcile()
        return alerts
    }

    /// Makes this watcher's rows the sessions whose rollouts processes have open now, whichever ran first,
    /// this pass or the list's liveness check, and whether or not the files changed. A row moves to the
    /// process that has its file open (a session resumed in another process), and leaves at once when
    /// none has it (a TUI that moved on to a new session, a desktop thread the app unloaded), even while
    /// the process that had it runs on. A session a process has open without a row is listed again as its
    /// records tell it (the liveness check dropped it before a pass saw its new process, or the bridge let
    /// it go), with no alert. A session the bridge follows or closed is the bridge's; one that ended comes
    /// back only with a new turn.
    private func reconcile() {
        let candidates = files.values.filter { $0.meta.map { follows($0) && !ended.contains($0.id) } ?? false }
        let rows = listed.filter { !bridge.owns($0) && !bridge.isClosed($0) }
        guard !candidates.isEmpty || !rows.isEmpty else { return }
        if running == nil { running = processes() }
        var holders: [String: (pid: pid_t, meta: RolloutMeta)] = [:]
        for watched in candidates {
            guard let meta = watched.meta, holders[meta.id] == nil, let pid = running?.holder(of: watched.file) else { continue }
            holders[meta.id] = (pid, meta)
        }
        for session in rows where holders[session] == nil {
            list.remove(AgentSession.Key(agent: .codex, id: session))
            listed.remove(session)
        }
        for holder in holders.values {
            hold(holder.meta, by: holder.pid)
        }
    }

    private func apply(_ record: RolloutRecord, _ meta: RolloutMeta, silent: Bool, at date: Date?, in file: RolloutFile) -> Task<Void, Never>? {
        remember(record, meta, at: date)
        guard follows(meta) else { return nil }
        if ended.contains(meta.id) {
            // Resumed: a new turn brings an ended session back. Nothing else does.
            guard case .started = record else { return nil }
            ended.remove(meta.id)
        }
        switch record {
        case .meta:
            return nil
        case .started, .aborted:
            show(meta, in: file)
        case .completed(let turn):
            // The row is idle either way; only the alert is once per turn, here or in the bridge.
            show(meta, in: file)
            guard !silent, bridge.claimTurnAlert(meta.id, turn: turn) else { return nil }
            return notify(meta)
        case .ended:
            ended.insert(meta.id)
            list.remove(AgentSession.Key(agent: .codex, id: meta.id))
            listed.remove(meta.id)
        case .context(let percent):
            list.setContext(AgentSession.Key(agent: .codex, id: meta.id), percent)
        }
        return nil
    }

    /// Keeps what `record` tells of `meta`'s session, read at `date` (nil: now), whether or not it is
    /// listed, a process has its rollout open or the bridge follows it. A session first told of is idle.
    private func remember(_ record: RolloutRecord, _ meta: RolloutMeta, at date: Date?) {
        guard !meta.ignored else { return }
        let state: AgentSessionState?
        switch record {
        case .meta: state = nil
        case .started: state = .working
        case .completed, .aborted: state = .idle
        case .ended: return
        case .context(let percent):
            told[meta.id]?.contextPercent = percent
            return
        }
        let previous = told[meta.id]
        // The list's clock, as the row would take the event without a date.
        told[meta.id] = Told(state: state ?? previous?.state ?? .idle, changed: date ?? list.now(), contextPercent: previous?.contextPercent)
    }

    /// Brings the session's row to what its records tell and gives it the process that has `file` open,
    /// if one has. A session joins the list only while a process has `file` open, and its row keeps that
    /// process, so it leaves once the process is gone even without a `shutdown_complete`.
    private func show(_ meta: RolloutMeta, in file: RolloutFile) {
        guard follows(meta), !ended.contains(meta.id), let told = told[meta.id] else { return }
        let key = AgentSession.Key(agent: .codex, id: meta.id)
        if list[key] != nil {
            list.update(key, folder: meta.folder, state: told.state, changed: told.changed)
        }
        if running == nil { running = processes() }
        if let pid = running?.holder(of: file) { hold(meta, by: pid) }
    }

    /// Gives `meta`'s session to `pid`, the process that has its rollout open now: lists it as its records
    /// tell it when it is not listed, or moves its row when another process had it. Either way its row and
    /// its alerts take the user to that process's terminal from then on. Until that terminal is found
    /// through the process's ancestors, every pass looks for it again, and its row and alerts go to what is
    /// found; a look that finds nothing leaves them where they are.
    private func hold(_ meta: RolloutMeta, by pid: pid_t) {
        let key = AgentSession.Key(agent: .codex, id: meta.id)
        if let row = list[key] {
            if row.pid != pid {
                list.setProcess(key, pid, terminal: retarget(meta, for: pid))
                return
            }
            if let kept = targets[meta.id], kept.pid == pid, kept.source == .process { return }
            let found = destination(meta, for: pid)
            guard let terminal = found.terminal, found != targets[meta.id] else { return }
            targets[meta.id] = found
            list.setProcess(key, pid, terminal: terminal)
            return
        }
        let told = told[meta.id]
        list.update(key, folder: meta.folder, state: told?.state, terminal: retarget(meta, for: pid), pid: pid, changed: told?.changed)
        list.setContext(key, told?.contextPercent)
        listed.insert(meta.id)
    }

    /// Looks up again where the session's row and alerts take the user, for `pid`, the process that has it
    /// now, and keeps it for its alerts.
    private func retarget(_ meta: RolloutMeta, for pid: pid_t) -> TerminalLocation? {
        let found = destination(meta, for: pid)
        targets[meta.id] = found
        return found.terminal
    }

    /// Where the session goes for `pid`: the desktop app for its sessions, otherwise the terminal app that
    /// process runs under, or, when its ancestors lead to none, the one terminal of the TUIs working in the
    /// session's folder.
    private func destination(_ meta: RolloutMeta, for pid: pid_t) -> Destination {
        if meta.desktop { return Destination(pid: pid, terminal: Self.desktopApp, source: .process) }
        if let found = trace(pid) { return Destination(pid: pid, terminal: found, source: .process) }
        guard let cwd = meta.cwd else { return Destination(pid: pid, terminal: nil, source: .none) }
        if tuis == nil { tuis = codexProcesses() }
        let found = CodexTerminals.terminal(forCwd: cwd, processes: tuis ?? []) { trace($0) }
        return Destination(pid: pid, terminal: found, source: found == nil ? .none : .folder)
    }

    /// The terminal app `pid` runs under, traced once a pass.
    private func trace(_ pid: pid_t) -> TerminalLocation? {
        if let known = traced[pid] { return known }
        let found = processTerminal(pid)
        traced[pid] = .some(found)
        return found
    }

    /// A session this watcher keeps: not an exec run or subagent, not followed by the bridge and not
    /// closed there.
    private func follows(_ meta: RolloutMeta) -> Bool {
        !meta.ignored && !bridge.owns(meta.id) && !bridge.isClosed(meta.id)
    }

    /// The bridge's alert for a finished turn; a desktop session's takes the user to the desktop app.
    private func notify(_ meta: RolloutMeta) -> Task<Void, Never> {
        let session = meta.id
        notices[session]?.task.cancel()
        noticeCount += 1
        let id = noticeCount
        let target = targets[session]?.terminal
        let request = AttentionRequest(
            title: meta.folder,
            message: "Codex가 작업을 마쳤어요.",
            accent: CodexBridge.accent,
            sourceIcon: AgentKind.codex.alertIcon(logos),
            buttons: [AttentionButton(
                id: CodexBridge.jumpButtonID,
                title: CodexBridge.jumpTitle(target),
                role: .primary
            )],
            timeout: ClaudeBridge.noticeTimeout
        )
        let task = Task { [context] in
            let response = await context.requestAttention(request)
            if case .answered(let answer) = response, answer.buttonID == CodexBridge.jumpButtonID {
                self.jump(to: target)
            }
            if self.notices[session]?.id == id {
                self.notices[session] = nil
            }
        }
        notices[session] = (id, task)
        return task
    }

    private func jump(to target: TerminalLocation?) {
        if let target, activator.jump(to: target, collapsing: context) { return }
        context.expand()
    }
}

/// A rollout's `session_meta`: whose session the file is and where it came from.
struct RolloutMeta: Equatable, Sendable {
    let id: String
    let cwd: String?
    /// Started by the Codex desktop app.
    let desktop: Bool
    /// An exec run or a subagent: never listed.
    let ignored: Bool

    var folder: String {
        guard let cwd, !cwd.isEmpty else { return "Codex" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
}

/// What the watcher acts on in one rollout line.
enum RolloutRecord: Equatable, Sendable {
    case meta(RolloutMeta)
    case started(turn: String?)
    case completed(turn: String?)
    case aborted(turn: String?)
    case ended
    /// How full the context window is, in percent (`token_count` with usage); nil when its counts or
    /// window are unknown, which clears the row's percent.
    case context(Int?)
}

/// Where the watcher stopped reading a file.
struct RolloutFile: Equatable, Sendable {
    var device: UInt64
    var inode: UInt64
    /// The byte after the last complete line read, or after the part read of a line too long to keep.
    var offset: UInt64
    /// `offset` is inside a line longer than `RolloutReader.lineLimit`: the next read drops the rest of it.
    var skipping = false
}

/// The processes that have rollouts open now. A row takes the process that has its session's rollout
/// open and leaves the list once that process is gone (`AgentSessionList.prune`) or has closed the file
/// (`CodexRollouts`), until a process has the file open again; a session no process has open is history,
/// not an open session, and gets no row.
/// The desktop app running is not enough: its app-server has open only the threads it has loaded.
struct CodexProcesses {
    /// A file by its device and inode, as `stat` and the kernel's table of open files give them: the
    /// path a process opened it by may differ from the one the watcher walks.
    struct File: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    /// The `codex` process that has each file open. codex keeps a session's rollout open while the
    /// session is loaded, in the TUI and in an app-server (the desktop app's own included) alike.
    var holders: [File: pid_t] = [:]

    /// The `codex` process that has `file` open; nil when none has.
    func holder(of file: RolloutFile) -> pid_t? {
        holders[File(device: file.device, inode: file.inode)]
    }

    /// This Mac's, read only: the files the user's `codex` processes have open.
    static func system() -> CodexProcesses {
        var processes = CodexProcesses()
        for pid in systemPIDs() {
            for file in openFiles(pid) {
                processes.holders[file] = pid
            }
        }
        return processes
    }

    /// The user's processes whose executable is named `codex`, read with `proc_listallpids` and
    /// `proc_pidpath`.
    static func systemPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let listed = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard listed > 0 else { return [] }
        return pids.prefix(Int(listed)).filter { pid in
            guard pid > 0 else { return false }
            var path = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
            let length = proc_pidpath(pid, &path, UInt32(path.count))
            guard length > 0 else { return false }
            let executable = String(decoding: path.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return (executable as NSString).lastPathComponent == "codex"
        }
    }

    /// The files `pid` has open, read with `PROC_PIDLISTFDS` and `PROC_PIDFDVNODEINFO`.
    static func openFiles(_ pid: pid_t) -> [File] {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard filled > 0 else { return [] }
        return fds.prefix(Int(filled) / stride).compactMap { fd in
            guard fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { return nil }
            var info = vnode_fdinfo()
            let size = Int32(MemoryLayout<vnode_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEINFO, &info, size) == size else { return nil }
            return File(device: UInt64(info.pvi.vi_stat.vst_dev), inode: info.pvi.vi_stat.vst_ino)
        }
    }
}

/// What changed in one file since the last pass.
struct RolloutRead: Sendable {
    let path: String
    let file: RolloutFile
    let records: [RolloutRecord]
    let modified: Date
    /// A known file replaced or cut short, read again from its start.
    let restarted: Bool
}

/// Which files a pass looks at.
enum RolloutScope: Sendable {
    /// The whole tree.
    case everything
    /// The date folders of `now` and the day before, and the `active` files.
    case recent(now: Date, active: [String])
}

/// The file side of `CodexRollouts`, off the main actor.
enum RolloutReader {
    static let originatorDesktop = "Codex Desktop"
    /// Lines without any of these are not decoded.
    static let markers = ["\"session_meta\"", "\"task_started\"", "\"task_complete\"", "\"turn_aborted\"", "\"shutdown_complete\"", "\"token_count\""]
        .map { Data($0.utf8) }

    /// How much of a file one read takes.
    static let chunkSize = 256 << 10
    /// The longest line kept; a longer one is skipped up to its end. Event lines are a few hundred bytes.
    static let lineLimit = 1 << 20
    static let newline = UInt8(ascii: "\n")

    /// The rollout files in `scope` that changed since `known`. With `since` (the indexing pass), a file
    /// not written since then is only remembered at its end. `headless` files are read from their first
    /// line as well, for the session they belong to.
    static func collect(root: URL, scope: RolloutScope, known: [String: RolloutFile], headless: Set<String>, since: Date?) -> [RolloutRead] {
        paths(root: root, scope: scope).compactMap { read($0, known: known[$0], head: headless.contains($0), since: since) }
    }

    /// The whole tree's rollout files, or only those in the recent date folders and the active ones.
    static func paths(root: URL, scope: RolloutScope) -> [String] {
        let rollout = { (name: String) in name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") }
        switch scope {
        case .everything:
            // Paths under `root` as given, like the recent folders': the walker's own URLs may resolve its links.
            guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
            return walker.compactMap { ($0 as? String).flatMap { rollout(($0 as NSString).lastPathComponent) ? root.appendingPathComponent($0).path : nil } }
        case .recent(let now, let active):
            var seen = Set(active)
            var paths = active
            for folder in recentFolders(now) {
                let directory = root.appendingPathComponent(folder)
                for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where rollout(name) {
                    let path = directory.appendingPathComponent(name).path
                    if seen.insert(path).inserted { paths.append(path) }
                }
            }
            return paths
        }
    }

    /// codex's date folders (`YYYY/MM/DD`) for today and yesterday, in the local time zone and in UTC.
    static func recentFolders(_ now: Date) -> [String] {
        var folders: [String] = []
        for zone in [TimeZone.current, TimeZone(identifier: "UTC")!] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            for date in [now, now.addingTimeInterval(-24 * 60 * 60)] {
                let day = calendar.dateComponents([.year, .month, .day], from: date)
                let folder = String(format: "%04d/%02d/%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
                if !folders.contains(folder) { folders.append(folder) }
            }
        }
        return folders
    }

    static func read(_ path: String, known: RolloutFile?, head: Bool, since: Date?) -> RolloutRead? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let size = UInt64(info.st_size)
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
        var file = RolloutFile(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), offset: 0)
        let same = known.map { $0.device == file.device && $0.inode == file.inode && $0.offset <= size } ?? false
        let restarted = known != nil && !same
        if same, let known {
            guard known.offset < size else { return nil }
            file.offset = known.offset
            file.skipping = known.skipping
        }
        if let since, modified < since {
            file.offset = size
            return RolloutRead(path: path, file: file, records: [], modified: modified, restarted: false)
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        if file.offset == 0, since != nil || restarted {
            // History, read without alerts: the session and its latest state are enough.
            guard let tail = latest(handle, size: size) else { return nil }
            file.offset = tail.end
            return RolloutRead(path: path, file: file, records: session(handle, missingFrom: tail.records) + tail.records, modified: modified, restarted: restarted)
        }
        // A file whose session is not known yet: read from its start, or `head`.
        let unknown = head || file.offset == 0
        guard let next = forward(handle, from: file.offset, to: size, skipping: file.skipping) else { return nil }
        file.offset = next.end
        file.skipping = next.skipping
        let records = unknown ? session(handle, missingFrom: next.records) + next.records : next.records
        return RolloutRead(path: path, file: file, records: records, modified: modified, restarted: restarted)
    }

    /// The file's session from its first line, to go ahead of `records` when they do not hold it.
    static func session(_ handle: FileHandle, missingFrom records: [RolloutRecord]) -> [RolloutRecord] {
        guard !records.contains(where: { if case .meta = $0 { true } else { false } }), let first = head(handle), case .meta = first else { return [] }
        return [first]
    }

    /// The records of the complete lines from `offset` up to `size`, read `chunkSize` at a time, and the
    /// offset after the last of them. A line still being written is left for the next pass, unless it is
    /// longer than `lineLimit`: it is then dropped up to its end, `skipping` while that end is not read
    /// yet, so the offset moves on and nothing is kept of it. `skipping` starts inside such a line.
    static func forward(_ handle: FileHandle, from offset: UInt64, to size: UInt64, skipping: Bool) -> (records: [RolloutRecord], end: UInt64, skipping: Bool)? {
        guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
        var records: [RolloutRecord] = []
        var end = offset
        var position = offset
        var skipping = skipping
        // The bytes from `end` on: a line not complete yet.
        var pending = Data()
        while position < size {
            guard let chunk = try? handle.read(upToCount: Int(min(size - position, UInt64(chunkSize)))), !chunk.isEmpty else { break }
            position += UInt64(chunk.count)
            if skipping {
                guard let first = chunk.firstIndex(of: newline) else {
                    end = position
                    continue
                }
                skipping = false
                end = position - UInt64(chunk.distance(from: first, to: chunk.endIndex)) + 1
                pending = Data(chunk[chunk.index(after: first)...])
            } else {
                pending.append(chunk)
            }
            if let last = pending.lastIndex(of: newline) {
                for line in pending[pending.startIndex..<last].split(separator: newline) {
                    if let record = record(Data(line)) { records.append(record) }
                }
                end += UInt64(pending.distance(from: pending.startIndex, to: last) + 1)
                pending = Data(pending[pending.index(after: last)...])
            }
            if pending.count > lineLimit {
                end = position
                pending = Data()
                skipping = true
            }
        }
        return (records, end, skipping)
    }

    /// The records of a file's last complete lines, read backwards `chunkSize` at a time until they hold
    /// both a turn's state and the context use, or the file's start; in file order, with the offset after
    /// the last complete line and whether the file's start was reached. Neither the line still being
    /// written nor one longer than `lineLimit` is kept.
    static func latest(_ handle: FileHandle, size: UInt64) -> (records: [RolloutRecord], end: UInt64, fromStart: Bool)? {
        var position = size
        // The bytes from `position` on not split into lines yet; their first line may begin earlier.
        var rest = Data()
        var end: UInt64?
        // The line `rest` ends in is longer than `lineLimit`: its bytes are dropped up to its start.
        var skipping = false
        var newest: [RolloutRecord] = []
        var state = false
        var usage = false
        while position > 0, !(state && usage) {
            let start = position - min(position, UInt64(chunkSize))
            guard (try? handle.seek(toOffset: start)) != nil,
                  let chunk = try? handle.read(upToCount: Int(position - start)), chunk.count == Int(position - start) else { return nil }
            position = start
            if end != nil {
                rest = skipping ? chunk : chunk + rest
            } else {
                // The last line may still be being written: only where it begins is needed.
                guard let last = chunk.lastIndex(of: newline) else { continue }
                end = position + UInt64(chunk.distance(from: chunk.startIndex, to: last) + 1)
                rest = Data(chunk[chunk.startIndex..<last])
            }
            if skipping {
                // What follows the long line's start is part of it.
                guard let begins = rest.lastIndex(of: newline) else {
                    rest = Data()
                    continue
                }
                rest = Data(rest[rest.startIndex..<begins])
                skipping = false
            }
            let cut = position == 0 ? nil : rest.firstIndex(of: newline)
            if position > 0, cut == nil {
                if rest.count > lineLimit {
                    rest = Data()
                    skipping = true
                }
                continue
            }
            let lines = cut.map { rest[rest.index(after: $0)...] } ?? rest[...]
            for line in lines.split(separator: newline).reversed() {
                guard let record = record(Data(line)) else { continue }
                newest.append(record)
                switch record {
                case .context: usage = true
                case .started, .completed, .aborted, .ended: state = true
                case .meta: break
                }
            }
            rest = cut.map { Data(rest[rest.startIndex..<$0]) } ?? Data()
        }
        return (newest.reversed(), end ?? 0, position == 0)
    }

    /// The record of the first line, from its first `chunkSize` bytes at most. `session_meta` carries
    /// codex's instructions after its id, folder, originator and source, so a longer line is decoded up
    /// to its last field complete in those bytes. A shorter line not ended yet waits: what it lacks may
    /// still come.
    static func head(_ handle: FileHandle) -> RolloutRecord? {
        guard (try? handle.seek(toOffset: 0)) != nil, let bytes = try? handle.read(upToCount: chunkSize) else { return nil }
        if let end = bytes.firstIndex(of: newline) {
            return record(Data(bytes[bytes.startIndex..<end]))
        }
        guard bytes.count == chunkSize else { return nil }
        return record(closed(bytes))
    }

    /// The start of a JSON value cut after its last complete member or element, with the objects and
    /// arrays still open there closed, so it decodes.
    static func closed(_ prefix: Data) -> Data {
        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")
        var open: [UInt8] = []
        var cut = 0
        var closers: [UInt8] = []
        var inString = false
        var escaped = false
        for (index, byte) in prefix.enumerated() {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == backslash {
                    escaped = true
                } else if byte == quote {
                    inString = false
                }
                continue
            }
            switch byte {
            case quote:
                inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                open.append(byte == UInt8(ascii: "{") ? UInt8(ascii: "}") : UInt8(ascii: "]"))
                cut = index + 1
                closers = open
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                _ = open.popLast()
            case UInt8(ascii: ","):
                cut = index
                closers = open
            default:
                break
            }
        }
        var data = Data(prefix.prefix(cut))
        data.append(contentsOf: closers.reversed())
        return data
    }

    static func record(_ line: Data) -> RolloutRecord? {
        guard markers.contains(where: { line.range(of: $0) != nil }),
              let value = try? JSONDecoder().decode(JSONValue.self, from: line),
              let payload = value["payload"] else { return nil }
        switch value["type"]?.string {
        case "session_meta":
            guard let id = payload["id"]?.string else { return nil }
            return .meta(RolloutMeta(id: id, cwd: payload["cwd"]?.string, desktop: payload["originator"]?.string == originatorDesktop, ignored: ignored(payload)))
        case "event_msg":
            let turn = payload["turn_id"]?.string
            switch payload["type"]?.string {
            case "task_started": return .started(turn: turn)
            case "task_complete": return .completed(turn: turn)
            case "turn_aborted": return .aborted(turn: turn)
            case "shutdown_complete": return .ended
            case "token_count":
                // Without `info` a rate-limit update, which leaves the row's percent; with it, usage whose
                // unknown counts or window clear the percent.
                guard let info = payload["info"], info != .null else { return nil }
                return .context(ContextUsage.codex(lastTotal: info["last_token_usage"]?["total_tokens"], window: info["model_context_window"]))
            default: return nil
            }
        default:
            return nil
        }
    }

    /// Subagents have an object `source` (`{"subagent": …}`) and their parent's id; `codex exec` runs say
    /// `"exec"`. The TUI says `"cli"` and the desktop app `"vscode"`.
    static func ignored(_ payload: JSONValue) -> Bool {
        if let parent = payload["parent_thread_id"], parent != .null { return true }
        guard let source = payload["source"], source != .null else { return false }
        return source.string == nil || source.string == "exec"
    }
}
