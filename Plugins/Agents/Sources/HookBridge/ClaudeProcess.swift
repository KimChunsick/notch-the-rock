import Darwin

/// Finds the Claude Code process a hook runs for. Claude Code starts each hook command through a
/// shell that exits with the hook, so the hook's parent may be that shell: the session's process is
/// the nearest ancestor that is not a shell.
public enum ClaudeProcess {
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh"]

    public static func find(startingAt pid: pid_t, in table: any ProcessTable) -> pid_t? {
        var pid = pid
        var seen: Set<pid_t> = []
        while pid > 1, seen.insert(pid).inserted, let entry = table.entry(for: pid) {
            guard let name = entry.executablePath?.split(separator: "/").last.map(String.init), shells.contains(name) else {
                return pid
            }
            pid = entry.parent
        }
        return nil
    }
}
