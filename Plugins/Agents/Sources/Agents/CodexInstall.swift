import Darwin
import Foundation
import HookBridge

/// The `codex` executable the plugin uses and its version.
struct CodexInstall: Equatable {
    /// The codex version this plugin's protocol handling was tested with.
    static let testedVersion = "0.153.4"

    let executable: URL
    let version: String?

    /// What the settings page warns about, or nil for the tested version.
    var warning: String? {
        guard let version else {
            return "codex 버전을 확인하지 못했어요. 이 플러그인은 \(Self.testedVersion) 버전에서 확인했어요."
        }
        guard version != Self.testedVersion else { return nil }
        return "이 플러그인은 codex \(Self.testedVersion) 버전에서 확인했어요. 설치된 \(version) 버전에서는 일부 요청이 노치에 나타나지 않을 수 있어요."
    }

    /// `0.153.4` from `codex-cli 0.153.4`.
    static func parseVersion(_ output: String) -> String? {
        guard let range = output.range(of: #"codex-cli (\d+\.\d+\.\d+)"#, options: .regularExpression) else { return nil }
        return String(output[range].dropFirst("codex-cli ".count))
    }

    /// The first executable among `candidates`, with the version it reports.
    static func detect(candidates: [String]) -> CodexInstall? {
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let executable = URL(fileURLWithPath: path)
        return CodexInstall(executable: executable, version: readVersion(executable))
    }

    /// `PATH`, then where Homebrew and the standalone installer put codex (an app opened from the
    /// Finder gets a short `PATH`).
    static func candidates(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let folders = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path]
        var seen: Set<String> = []
        return folders.filter { !$0.isEmpty && seen.insert($0).inserted }.map { $0 + "/codex" }
    }

    private static func readVersion(_ executable: URL) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseVersion(String(decoding: data, as: UTF8.self))
    }
}

/// A running process whose executable is named `codex`, with its working folder.
struct CodexProcess: Equatable {
    let pid: pid_t
    let cwd: String
}

/// Finds the terminal of a thread's `codex` TUI: the `codex` processes whose working folder is the
/// thread's folder, each traced to its terminal app by `TerminalFinder`. The app-server the plugin
/// started has no terminal and drops out. Two TUIs in one folder under different terminals, a TUI
/// started in another folder than its thread's, or one that changed folder give no answer, and the
/// notch opens instead.
enum CodexTerminals {
    static func terminal(forCwd cwd: String, processes: [CodexProcess], find: (pid_t) -> TerminalLocation?) -> TerminalLocation? {
        let found = Set(processes.filter { $0.cwd == cwd }.compactMap { find($0.pid) })
        return found.count == 1 ? found.first : nil
    }

    /// The terminal of the TUI working in `cwd` on this Mac.
    static func systemTerminal(forCwd cwd: String?) -> TerminalLocation? {
        guard let cwd else { return nil }
        let finder = TerminalFinder.system
        return terminal(forCwd: cwd, processes: systemProcesses()) { finder.find(startingAt: $0) }
    }

    /// Every process of the user's named `codex`, read with `proc_listallpids`, `proc_pidpath` and
    /// `PROC_PIDVNODEPATHINFO`.
    static func systemProcesses() -> [CodexProcess] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let listed = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard listed > 0 else { return [] }
        return pids.prefix(Int(listed)).compactMap { pid -> CodexProcess? in
            guard pid > 0 else { return nil }
            var path = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
            let length = proc_pidpath(pid, &path, UInt32(path.count))
            guard length > 0 else { return nil }
            let executable = String(decoding: path.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard (executable as NSString).lastPathComponent == "codex" else { return nil }
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
            let cwd = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return cwd.isEmpty ? nil : CodexProcess(pid: pid, cwd: cwd)
        }
    }
}
