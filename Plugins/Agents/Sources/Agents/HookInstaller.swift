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

    /// The entries for Claude Code: `notch-hook <event>` for each event the plugin handles.
    static func claude(helper: URL) -> [HookEntry] {
        [HookEvent.sessionStart, .stop, .notification].map {
            HookEntry(event: $0.rawValue, matcher: nil, command: HookInstaller.command(helper: helper, event: $0), timeout: 10)
        }
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
    case nothingToRemove
}

enum InstallError: Error, Equatable {
    /// The settings file cannot be read as Claude Code settings; it was left untouched.
    case unreadable(String)
    case unwritable(String)

    /// Shown in the settings page.
    var message: String {
        switch self {
        case .unreadable(let reason): "settings.json을 읽지 못해서 바꾸지 않았어요. \(reason)"
        case .unwritable(let reason): "settings.json을 저장하지 못했어요. \(reason)"
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
struct HookInstaller {
    let settingsURL: URL
    /// Where install remembers what uninstall may put back (in the plugin's own storage).
    let recordURL: URL
    let entries: [HookEntry]
    var now: () -> Date = Date.init

    /// The shell command for `event`: the helper's path in single quotes (it may contain spaces)
    /// and the event name.
    static func command(helper: URL, event: HookEvent) -> String {
        "'" + helper.path.replacingOccurrences(of: "'", with: "'\\''") + "' " + event.rawValue
    }

    func status() -> InstallStatus {
        do {
            guard let settings = try read() else { return .notInstalled }
            let present = entries.filter { contains(settings.object, $0) }.count
            if present == 0 { return .notInstalled }
            return present == entries.count ? .installed : .partial
        } catch {
            return .unreadable(error.message)
        }
    }

    func install() throws(InstallError) {
        let current = try read()
        var object = current?.object ?? [:]
        let missing = entries.filter { !contains(object, $0) }
        guard !missing.isEmpty else { return }
        var hooks = object["hooks"] as? [String: Any] ?? [:]
        for entry in missing {
            var group: [String: Any] = ["hooks": [["type": "command", "command": entry.command, "timeout": entry.timeout]]]
            if let matcher = entry.matcher { group["matcher"] = matcher }
            hooks[entry.event] = (hooks[entry.event] as? [Any] ?? []) + [group]
        }
        object["hooks"] = hooks
        let data = try serialize(object)

        var backup: URL?
        if let current {
            backup = try writeBackup(current.data)
        }
        let previous = loadRecord()
        let original: InstallRecord.Original?
        if let previous, let current, previous.written == Self.digest(current.data) {
            // Only the plugin wrote to the file since the first install: that state still counts.
            original = previous.original
        } else if let current, entries.contains(where: { contains(current.object, $0) }) {
            // The file already holds some of the plugin's entries; no earlier state is known.
            original = nil
        } else {
            original = backup.map { .backup(path: $0.path) } ?? .absent
        }
        try saveRecord(InstallRecord(written: Self.digest(data), original: original))
        try replace(with: data)
    }

    @discardableResult
    func uninstall() throws(InstallError) -> UninstallResult {
        let record = loadRecord()
        let result = try uninstall(record: record)
        try? FileManager.default.removeItem(at: recordURL)
        return result
    }

    private func uninstall(record: InstallRecord?) throws(InstallError) -> UninstallResult {
        guard let data = try contents() else { return .nothingToRemove }
        if let record, let original = record.original, record.written == Self.digest(data) {
            switch original {
            case .absent:
                try delete()
                return .deleted
            case .backup(let path):
                // A backup the user deleted leaves only the entries to remove.
                if let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                    try replace(with: bytes)
                    return .restored
                }
            }
        }
        var object = try parse(data)
        guard remove(from: &object) else { return .nothingToRemove }
        if object.isEmpty, record?.original == .absent {
            try delete()
            return .deleted
        }
        try replace(with: try serialize(object))
        return .removedEntries
    }

    // MARK: Settings file

    /// The file the settings path leads to, following a symlink.
    private var target: URL { settingsURL.resolvingSymlinksInPath() }

    private func contents() throws(InstallError) -> Data? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return nil }
        do {
            return try Data(contentsOf: settingsURL)
        } catch {
            throw .unreadable("파일을 열지 못했어요: \(error.localizedDescription)")
        }
    }

    private func read() throws(InstallError) -> (data: Data, object: [String: Any])? {
        guard let data = try contents() else { return nil }
        return (data, try parse(data))
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

    /// Replaces the settings file through a temporary file and a rename, keeping its permissions
    /// (0600 for a new file).
    private func replace(with data: Data) throws(InstallError) {
        let target = target
        var info = stat()
        let mode = lstat(target.path, &info) == 0 ? info.st_mode & 0o7777 : 0o600
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw .unwritable(error.localizedDescription)
        }
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        guard try Self.createNew(temporary, data: data, mode: mode) else {
            throw .unwritable("임시 파일이 이미 있어요: \(temporary.path)")
        }
        guard rename(temporary.path, target.path) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(temporary.path)
            throw .unwritable(reason)
        }
    }

    private func delete() throws(InstallError) {
        do {
            try FileManager.default.removeItem(at: target)
        } catch {
            throw .unwritable(error.localizedDescription)
        }
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
        /// SHA-256 of the bytes install last wrote.
        var written: String
        /// What uninstall puts back when the file still holds `written`; nil when only removing the
        /// entries is safe.
        var original: Original?

        enum Original: Codable, Equatable {
            case backup(path: String)
            /// There was no settings file.
            case absent
        }
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
