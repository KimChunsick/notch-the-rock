import Foundation

/// A running stream helper.
@MainActor
protocol StreamHandle: AnyObject {
    /// Ends the helper and waits until it has exited. Lines and the exit of a stopped helper may
    /// still be delivered afterwards; the caller ignores them.
    func stop()
}

/// Starts the helper processes. The plugin reaches the outside world only through this.
@MainActor
protocol HelperLauncher {
    /// Starts the helper in stream mode. `onLine` gets every line of its output in order, then
    /// `onExit` its exit status once, both on the main actor.
    func startStream(
        onLine: @escaping @MainActor (String) -> Void,
        onExit: @escaping @MainActor (Int32) -> Void
    ) throws -> any StreamHandle

    /// Runs the helper once to send `command`; `completion` gets its exit status, or the error that
    /// kept it from starting.
    func send(_ command: NowPlayingCommand, completion: @escaping @MainActor (Result<Int32, any Error>) -> Void)
}

/// Runs `/usr/bin/perl` with the driver and the helper library of the installed bundle.
struct PerlHelperLauncher: HelperLauncher {
    let library: URL

    func startStream(
        onLine: @escaping @MainActor (String) -> Void,
        onExit: @escaping @MainActor (Int32) -> Void
    ) throws -> any StreamHandle {
        try LineProcess.start(.stream(library: library), onLine: onLine, onExit: onExit)
    }

    func send(_ command: NowPlayingCommand, completion: @escaping @MainActor (Result<Int32, any Error>) -> Void) {
        let helper = HelperCommand.send(command, library: library)
        let process = Process()
        process.executableURL = helper.executable
        process.arguments = helper.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            let status = process.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(.success(status)) }
            }
        }
        do {
            try process.run()
        } catch {
            completion(.failure(error))
        }
    }
}

/// A process whose output is read line by line on a thread of its own. The process keeps running
/// while its stdin is open; `stop()` closes it and terminates the process.
@MainActor
final class LineProcess: StreamHandle {
    /// How long `stop()` waits for the process to end after SIGTERM, and again after SIGKILL.
    static let stopTimeout: DispatchTimeInterval = .seconds(2)

    private let process: Process
    private let input: FileHandle
    /// Signalled by the reader once the process has exited and its output is read to the end.
    private let finished: DispatchSemaphore

    private init(process: Process, input: FileHandle, finished: DispatchSemaphore) {
        self.process = process
        self.input = input
        self.finished = finished
    }

    static func start(
        _ command: HelperCommand,
        onLine: @escaping @MainActor (String) -> Void,
        onExit: @escaping @MainActor (Int32) -> Void
    ) throws -> LineProcess {
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // Process closes the child's ends of both pipes here once the child has them.
        try process.run()

        let finished = DispatchSemaphore(value: 0)
        let reader = output.fileHandleForReading
        // Lines go to the main queue in order, and the exit only after the last of them.
        Thread.detachNewThread {
            var pending = Data()
            while let chunk = try? reader.read(upToCount: 64 * 1024), !chunk.isEmpty {
                var start = chunk.startIndex
                while let newline = chunk[start...].firstIndex(of: UInt8(ascii: "\n")) {
                    pending.append(chunk[start..<newline])
                    let line = String(decoding: pending, as: UTF8.self)
                    pending.removeAll(keepingCapacity: true)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { onLine(line) }
                    }
                    start = chunk.index(after: newline)
                }
                pending.append(chunk[start...])
            }
            try? reader.close()
            process.waitUntilExit()
            let status = process.terminationStatus
            finished.signal()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { onExit(status) }
            }
        }
        return LineProcess(process: process, input: input.fileHandleForWriting, finished: finished)
    }

    func stop() {
        try? input.close()
        if process.isRunning {
            process.terminate()
        }
        if finished.wait(timeout: .now() + Self.stopTimeout) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + Self.stopTimeout)
        }
    }
}
