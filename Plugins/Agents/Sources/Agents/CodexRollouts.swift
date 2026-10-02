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
/// known: a turn starting (working), finishing (idle, with an alert) and being stopped (idle).
/// Requests for approval or input, errors and the session's end are not persisted, so these rows
/// never wait and leave the list only by staying silent (`AgentSessionList.silenceLimit`).
///
/// The first pass after `start` indexes the files without alerts, and only sessions written within
/// `recentWindow` get a row. Exec runs and subagents are skipped. A thread the bridge follows is left
/// to it, and a turn alerts once whichever of the two sees it end first.
@MainActor
final class CodexRollouts {
    static let interval: Duration = .seconds(2)
    static let recentWindow: TimeInterval = 3 * 60 * 60
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
    private var indexed = false
    /// Bumped by `stop`, so a pass that began before it changes nothing.
    private var generation = 0
    private var polling: Task<Void, Never>?
    private var notices: [String: (id: Int, task: Task<Void, Never>)] = [:]
    private var noticeCount = 0

    private struct Watched {
        var file: RolloutFile
        /// The file's session, once its `session_meta` line was read.
        var meta: RolloutMeta?
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
        files.removeAll()
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

    /// One pass over the tree; the first indexes without alerts. Returns the alerts it raised.
    @discardableResult
    func scan() async -> [Task<Void, Never>] {
        let generation = generation
        let indexing = !indexed
        let since = indexing ? now().addingTimeInterval(-Self.recentWindow) : nil
        let known = files.mapValues(\.file)
        let headless = Set(files.filter { $0.value.meta == nil }.keys)
        let root = root
        let reads = await Task.detached(priority: .utility) {
            RolloutReader.collect(root: root, known: known, headless: headless, since: since)
        }.value
        guard generation == self.generation else { return [] }
        indexed = true
        var alerts: [Task<Void, Never>] = []
        for read in reads {
            var watched = files[read.path] ?? Watched(file: read.file)
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
        guard !meta.ignored, !bridge.owns(meta.id) else { return nil }
        switch record {
        case .meta:
            return nil
        case .started:
            show(meta, .working, at: date)
        case .aborted:
            show(meta, .idle, at: date)
        case .completed(let turn):
            show(meta, .idle, at: date)
            guard !silent, bridge.claimTurnAlert(meta.id, turn: turn) else { return nil }
            return notify(meta)
        case .ended:
            list.remove(AgentSession.Key(agent: .codex, id: meta.id))
            listed.remove(meta.id)
        }
        return nil
    }

    /// Moves the session's row; a session seen for the first time gets its jump target here.
    private func show(_ meta: RolloutMeta, _ state: AgentSessionState?, at date: Date?) {
        guard !meta.ignored, !bridge.owns(meta.id) else { return }
        if targets[meta.id] == nil {
            targets[meta.id] = .some(meta.desktop ? Self.desktopApp : terminal(meta.cwd))
        }
        listed.insert(meta.id)
        list.update(
            AgentSession.Key(agent: .codex, id: meta.id), folder: meta.folder, state: state,
            terminal: targets[meta.id] ?? nil, changed: date
        )
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
                title: target == nil ? "노치 열기" : (meta.desktop ? "Codex 앱으로 이동" : "터미널로 이동"),
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

/// The file side of `CodexRollouts`, off the main actor.
enum RolloutReader {
    static let originatorDesktop = "Codex Desktop"
    /// Lines without any of these are not decoded.
    static let markers = ["\"session_meta\"", "\"task_started\"", "\"task_complete\"", "\"turn_aborted\"", "\"shutdown_complete\""]
        .map { Data($0.utf8) }

    /// The rollout files under `root` that changed since `known`. With `since` (the indexing pass), a
    /// file not written since then is only remembered at its end. `headless` files are read from
    /// their first line as well, for the session they belong to.
    static func collect(root: URL, known: [String: RolloutFile], headless: Set<String>, since: Date?) -> [RolloutRead] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var reads: [RolloutRead] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"),
                  let read = read(url.path, known: known[url.path], head: headless.contains(url.path), since: since) else { continue }
            reads.append(read)
        }
        return reads
    }

    static func read(_ path: String, known: RolloutFile?, head: Bool, since: Date?) -> RolloutRead? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let size = UInt64(info.st_size)
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
        var file = RolloutFile(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), offset: 0)
        let same = known.map { $0.device == file.device && $0.inode == file.inode && $0.offset <= size } ?? false
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
        if head, file.offset > 0, let first = firstLine(handle), let meta = record(first) {
            records.append(meta)
        }
        guard (try? handle.seek(toOffset: file.offset)) != nil,
              let data = try? handle.read(upToCount: Int(size - file.offset)),
              let end = data.lastIndex(of: UInt8(ascii: "\n")) else {
            return RolloutRead(path: path, file: file, records: records, modified: modified, restarted: known != nil && !same)
        }
        for line in data[data.startIndex..<end].split(separator: UInt8(ascii: "\n")) {
            if let record = record(Data(line)) { records.append(record) }
        }
        file.offset += UInt64(end - data.startIndex + 1)
        return RolloutRead(path: path, file: file, records: records, modified: modified, restarted: known != nil && !same)
    }

    /// The first complete line, read in pieces: `session_meta` carries codex's instructions.
    static func firstLine(_ handle: FileHandle) -> Data? {
        guard (try? handle.seek(toOffset: 0)) != nil else { return nil }
        var line = Data()
        while line.count < 8 << 20, let piece = try? handle.read(upToCount: 64 << 10), !piece.isEmpty {
            if let end = piece.firstIndex(of: UInt8(ascii: "\n")) {
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
