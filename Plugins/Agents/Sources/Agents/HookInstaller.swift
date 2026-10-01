import CryptoKit
import Darwin
import Foundation
import HookBridge

/// One hook handler the plugin adds to Claude Code's settings.
struct HookEntry: Hashable, Sendable {
    let event: String
    /// Claude Code's matcher for the event, or nil for every occurrence.
    let matcher: String?
    let command: String
    /// Seconds Claude Code waits for the hook.
    let timeout: Int

    /// The entries for Claude Code: `notch-hook <event>` for each event the plugin handles. Notices
    /// return at once; requests may wait for the notch, so their timeout outlasts any wait.
    static func claude(helper: URL) -> [HookEntry] {
        let notices = [HookEvent.sessionStart, .userPromptSubmit, .stop, .notification, .sessionEnd, .postToolUse, .postToolUseFailure].map {
            HookEntry(event: $0.rawValue, matcher: nil, command: HookInstaller.command(helper: helper, event: $0), timeout: 10)
        }
        return notices + [
            HookEntry(
                event: HookEvent.permissionRequest.rawValue,
                matcher: nil,
                command: HookInstaller.command(helper: helper, event: .permissionRequest),
                timeout: ApprovalWait.hookTimeout
            ),
            HookEntry(
                event: HookEvent.preToolUse.rawValue,
                matcher: "AskUserQuestion",
                command: HookInstaller.command(helper: helper, event: .preToolUse),
                timeout: ApprovalWait.hookTimeout
            ),
        ]
    }
}

enum InstallStatus: Equatable {
    case notInstalled
    /// Some of the plugin's entries are in the file, others are not.
    case partial
    case installed
    /// The settings file cannot be read as Claude Code settings; nothing is written to it. Carries
    /// the message for the settings page.
    case unreadable(String)
}

enum UninstallResult: Equatable {
    /// The file again holds the bytes it had before the plugin first wrote to it.
    case restored
    /// The plugin created the file and nothing else is in it, so it is gone again.
    case deleted
    /// The file changed since the plugin wrote it: only the plugin's entries were taken out.
    case removedEntries
    /// The plugin's entries were taken out, but the file from before install is not known (no
    /// record of it, or its backup is gone), so it could not be put back byte for byte.
    case removedEntriesWithoutOriginal
    case nothingToRemove

    /// Shown in the settings page after 해제, when there is something the user should know.
    var message: String? {
        switch self {
        case .removedEntriesWithoutOriginal: "연결하기 전 파일을 찾지 못해서 그대로 되돌리지는 못했어요. NotchTheRock 훅만 지웠어요."
        case .restored, .deleted, .removedEntries, .nothingToRemove: nil
        }
    }
}

enum InstallError: Error, Equatable {
    /// The settings file cannot be read as Claude Code settings; it was left untouched.
    case unreadable(String)
    case unwritable(String)
    /// The settings file kept changing while the plugin was about to write it; it was left as it is.
    case changedMeanwhile

    /// Shown in the settings page.
    var message: String {
        switch self {
        case .unreadable(let reason): "settings.json을 읽지 못해서 바꾸지 않았어요. \(reason)"
        case .unwritable(let reason): "settings.json을 저장하지 못했어요. \(reason)"
        case .changedMeanwhile: "settings.json이 그사이 계속 바뀌어서 바꾸지 않았어요. 잠시 뒤에 다시 눌러 주세요."
        }
    }
}

/// Adds the plugin's hooks to Claude Code's `settings.json` and takes them out again.
///
/// Install backs up the current file (0600, next to it), then merges the entries into `hooks`
/// without touching other keys or other hooks; a file it cannot read is left alone. Uninstall puts
/// the backed-up bytes back when the file still holds exactly what install wrote, so install and
/// uninstall leave the file byte for byte as it was; when the file changed since, it removes only
/// the entries whose command is exactly the plugin's. A file that install created is deleted again,
/// unless other keys were added to it meanwhile. A symlinked settings file stays a link: the file it
/// points to is written.
///
/// Claude Code and editors save the file at any time, so every write is a compare-and-swap: the file
/// is read again just before it is replaced or deleted, and when it changed since it was read the
/// whole read-merge-write starts over (`attempts` times, then `InstallError.changedMeanwhile`
/// without writing). A save in the instant between that last read and the rename itself cannot be
/// detected; POSIX has no rename that compares first.
struct HookInstaller {
    let settingsURL: URL
    /// Where install remembers what uninstall may put back (in the plugin's own storage).
    let recordURL: URL
    let entries: [HookEntry]
    var now: () -> Date = Date.init
    /// Runs after the settings file was read and just before it is replaced or deleted. Tests save
    /// the file here, as Claude Code or an editor might at that moment.
    var willReplace: () -> Void = {}
    /// Runs after each step of install that leaves something on disk. Tests throw here to stop
    /// install the way a crash would: nothing after the step runs, not even the clean-up.
    var afterStep: (Step) throws(InstallError) -> Void = { _ in }

    enum Step {
        /// The backup and the pending record are on disk; the settings file is untouched.
        case prepared
        /// The settings file holds the merged hooks; the record still says pending.
        case replaced
    }

    /// The shell command for `event`: the helper's path in single quotes (it may contain spaces)
    /// and the event name.
    static func command(helper: URL, event: HookEvent) -> String {
        "'" + helper.path.replacingOccurrences(of: "'", with: "'\\''") + "' " + event.rawValue
    }

    func status() -> InstallStatus {
        do {
            guard let data = try snapshot().data else { return .notInstalled }
            let settings = try parse(data)
            let present = entries.filter { contains(settings, $0) }.count
            if present == 0 { return .notInstalled }
            return present == entries.count ? .installed : .partial
        } catch {
            return .unreadable(error.message)
        }
    }

    /// How many times install and uninstall start over when the file changes under them.
    static let attempts = 3

    func install() throws(InstallError) {
        for _ in 0..<Self.attempts {
            if try installOnce() { return }
        }
        throw .changedMeanwhile
    }

    /// Reads the file, merges the entries and writes the result over exactly what was read. False
    /// when the file changed before it could be replaced: then nothing was written.
    private func installOnce() throws(InstallError) -> Bool {
        let snapshot = try snapshot()
        var object: [String: Any] = [:]
        if let data = snapshot.data {
            object = try parse(data)
        }
        let missing = entries.filter { !contains(object, $0) }
        guard !missing.isEmpty else { return true }
        var hooks = object["hooks"] as? [String: Any] ?? [:]
        for entry in missing {
            var group: [String: Any] = ["hooks": [["type": "command", "command": entry.command, "timeout": entry.timeout]]]
            if let matcher = entry.matcher { group["matcher"] = matcher }
            hooks[entry.event] = (hooks[entry.event] as? [Any] ?? []) + [group]
        }
        object["hooks"] = hooks
        let data = try serialize(object)

        // A record left by an install that stopped half way is settled first, so its backup is gone
        // before this one is named.
        let previous = record(for: snapshot)
        // The backup holds the very bytes the merge started from.
        var backup: URL?
        if let current = snapshot.data {
            backup = try writeBackup(current)
        }
        var pending = InstallRecord(state: .pending, written: Self.digest(data), before: snapshot.data.map(Self.digest), backup: backup?.path)
        if let previous, let current = snapshot.data, previous.written == Self.digest(current) {
            // Only the plugin wrote to the file since the first install: that state still counts.
            pending.original = previous.original
            pending.inherited = true
        } else if missing.count < entries.count {
            // The file already holds some of the plugin's entries; no earlier state is known.
            pending.original = nil
        } else {
            pending.original = backup.map { .backup(path: $0.path) } ?? .absent
        }
        // The way back is on disk before the file changes: a crash from here on leaves a record that
        // the next 연결 or 해제 settles against the file.
        do {
            try saveRecord(pending)
        } catch {
            if let backup { unlink(backup.path) }
            throw error
        }
        try afterStep(.prepared)
        let replaced: Bool
        do {
            replaced = try replace(snapshot, with: data)
        } catch {
            undo(pending, putting: previous)
            throw error
        }
        guard replaced else {
            undo(pending, putting: previous)
            return false
        }
        try afterStep(.replaced)
        // Best effort: a record left pending is settled as done, since the file holds its bytes.
        pending.state = .committed
        try? saveRecord(pending)
        return true
    }

    /// Takes back an install whose file was not replaced: its backup goes and the record it
    /// replaced comes back.
    private func undo(_ pending: InstallRecord, putting previous: InstallRecord?) {
        if let backup = pending.backup { unlink(backup) }
        if let previous {
            try? saveRecord(previous)
        } else {
            try? FileManager.default.removeItem(at: recordURL)
        }
    }

    /// Puts the file back as it was, or takes the entries out. The record stays when the file kept
    /// changing, so a later 해제 can still restore it.
    @discardableResult
    func uninstall() throws(InstallError) -> UninstallResult {
        for _ in 0..<Self.attempts {
            let snapshot = try snapshot()
            if let result = try uninstallOnce(snapshot, record: record(for: snapshot)) {
                try? FileManager.default.removeItem(at: recordURL)
                return result
            }
        }
        throw .changedMeanwhile
    }

    /// Nil when the file changed before it could be restored, rewritten or deleted: then it was left
    /// as it is.
    private func uninstallOnce(_ snapshot: Snapshot, record: InstallRecord?) throws(InstallError) -> UninstallResult? {
        guard let data = snapshot.data else { return .nothingToRemove }
        var restorable = record?.original != nil
        if let record, let original = record.original, record.written == Self.digest(data) {
            switch original {
            case .absent:
                return try delete(snapshot) ? .deleted : nil
            case .backup(let path):
                // A backup the user deleted leaves only the entries to remove.
                if let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                    return try replace(snapshot, with: bytes) ? .restored : nil
                }
                restorable = false
            }
        }
        var object = try parse(data)
        guard remove(from: &object) else { return .nothingToRemove }
        if object.isEmpty, record?.original == .absent {
            return try delete(snapshot) ? .deleted : nil
        }
        let result: UninstallResult = restorable ? .removedEntries : .removedEntriesWithoutOriginal
        return try replace(snapshot, with: try serialize(object)) ? result : nil
    }

    // MARK: Settings file

    /// The file the settings path leads to, following a symlink.
    private var target: URL { settingsURL.resolvingSymlinksInPath() }

    /// The settings file's bytes and the file they were read from, at one moment.
    private struct Snapshot: Equatable {
        struct Identity: Equatable {
            let device: Int32
            let inode: UInt64
            let size: Int64
            let modified: Int
            let modifiedNanoseconds: Int
            let mode: mode_t
        }

        /// Nil when there is no settings file.
        let data: Data?
        let identity: Identity?
    }

    private func snapshot() throws(InstallError) -> Snapshot {
        let fd = open(target.path, O_RDONLY | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return Snapshot(data: nil, identity: nil) }
        guard fd >= 0 else { throw .unreadable("파일을 열지 못했어요: \(String(cString: strerror(errno)))") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw .unreadable("파일을 열지 못했어요: \(String(cString: strerror(errno)))") }
        let data: Data
        do {
            data = try handle.readToEnd() ?? Data()
        } catch {
            throw .unreadable("파일을 열지 못했어요: \(error.localizedDescription)")
        }
        let identity = Snapshot.Identity(
            device: info.st_dev,
            inode: info.st_ino,
            size: info.st_size,
            modified: info.st_mtimespec.tv_sec,
            modifiedNanoseconds: info.st_mtimespec.tv_nsec,
            mode: info.st_mode & 0o7777
        )
        return Snapshot(data: data, identity: identity)
    }

    /// Claude Code settings as an object. Comments and trailing commas are accepted (JSON5); a
    /// `hooks` that is not an object of arrays is refused, since merging into it would break it.
    private func parse(_ data: Data) throws(InstallError) -> [String: Any] {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed])
        } catch {
            let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
            throw .unreadable("JSON 형식이 아니에요." + (detail.map { " (\($0))" } ?? ""))
        }
        guard let object = value as? [String: Any] else { throw .unreadable("맨 바깥이 JSON 객체가 아니에요.") }
        if let hooks = object["hooks"] {
            guard let hooks = hooks as? [String: Any] else { throw .unreadable("hooks 항목이 객체가 아니에요.") }
            for event in Set(entries.map(\.event)) where hooks[event] != nil && !(hooks[event] is [Any]) {
                throw .unreadable("hooks.\(event) 항목이 배열이 아니에요.")
            }
        }
        return object
    }

    private func serialize(_ object: [String: Any]) throws(InstallError) -> Data {
        do {
            var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            data.append(UInt8(ascii: "\n"))
            return data
        } catch {
            throw .unwritable(error.localizedDescription)
        }
    }

    private func contains(_ object: [String: Any], _ entry: HookEntry) -> Bool {
        let groups = (object["hooks"] as? [String: Any])?[entry.event] as? [Any] ?? []
        return groups.contains { group in
            let handlers = (group as? [String: Any])?["hooks"] as? [Any] ?? []
            return handlers.contains { ($0 as? [String: Any])?["command"] as? String == entry.command }
        }
    }

    /// Takes out every handler whose command is exactly one of the plugin's for that event, then the
    /// groups, event lists and `hooks` object that only held them. True when something was removed.
    private func remove(from object: inout [String: Any]) -> Bool {
        guard var hooks = object["hooks"] as? [String: Any] else { return false }
        var removedAny = false
        for event in Set(entries.map(\.event)) {
            guard let groups = hooks[event] as? [Any] else { continue }
            let commands = Set(entries.filter { $0.event == event }.map(\.command))
            var kept: [Any] = []
            var removedHere = false
            for group in groups {
                guard var members = group as? [String: Any], let handlers = members["hooks"] as? [Any] else {
                    kept.append(group)
                    continue
                }
                let remaining = handlers.filter { handler in
                    guard let command = (handler as? [String: Any])?["command"] as? String else { return true }
                    return !commands.contains(command)
                }
                if remaining.count == handlers.count {
                    kept.append(group)
                    continue
                }
                removedHere = true
                if !remaining.isEmpty {
                    members["hooks"] = remaining
                    kept.append(members)
                }
            }
            if removedHere {
                removedAny = true
                hooks[event] = kept.isEmpty ? nil : kept
            }
        }
        guard removedAny else { return false }
        object["hooks"] = hooks.isEmpty ? nil : hooks
        return true
    }

    /// Writes `data` over the file `snapshot` was read from, through a temporary file and a rename
    /// that keep its permissions (0600 for a new file). Right before the rename the file is read
    /// again; when its bytes or identity differ from `snapshot`, someone saved it meanwhile, so
    /// nothing is written and the result is false. Where there was no file, the rename refuses to
    /// replace one that appeared since.
    private func replace(_ snapshot: Snapshot, with data: Data) throws(InstallError) -> Bool {
        let target = target
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw .unwritable(error.localizedDescription)
        }
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        guard try Self.createNew(temporary, data: data, mode: snapshot.identity?.mode ?? 0o600) else {
            throw .unwritable("임시 파일이 이미 있어요: \(temporary.path)")
        }
        willReplace()
        guard (try? self.snapshot()) == snapshot else {
            unlink(temporary.path)
            return false
        }
        guard renamex_np(temporary.path, target.path, snapshot.data == nil ? UInt32(RENAME_EXCL) : 0) == 0 else {
            let code = errno
            unlink(temporary.path)
            if code == EEXIST { return false }
            throw .unwritable(String(cString: strerror(code)))
        }
        return true
    }

    /// Deletes the file `snapshot` was read from; false, leaving it, when it changed since.
    private func delete(_ snapshot: Snapshot) throws(InstallError) -> Bool {
        willReplace()
        guard (try? self.snapshot()) == snapshot else { return false }
        guard unlink(target.path) == 0 || errno == ENOENT else {
            throw .unwritable(String(cString: strerror(errno)))
        }
        return true
    }

    /// Copies the current bytes to `settings.json.notchtherock-<time>.bak` beside the settings
    /// path, readable by the user only.
    private func writeBackup(_ data: Data) throws(InstallError) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        let stem = "\(settingsURL.lastPathComponent).notchtherock-\(formatter.string(from: now()))"
        for attempt in 0..<100 {
            let url = settingsURL.deletingLastPathComponent()
                .appendingPathComponent(attempt == 0 ? "\(stem).bak" : "\(stem)-\(attempt).bak")
            if try Self.createNew(url, data: data, mode: 0o600) {
                return url
            }
        }
        throw .unwritable("백업 파일 이름을 정하지 못했어요.")
    }

    /// Writes `data` to a new file created with `mode` from the start; false when a file is already
    /// at `url`.
    private static func createNew(_ url: URL, data: Data, mode: mode_t) throws(InstallError) -> Bool {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        if fd < 0 && errno == EEXIST { return false }
        guard fd >= 0 else { throw .unwritable("\(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        guard HookSocket.write(data, to: fd), fsync(fd) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(url.path)
            throw .unwritable("\(url.lastPathComponent): \(reason)")
        }
        return true
    }

    // MARK: Install record

    struct InstallRecord: Codable, Equatable {
        enum State: String, Codable {
            /// Saved before the settings file is replaced; the replacement may not have happened.
            case pending
            /// The settings file was replaced.
            case committed
        }

        var state: State
        /// SHA-256 of the bytes install wrote (or, while pending, is about to write).
        var written: String
        /// SHA-256 of the bytes install started from; nil when there was no settings file.
        var before: String?
        /// What uninstall puts back when the file still holds `written`; nil when only removing the
        /// entries is safe.
        var original: Original?
        /// The backup this install made.
        var backup: String?
        /// `original` came from an earlier install whose bytes this one started from.
        var inherited = false

        enum Original: Codable, Equatable {
            case backup(path: String)
            /// There was no settings file.
            case absent
        }
    }

    /// The install record, with an install that stopped half way settled against `snapshot`: when
    /// the file holds what it was about to write, it happened; when the file still holds what it
    /// started from, it did not, so its backup is removed and the record it replaced comes back.
    /// When the file holds neither, it was saved since, and the record stays as it is (uninstall
    /// then only takes the entries out).
    private func record(for snapshot: Snapshot) -> InstallRecord? {
        guard var record = loadRecord() else { return nil }
        guard record.state == .pending else { return record }
        let current = snapshot.data.map(Self.digest)
        if current == record.written {
            record.state = .committed
            try? saveRecord(record)
            return record
        }
        guard current == record.before else { return record }
        let earlier = record.inherited ? record.before.map { InstallRecord(state: .committed, written: $0, original: record.original) } : nil
        undo(record, putting: earlier)
        return earlier
    }

    private func loadRecord() -> InstallRecord? {
        guard let data = try? Data(contentsOf: recordURL) else { return nil }
        return try? JSONDecoder().decode(InstallRecord.self, from: data)
    }

    private func saveRecord(_ record: InstallRecord) throws(InstallError) {
        do {
            try FileManager.default.createDirectory(at: recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
        } catch {
            throw .unwritable(error.localizedDescription)
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
