import Darwin
import Foundation

/// One process as the terminal search sees it.
public struct ProcessEntry: Hashable, Sendable {
    public var parent: pid_t
    /// The controlling terminal, e.g. `/dev/ttys004`, or nil without one.
    public var tty: String?
    public var executablePath: String?

    public init(parent: pid_t, tty: String?, executablePath: String?) {
        self.parent = parent
        self.tty = tty
        self.executablePath = executablePath
    }
}

public protocol ProcessTable: Sendable {
    func entry(for pid: pid_t) -> ProcessEntry?
}

/// The running system's processes, read with `sysctl(KERN_PROC_PID)` and `proc_pidpath`.
public struct SystemProcessTable: ProcessTable {
    public init() {}

    public func entry(for pid: pid_t) -> ProcessEntry? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let device = info.kp_eproc.e_tdev
        // NODEV (-1) means no controlling terminal.
        let tty = device == -1 ? nil : devname(device, S_IFCHR).map { "/dev/" + String(cString: $0) }
        var path = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        return ProcessEntry(
            parent: info.kp_eproc.e_ppid,
            tty: tty,
            executablePath: length > 0 ? String(decoding: path.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
        )
    }
}

/// Finds the terminal app a hook runs under: the first ancestor process that belongs to a known
/// terminal app, with the terminal device of the nearest ancestor that has one. Hooks have no
/// terminal of their own, but Claude Code and its shell do.
public struct TerminalFinder: Sendable {
    /// Terminal.app, Ghostty and VS Code (its integrated terminal runs under a helper app nested
    /// inside the main app, so the outermost app in the path counts).
    public static let knownTerminals: Set<String> = [
        "com.apple.Terminal",
        "com.mitchellh.ghostty",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
    ]

    let table: any ProcessTable
    let bundleIdentifier: @Sendable (String) -> String?

    /// `bundleIdentifier` maps an `.app` folder path to its bundle identifier.
    public init(table: any ProcessTable, bundleIdentifier: @escaping @Sendable (String) -> String?) {
        self.table = table
        self.bundleIdentifier = bundleIdentifier
    }

    public static var system: TerminalFinder {
        TerminalFinder(table: SystemProcessTable()) { Bundle(path: $0)?.bundleIdentifier }
    }

    public func find(startingAt pid: pid_t) -> TerminalLocation? {
        var pid = pid
        var tty: String?
        var seen: Set<pid_t> = []
        while pid > 1, seen.insert(pid).inserted, let entry = table.entry(for: pid) {
            tty = tty ?? entry.tty
            if let app = entry.executablePath.flatMap(Self.outermostApp),
               let id = bundleIdentifier(app), Self.knownTerminals.contains(id) {
                return TerminalLocation(bundleID: id, tty: tty)
            }
            pid = entry.parent
        }
        return nil
    }

    /// `/Applications/A.app/Contents/Frameworks/B.app/Contents/MacOS/B` → `/Applications/A.app`.
    static func outermostApp(_ path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return components[...index].joined(separator: "/")
    }
}
