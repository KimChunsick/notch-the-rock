import Foundation

/// Finds the folders Claude Code was started in from the names of its project folders
/// (`~/.claude/projects/<encoded path>`). Claude Code writes every character of the path other than
/// an ASCII letter or digit as '-', so `-work-my-app` may be `/work/my-app` or `/work/my/app`: the
/// candidates are the existing folders whose encoded path is that name.
struct ProjectDiscovery: Sendable {
    /// Claude Code's project folders, `~/.claude/projects`.
    let claudeProjects: URL
    /// The folder an encoded path starts from, `/`.
    let fileSystemRoot: URL

    private static let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".utf16)

    /// Claude Code's encoding of a path: each UTF-16 unit other than an ASCII letter or digit
    /// becomes '-'.
    static func encode(_ path: String) -> String {
        String(decoding: path.utf16.map { allowed.contains($0) ? $0 : 45 }, as: UTF16.self)
    }

    /// The encoded names in Claude Code's project folder.
    func entries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: claudeProjects.path)) ?? [])
            .filter { $0.hasPrefix("-") }
            .sorted()
    }

    /// The existing folders whose path encodes to `encoded`.
    func candidates(for encoded: String) -> [URL] {
        guard encoded.hasPrefix("-") else { return [] }
        var found: [URL] = []
        walk(fileSystemRoot, remaining: encoded.dropFirst(), depth: 0, into: &found)
        return found
    }

    private func walk(_ folder: URL, remaining: Substring, depth: Int, into found: inout [URL]) {
        guard depth < 40, found.count < 8,
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names.sorted() {
            let encodedName = Self.encode(name)
            guard remaining.hasPrefix(encodedName) else { continue }
            let rest = remaining.dropFirst(encodedName.count)
            guard rest.isEmpty || rest.first == "-" else { continue }
            let child = folder.appendingPathComponent(name)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: child.path, isDirectory: &isFolder), isFolder.boolValue else { continue }
            if rest.isEmpty {
                found.append(child)
            } else {
                walk(child, remaining: rest.dropFirst(), depth: depth + 1, into: &found)
            }
        }
    }
}

/// The folders the user added in settings and the ones removed, kept in the plugin's defaults by
/// resolved path. A removed folder stays hidden even when it is discovered again; adding it back
/// clears that.
struct ProjectFolders {
    static let addedKey = "addedFolders"
    static let removedKey = "removedFolders"
    let defaults: UserDefaults

    var added: [String] { defaults.stringArray(forKey: Self.addedKey) ?? [] }
    var removed: [String] { defaults.stringArray(forKey: Self.removedKey) ?? [] }

    func add(_ url: URL) {
        let path = Self.key(url)
        defaults.set(removed.filter { $0 != path }, forKey: Self.removedKey)
        if !added.contains(path) { defaults.set(added + [path], forKey: Self.addedKey) }
    }

    func remove(_ url: URL) {
        let path = Self.key(url)
        defaults.set(added.filter { $0 != path }, forKey: Self.addedKey)
        if !removed.contains(path) { defaults.set(removed + [path], forKey: Self.removedKey) }
    }

    /// The discovered folders, then the added ones, without the removed ones or duplicates.
    func resolve(discovered: [URL]) -> [URL] {
        Self.resolve(discovered: discovered, added: added, removed: removed)
    }

    /// `resolve(discovered:)` for lists read earlier, so it can run off the main actor.
    static func resolve(discovered: [URL], added: [String], removed: [String]) -> [URL] {
        let hidden = Set(removed)
        var seen = Set<String>()
        return (discovered.map(key) + added).compactMap { path in
            guard !hidden.contains(path), seen.insert(path).inserted else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    static func key(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
