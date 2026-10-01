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

    /// The first executable among `candidates`. Only looks at the files: the version is read later,
    /// off the main actor, when the settings page shows it.
    static func find(candidates: [String]) -> URL? {
        candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    /// `PATH`, then where Homebrew and the standalone installer put codex (an app opened from the
    /// Finder gets a short `PATH`).
    static func candidates(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let folders = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path]
        var seen: Set<String> = []
        return folders.filter { !$0.isEmpty && seen.insert($0).inserted }.map { $0 + "/codex" }
    }

    /// What `<executable> --version` reports, or nil when it fails or does not finish within
    /// `timeout`; then codex is killed. Never blocks the caller's thread.
    static func readVersion(_ executable: URL, timeout: Duration = .seconds(3)) async -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let reading = output.fileHandleForReading
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            process.terminationHandler = { _ in
                guard once.claim() else { return }
                continuation.resume(returning: parseVersion(String(decoding: drain(reading.fileDescriptor), as: UTF8.self)))
            }
            do {
                try process.run()
            } catch {
                if once.claim() { continuation.resume(returning: nil) }
                return
            }
            let pid = process.processIdentifier
            let parts = timeout.components
            let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                guard once.claim() else { return }
                kill(pid, SIGKILL)
                continuation.resume(returning: nil)
            }
        }
    }

    /// What the exited process wrote, without waiting for an end of file that a child it left behind
    /// could hold back.
    private static func drain(_ fd: Int32) -> Data {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while data.count < 65_536 {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { break }
            data.append(contentsOf: chunk.prefix(count))
        }
        return data
    }
}

/// True for the first caller only.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
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
