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
@MainActor
final class PerlHelperLauncher: HelperLauncher {
    /// Starts one stream helper process.
    typealias StartProcess = @MainActor (
        _ onLine: @escaping @MainActor (String) -> Void,
        _ onExit: @escaping @MainActor (Int32) -> Void
    ) throws -> any StreamHandle
    /// Runs one helper that sends a command.
    typealias RunCommand = @MainActor (
        NowPlayingCommand,
        _ completion: @escaping @MainActor (Result<Int32, any Error>) -> Void
    ) -> Void

    private let startProcess: StartProcess
    private let runCommand: RunCommand
    private let timer: VerifiedStream.Timer
    /// The stream started last, checked again after a command goes through.
    private weak var stream: VerifiedStream?

    convenience init(library: URL) {
        self.init(
            startProcess: { try LineProcess.start(.stream(library: library), onLine: $0, onExit: $1) },
            runCommand: { PerlHelperLauncher.run(.send($0, library: library), completion: $1) },
            clock: ContinuousClock()
        )
    }

    init<C: Clock<Duration>>(startProcess: @escaping StartProcess, runCommand: @escaping RunCommand, clock: C) {
        self.startProcess = startProcess
        self.runCommand = runCommand
        timer = { delay in
            let deadline = clock.now.advanced(by: delay)
            return { try await clock.sleep(until: deadline, tolerance: nil) }
        }
    }

    func startStream(
        onLine: @escaping @MainActor (String) -> Void,
        onExit: @escaping @MainActor (Int32) -> Void
    ) throws -> any StreamHandle {
        let stream = try VerifiedStream(start: startProcess, timer: timer, onLine: onLine, onExit: onExit)
        self.stream = stream
        return stream
    }

    func send(_ command: NowPlayingCommand, completion: @escaping @MainActor (Result<Int32, any Error>) -> Void) {
        runCommand(command) { [weak self] result in
            if case .success(0) = result {
                self?.stream?.commandSent()
            }
            completion(result)
        }
    }

    /// Runs `helper` once without input or output; `completion` gets its exit status, or the error
    /// that kept it from starting.
    private static func run(_ helper: HelperCommand, completion: @escaping @MainActor (Result<Int32, any Error>) -> Void) {
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

/// The stream the plugin gets from `PerlHelperLauncher`.
///
/// A long-lived helper's MediaRemote client can go stale: after a track change one kept saying
/// playing, with the browser's icon as the image, while the system had paused with the real cover.
/// So the long-lived helper is checked against a fresh one (a new process is a new MediaRemote
/// client), whose first line is the state now: at once when a line says playing at rate 0, a second
/// after a command went through, and every `checkInterval` while the long-lived helper says playing.
/// When the two differ in the playing flag, the item, the source app or the image, the fresh line
/// goes to the plugin and the long-lived helper is replaced; the replacement is not an exit.
///
/// A `none` line waits `nothingHold` and is dropped when another line comes first, so a track change
/// that reports nothing for a moment does not take the item away.
@MainActor
final class VerifiedStream: StreamHandle {
    static let checkAfterCommand: Duration = .seconds(1)
    static let checkInterval: Duration = .seconds(12)
    /// A fresh helper that has not answered by then is stopped, so later checks can run.
    static let checkTimeout: Duration = .seconds(5)
    static let nothingHold: Duration = .seconds(1)
    /// The exit reported when no new long-lived helper can be started after a check.
    static let restartFailedStatus: Int32 = -1

    /// Returns a wait that ends `delay` after this call on the launcher's clock, and throws when its
    /// task is cancelled: the time counts from when the timer is set, not from when its task runs.
    typealias Timer = @Sendable (_ delay: Duration) -> @Sendable () async throws -> Void

    /// What a helper says, as far as a check compares it.
    private enum Reported: Equatable {
        case nothing
        case item(title: String, artist: String?, bundleID: String?, isPlaying: Bool, artwork: Data?)
    }

    /// A fresh helper asked for the state now.
    private struct Check {
        let id: Int
        let helper: any StreamHandle
        var timeout: Task<Void, Never>?
        /// The long-lived helper wrote a line meanwhile: a difference may be a real change between the
        /// two reads rather than a stale client, so the answer is not used.
        var isOvertaken = false
    }

    private let start: PerlHelperLauncher.StartProcess
    private let timer: Timer
    private let onLine: @MainActor (String) -> Void
    private let onExit: @MainActor (Int32) -> Void

    /// The long-lived helper; nil once it ended or the stream was stopped.
    private var helper: (any StreamHandle)?
    /// Counts long-lived helpers; output of a replaced one, or after the end, is ignored.
    private var generation = 0
    /// What the long-lived helper says now; nil before its first line.
    private var reported: Reported?
    private var check: Check?
    private var checksStarted = 0
    private var heldNothing: Task<Void, Never>?
    private var nextCheck: Task<Void, Never>?
    private var commandCheck: Task<Void, Never>?

    init(
        start: @escaping PerlHelperLauncher.StartProcess,
        timer: @escaping Timer,
        onLine: @escaping @MainActor (String) -> Void,
        onExit: @escaping @MainActor (Int32) -> Void
    ) throws {
        self.start = start
        self.timer = timer
        self.onLine = onLine
        self.onExit = onExit
        try startHelper()
    }

    func stop() {
        guard let helper else { return }
        end()
        helper.stop()
    }

    /// A command went through: the app's answer should show within a second.
    func commandSent() {
        guard helper != nil else { return }
        commandCheck?.cancel()
        commandCheck = after(Self.checkAfterCommand) { stream in
            stream.commandCheck = nil
            stream.runCheck()
        }
    }

    private func startHelper() throws {
        generation += 1
        let current = generation
        helper = try start(
            { [weak self] line in self?.helperLine(line, from: current) },
            { [weak self] status in self?.helperEnded(status, from: current) }
        )
    }

    private func helperLine(_ line: String, from current: Int) {
        guard current == generation else { return }
        guard let parsed = HelperLine(line) else {
            onLine(line)
            return
        }
        check?.isOvertaken = true
        heldNothing?.cancel()
        heldNothing = nil
        switch parsed {
        case .nothing:
            reported = .nothing
            heldNothing = after(Self.nothingHold) { stream in
                stream.heldNothing = nil
                stream.onLine(line)
            }
        case .info(let info, let artwork):
            reported = Self.reported(info, artwork, after: reported)
            onLine(line)
            if info.isPlaying, info.rate == 0 {
                runCheck()
            }
        case .unavailable:
            reported = nil
            onLine(line)
        }
        scheduleNextCheck()
    }

    private func helperEnded(_ status: Int32, from current: Int) {
        guard current == generation else { return }
        end()
        onExit(status)
    }

    /// No more output, timers or checks.
    private func end() {
        generation += 1
        helper = nil
        for task in [heldNothing, nextCheck, commandCheck] {
            task?.cancel()
        }
        heldNothing = nil
        nextCheck = nil
        commandCheck = nil
        if let check {
            endCheck(check.id)
        }
    }

    /// While the long-lived helper says playing, a check every `checkInterval`.
    private func scheduleNextCheck() {
        guard case .item(_, _, _, true, _)? = reported else {
            nextCheck?.cancel()
            nextCheck = nil
            return
        }
        guard nextCheck == nil else { return }
        nextCheck = after(Self.checkInterval) { stream in
            stream.nextCheck = nil
            stream.runCheck()
            stream.scheduleNextCheck()
        }
    }

    /// Asks a fresh helper for the state now, unless one is asking already.
    private func runCheck() {
        guard helper != nil, reported != nil, check == nil else { return }
        checksStarted += 1
        let id = checksStarted
        // A fresh helper that cannot start leaves the long-lived one as it is; a later check tries again.
        guard let fresh = try? start(
            { [weak self] line in self?.checkAnswered(line, by: id) },
            { [weak self] _ in self?.endCheck(id) }
        ) else { return }
        check = Check(id: id, helper: fresh)
        check?.timeout = after(Self.checkTimeout) { $0.endCheck(id) }
    }

    private func endCheck(_ id: Int) {
        guard let check, check.id == id else { return }
        self.check = nil
        check.timeout?.cancel()
        check.helper.stop()
    }

    /// The fresh helper's first line is the state now. When it differs from what the long-lived helper
    /// says, the plugin gets it and the long-lived helper is replaced.
    private func checkAnswered(_ line: String, by id: Int) {
        guard let answered = check, answered.id == id else { return }
        endCheck(id)
        guard !answered.isOvertaken, let parsed = HelperLine(line) else { return }
        let fresh: Reported
        switch parsed {
        case .nothing:
            fresh = .nothing
        case .info(let info, let artwork):
            fresh = Self.reported(info, artwork, after: nil)
        case .unavailable:
            return
        }
        guard fresh != reported else { return }
        heldNothing?.cancel()
        heldNothing = nil
        reported = fresh
        onLine(line)
        replaceHelper()
        scheduleNextCheck()
    }

    /// A new long-lived helper is a new client. Its start failing ends the stream like an exit.
    private func replaceHelper() {
        helper?.stop()
        do {
            try startHelper()
        } catch {
            end()
            onExit(Self.restartFailedStatus)
        }
    }

    /// Runs `action` after `delay` on the stream's clock, unless the task is cancelled first.
    private func after(_ delay: Duration, _ action: @escaping @MainActor (VerifiedStream) -> Void) -> Task<Void, Never> {
        let elapsed = timer(delay)
        return Task { [weak self] in
            do { try await elapsed() } catch { return }
            guard !Task.isCancelled, let self else { return }
            action(self)
        }
    }

    /// What an `info` line says; a line that leaves the image out keeps the one `previous` had.
    private static func reported(_ info: TrackInfo, _ artwork: ArtworkUpdate, after previous: Reported?) -> Reported {
        let image: Data?
        switch artwork {
        case .image(let data, _):
            image = data
        case .removed:
            image = nil
        case .unchanged:
            if case .item(_, _, _, _, let held)? = previous { image = held } else { image = nil }
        }
        return .item(title: info.title, artist: info.artist, bundleID: info.bundleID, isPlaying: info.isPlaying, artwork: image)
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
            while let chunk = LineProcess.readAvailable(from: reader.fileDescriptor) {
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

    /// What the pipe holds now, up to 64 KiB, waiting only while it is empty; nil at its end or on an
    /// error. (`FileHandle.read(upToCount:)` waits for the whole count or the end, which kept a running
    /// helper's lines in the pipe.)
    private nonisolated static func readAvailable(from descriptor: Int32) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 { return Data(buffer[..<count]) }
            if count < 0, errno == EINTR { continue }
            return nil
        }
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
