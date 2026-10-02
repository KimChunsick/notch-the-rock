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
/// context use codex counted (`token_count`).
/// Requests for approval or input and errors are not persisted, so these rows never wait.
///
/// The first pass after `start` indexes the files without alerts, reading only the end of each file
/// written within `recentWindow`, and only those sessions get a row. Later passes look every
/// `interval` at the files written within `recentWindow` and the recent date folders only; the whole
/// tree is walked again every `discoveryInterval`. Exec runs and subagents are skipped. A thread the
/// bridge follows is left to it, a turn alerts once whichever of the two sees it end first, and a
/// session that closed stays closed whatever is read of it later.
@MainActor
final class CodexRollouts {
    static let interval: Duration = .seconds(2)
    static let recentWindow: TimeInterval = 3 * 60 * 60
    static let discoveryInterval: TimeInterval = 60
    /// The Codex desktop app (`/Applications/ChatGPT.app`): its sessions' rows and alerts bring it forward.
    static let desktopApp = TerminalLocation(bundleID: "com.openai.codex", tty: nil)

    private let root: URL
    private let context: NotchContext
    private let bridge: CodexBridge
    private let activator: any TerminalActivating
    /// The terminal of the `codex` TUI working in a folder; looked up once per session.
    private let terminal: @MainActor (String?) -> TerminalLocation?
    private let logos: (any AgentLogoProviding)?
    private let now: () -> Date

    private var files: [String: Watched] = [:]
    /// Where each session's row and alerts take the user, by session id; nil when nothing was found.
    private var targets: [String: TerminalLocation?] = [:]
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
        /// When the file was last seen written.
        var modified: Date
    }

    init(
        root: URL,
        context: NotchContext,
        bridge: CodexBridge,
        activator: any TerminalActivating,
        terminal: @escaping @MainActor (String?) -> TerminalLocation?,
        logos: (any AgentLogoProviding)? = nil,
        now: @escaping () -> Date = { .now }
    ) {
        self.root = root
        self.context = context
        self.bridge = bridge
        self.activator = activator
        self.terminal = terminal
        self.logos = logos
        self.now = now
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
        if discovering { discovered = started }
        var alerts: [Task<Void, Never>] = []
        for read in reads {
            var watched = files[read.path] ?? Watched(file: read.file, modified: read.modified)
            watched.modified = read.modified
            // A replaced or shortened file is read again from its start, as history.
            let silent = indexing || read.restarted
            if read.restarted { watched.meta = nil }
            watched.file = read.file
            let date = silent ? read.modified : nil
            for record in read.records {
                if case .meta(let meta) = record {
                    guard watched.meta == nil else { continue }
                    watched.meta = meta
                    show(meta, nil, at: date)
                    continue
                }
                guard let meta = watched.meta else { continue }
                if let alert = apply(record, meta, silent: silent, at: date) {
                    alerts.append(alert)
                }
            }
            files[read.path] = watched
        }
        return alerts
    }

    private func apply(_ record: RolloutRecord, _ meta: RolloutMeta, silent: Bool, at date: Date?) -> Task<Void, Never>? {
        guard follows(meta) else { return nil }
        if ended.contains(meta.id) {
            // Resumed: a new turn brings an ended session back. Nothing else does.
            guard case .started = record else { return nil }
            ended.remove(meta.id)
        }
        switch record {
        case .meta:
            return nil
        case .started:
            show(meta, .working, at: date)
        case .aborted:
            show(meta, .idle, at: date)
        case .completed(let turn):
            // A turn that alerted already, here or in the bridge, moves nothing: the bridge may have closed it.
            guard silent || bridge.claimTurnAlert(meta.id, turn: turn) else { return nil }
            show(meta, .idle, at: date)
            return silent ? nil : notify(meta)
        case .ended:
            ended.insert(meta.id)
            list.remove(AgentSession.Key(agent: .codex, id: meta.id))
            listed.remove(meta.id)
        case .context(let percent):
            list.setContext(AgentSession.Key(agent: .codex, id: meta.id), percent)
        }
        return nil
    }

    /// Moves the session's row; a session seen for the first time gets its jump target here.
    private func show(_ meta: RolloutMeta, _ state: AgentSessionState?, at date: Date?) {
        guard follows(meta), !ended.contains(meta.id) else { return }
        if targets[meta.id] == nil {
            targets[meta.id] = .some(meta.desktop ? Self.desktopApp : terminal(meta.cwd))
        }
        listed.insert(meta.id)
        list.update(
            AgentSession.Key(agent: .codex, id: meta.id), folder: meta.folder, state: state,
            terminal: targets[meta.id] ?? nil, changed: date
        )
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
        let target = targets[session] ?? nil
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
    /// How full the context window is, in percent (`token_count`).
    case context(Int)
}

/// Where the watcher stopped reading a file.
struct RolloutFile: Equatable, Sendable {
    var device: UInt64
    var inode: UInt64
    /// The byte after the last complete line read.
    var offset: UInt64
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
        }
        if let since, modified < since {
            file.offset = size
            return RolloutRead(path: path, file: file, records: [], modified: modified, restarted: false)
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var records: [RolloutRecord] = []
        if file.offset == 0, since != nil || restarted {
            // History, read without alerts: the session and its latest state are enough.
            guard let tail = latest(handle, size: size) else { return nil }
            if !tail.fromStart, let first = firstLine(handle), let meta = record(first) {
                records.append(meta)
            }
            file.offset = tail.end
            return RolloutRead(path: path, file: file, records: records + tail.records, modified: modified, restarted: restarted)
        }
        if head, file.offset > 0, let first = firstLine(handle), let meta = record(first) {
            records.append(meta)
        }
        guard let next = forward(handle, from: file.offset, to: size) else { return nil }
        file.offset = next.end
        return RolloutRead(path: path, file: file, records: records + next.records, modified: modified, restarted: restarted)
    }

    /// The records of the complete lines from `offset` up to `size`, read `chunkSize` at a time, and the
    /// offset after the last of them. A line still being written is left for the next pass.
    static func forward(_ handle: FileHandle, from offset: UInt64, to size: UInt64) -> (records: [RolloutRecord], end: UInt64)? {
        guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
        var records: [RolloutRecord] = []
        var end = offset
        var position = offset
        // The bytes from `end` on: a line not complete yet.
        var pending = Data()
        while position < size {
            guard let chunk = try? handle.read(upToCount: Int(min(size - position, UInt64(chunkSize)))), !chunk.isEmpty else { break }
            position += UInt64(chunk.count)
            pending.append(chunk)
            guard let last = pending.lastIndex(of: newline) else { continue }
            for line in pending[pending.startIndex..<last].split(separator: newline) {
                if let record = record(Data(line)) { records.append(record) }
            }
            end += UInt64(pending.distance(from: pending.startIndex, to: last) + 1)
            pending = Data(pending[pending.index(after: last)...])
        }
        return (records, end)
    }

    /// The records of a file's last complete lines, read backwards `chunkSize` at a time until they hold
    /// both a turn's state and the context use, or the file's start; in file order, with the offset after
    /// the last complete line and whether the file's start was reached.
    static func latest(_ handle: FileHandle, size: UInt64) -> (records: [RolloutRecord], end: UInt64, fromStart: Bool)? {
        var position = size
        // The bytes from `position` on not split into lines yet; their first line may begin earlier.
        var rest = Data()
        var end: UInt64?
        var newest: [RolloutRecord] = []
        var state = false
        var usage = false
        while position > 0, !(state && usage) {
            let start = position - min(position, UInt64(chunkSize))
            guard (try? handle.seek(toOffset: start)) != nil,
                  let chunk = try? handle.read(upToCount: Int(position - start)), chunk.count == Int(position - start) else { return nil }
            position = start
            rest = chunk + rest
            if end == nil {
                // The last line may still be being written.
                guard let last = rest.lastIndex(of: newline) else { continue }
                end = position + UInt64(rest.distance(from: rest.startIndex, to: last) + 1)
                rest = Data(rest[rest.startIndex..<last])
            }
            let cut = position == 0 ? nil : rest.firstIndex(of: newline)
            if position > 0, cut == nil { continue }
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

    /// The first complete line, read in pieces: `session_meta` carries codex's instructions.
    static func firstLine(_ handle: FileHandle) -> Data? {
        guard (try? handle.seek(toOffset: 0)) != nil else { return nil }
        var line = Data()
        while line.count < 8 << 20, let piece = try? handle.read(upToCount: 64 << 10), !piece.isEmpty {
            if let end = piece.firstIndex(of: newline) {
                return line + piece[piece.startIndex..<end]
            }
            line += piece
        }
        return nil
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
                // Without `info` (a rate-limit update) the use is unknown, and the row keeps its percent.
                let info = payload["info"]
                return ContextUsage.codex(lastTotal: info?["last_token_usage"]?["total_tokens"], window: info?["model_context_window"]).map(RolloutRecord.context)
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
