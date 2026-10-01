import Darwin
import Foundation
import HookBridge

// notch-hook <event>: the command Claude Code hooks run (installed by the Agents plugin). Reads the
// hook input on stdin, forwards it to the Agents plugin's socket and prints what the plugin decided.
// It always exits 0; empty output tells Claude Code to go on as if the hook were not there, which is
// what happens when the app is not running.

let environment = ProcessInfo.processInfo.environment
let runner = HookRunner(
    socketPath: environment[HookSocket.pathEnvironmentKey]
        ?? HookSocket.defaultPath(home: FileManager.default.homeDirectoryForCurrentUser),
    environment: environment,
    readInput: { FileHandle.standardInput.readDataToEndOfFile() },
    findTerminal: { TerminalFinder.system.find(startingAt: getppid()) }
)
let output = runner.run(arguments: Array(CommandLine.arguments.dropFirst()))
if !output.isEmpty {
    FileHandle.standardOutput.write(output)
}
exit(0)
