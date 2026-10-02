import Foundation

/// Where the agents' command line tools are. Only looks at the files; nothing is run.
enum ToolSearch {
    /// The first executable among `candidates`.
    static func find(candidates: [String]) -> URL? {
        candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    /// `name` in each `PATH` folder, then where Homebrew and the standalone installers put it (an app
    /// opened from the Finder gets a short `PATH`), then in `extraFolders`.
    static func candidates(
        named name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        extraFolders: [String] = []
    ) -> [String] {
        let folders = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path]
            + extraFolders
        var seen: Set<String> = []
        return folders.filter { !$0.isEmpty && seen.insert($0).inserted }.map { $0 + "/" + name }
    }
}
