import Foundation

/// Why a system tool gave no output.
enum ToolError: Error, Equatable, CustomStringConvertible {
    /// The tool ran and exited with a non-zero status.
    case exited(executable: String, status: Int32)
    /// The tool was still running at its timeout and was terminated.
    case timedOut(executable: String, after: Duration)

    var description: String {
        switch self {
        case let .exited(executable, status): "\(executable) exited with status \(status)"
        case let .timedOut(executable, timeout): "\(executable) was terminated after running for \(timeout)"
        }
    }
}

/// Runs `executable` and returns what it printed. No thread waits on the process: the output is
/// read as it arrives. The tool is terminated when the calling task is cancelled (the call throws
/// `CancellationError`) or when it is still running after `timeout` (`ToolError.timedOut`).
func toolOutput(_ executable: String, _ arguments: [String], environment: [String: String]? = nil, timeout: Duration) async throws -> Data {
    let run = ToolRun(executable: executable, arguments: arguments, environment: environment)
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            run.start(continuation, timeout: timeout)
        }
    } onCancel: {
        run.finish(.failure(CancellationError()))
    }
}

/// One run of a tool. Whichever comes first ends it: the tool exiting with its output read to the
/// end, its timeout or the caller's cancellation. That first outcome resumes the caller exactly once,
/// stops reading and terminates the tool if it still runs; later ones find the run finished.
private final class ToolRun: @unchecked Sendable {
    private let executable: String
    private let process = Process()
    private let pipe = Pipe()
    private let lock = NSLock()
    // Guarded by `lock`.
    private var continuation: CheckedContinuation<Data, Error>?
    private var outcome: Result<Data, Error>?
    private var launched = false
    private var exited = false
    private var endOfOutput = false
    private var output = Data()

    init(executable: String, arguments: [String], environment: [String: String]?) {
        self.executable = executable
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
    }

    /// Launches the tool, unless the caller was cancelled before it started.
    func start(_ continuation: CheckedContinuation<Data, Error>, timeout: Duration) {
        // Launching under the lock: a cancellation either comes first and nothing launches, or
        // comes after and finds a process to terminate.
        let (earlier, launchError) = lock.withLock { () -> (Result<Data, Error>?, Error?) in
            if let outcome { return (outcome, nil) }
            self.continuation = continuation
            // Reads only what is already there, so no read is left waiting once the run ends.
            pipe.fileHandleForReading.readabilityHandler = { [self] handle in
                let chunk = handle.availableData
                lock.withLock {
                    if chunk.isEmpty { endOfOutput = true } else { output.append(chunk) }
                }
                if chunk.isEmpty { handle.readabilityHandler = nil }
                finishIfDone()
            }
            process.terminationHandler = { [self] _ in
                lock.withLock { exited = true }
                finishIfDone()
            }
            do {
                try process.run()
                launched = true
                return (nil, nil)
            } catch {
                process.terminationHandler = nil
                return (nil, error)
            }
        }
        if let earlier { return continuation.resume(with: earlier) }
        if let launchError { return finish(.failure(launchError)) }
        let (seconds, attoseconds) = timeout.components
        let deadline = DispatchTime.now() + Double(seconds) + Double(attoseconds) * 1e-18
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) { [weak self, executable] in
            self?.finish(.failure(ToolError.timedOut(executable: executable, after: timeout)))
        }
    }

    /// Ends the run with `result` unless it already ended.
    func finish(_ result: Result<Data, Error>) {
        let ended = lock.withLock { () -> (waiting: CheckedContinuation<Data, Error>?, launched: Bool)? in
            guard outcome == nil else { return nil }
            outcome = result
            defer { continuation = nil }
            return (continuation, launched)
        }
        guard let ended else { return }
        pipe.fileHandleForReading.readabilityHandler = nil
        // The termination handler stays: it keeps this run, and with it the process, until the tool
        // exits and is reaped.
        if ended.launched, process.isRunning { process.terminate() }
        ended.waiting?.resume(with: result)
    }

    /// Ends the run once the tool has exited and its output is read to the end.
    private func finishIfDone() {
        let done = lock.withLock { exited && endOfOutput ? output : nil }
        guard let done else { return }
        let status = process.terminationStatus
        finish(status == 0 ? .success(done) : .failure(ToolError.exited(executable: executable, status: status)))
    }
}
