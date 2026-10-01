import Darwin
import Foundation
import HookBridge

/// Where codex's shared app-server listens: the default endpoint the `codex` TUI attaches to.
struct CodexEndpoint: Equatable {
    /// `$CODEX_HOME`, `~/.codex` when unset.
    let home: URL

    var socketPath: String {
        home.appendingPathComponent("app-server-control/app-server-control.sock").path
    }

    static func current(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> CodexEndpoint {
        if let set = environment["CODEX_HOME"], !set.isEmpty {
            return CodexEndpoint(home: URL(fileURLWithPath: set))
        }
        return CodexEndpoint(home: home.appendingPathComponent(".codex"))
    }
}

struct CodexServerError: Error, CustomStringConvertible {
    let description: String
}

/// A running `codex app-server` the plugin started.
@MainActor
protocol CodexServerProcess: AnyObject {
    func terminate()
}

/// Starts processes; tests replace it.
@MainActor
protocol CodexLaunching: AnyObject {
    /// `onExit` runs with the exit status, on any thread.
    func launch(_ executable: URL, arguments: [String], environment: [String: String], onExit: @escaping @Sendable (Int32) -> Void) throws -> any CodexServerProcess
}

@MainActor
final class SystemCodexLauncher: CodexLaunching {
    private final class Running: CodexServerProcess {
        let process: Process
        init(_ process: Process) { self.process = process }
        func terminate() { process.terminate() }
    }

    func launch(_ executable: URL, arguments: [String], environment: [String: String], onExit: @escaping @Sendable (Int32) -> Void) throws -> any CodexServerProcess {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { onExit($0.terminationStatus) }
        try process.run()
        return Running(process)
    }
}

enum CodexServerOwnership: Equatable {
    /// A server someone else started; the plugin never stops it.
    case reused
    /// The server the plugin started and stops on 해제 or deactivation.
    case spawned
}

/// Keeps a shared app-server reachable at the default endpoint: reuses one that already listens in
/// a folder only the user can enter, otherwise starts `codex app-server --listen unix://<endpoint>`.
/// It stops only a server it started itself.
@MainActor
final class CodexSupervisor {
    let endpoint: CodexEndpoint
    private let executable: URL?
    private let launcher: any CodexLaunching
    private let startTimeout: Duration
    private var process: (any CodexServerProcess)?
    private var launchCount = 0

    var ownsServer: Bool { process != nil }

    init(endpoint: CodexEndpoint, executable: URL?, launcher: any CodexLaunching, startTimeout: Duration = .seconds(10)) {
        self.endpoint = endpoint
        self.executable = executable
        self.launcher = launcher
        self.startTimeout = startTimeout
    }

    /// The delay before retry number `attempt` (from 0): 1, 2, 4, 8, 16, then 30 seconds.
    nonisolated static func backoff(attempt: Int) -> Duration {
        .seconds(min(30, 1 << min(attempt, 5)))
    }

    /// Makes sure a server listens at the endpoint. Throws when the socket folder or socket is not
    /// the user's alone, when codex is missing, or when a started server does not listen in time.
    func ensure() async throws -> CodexServerOwnership {
        let path = endpoint.socketPath
        switch Self.check(path) {
        case .listening: return process == nil ? .reused : .spawned
        case .unsafe(let reason): throw CodexServerError(description: reason)
        case .absent: break
        }
        // Ours, but no longer listening: start over.
        process?.terminate()
        process = nil
        guard let executable else { throw CodexServerError(description: "codex를 찾지 못했어요.") }
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = endpoint.home.path
        environment["PATH"] = ([executable.deletingLastPathComponent().path] + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        launchCount += 1
        let number = launchCount
        let launched = try launcher.launch(executable, arguments: ["app-server", "--listen", "unix://" + path], environment: environment) { [weak self] _ in
            Task { @MainActor in self?.exited(number) }
        }
        process = launched
        let deadline = ContinuousClock.now + startTimeout
        while ContinuousClock.now < deadline {
            guard process === launched else { throw CodexServerError(description: "codex app-server가 바로 끝났어요.") }
            switch Self.check(path) {
            case .listening: return .spawned
            case .unsafe(let reason):
                stop()
                throw CodexServerError(description: reason)
            case .absent:
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        stop()
        throw CodexServerError(description: "codex app-server가 소켓을 열지 않았어요.")
    }

    /// Stops the server this supervisor started, if any.
    func stop() {
        process?.terminate()
        process = nil
    }

    private func exited(_ number: Int) {
        if number == launchCount { process = nil }
    }

    enum Check: Equatable {
        case listening
        /// Nothing listens: no socket, or a stale file nobody accepts on.
        case absent
        case unsafe(String)
    }

    /// Whether a server listens at `path` in a folder (0700) and socket (0600) of the user's own.
    nonisolated static func check(_ path: String) -> Check {
        let folder = (path as NSString).deletingLastPathComponent
        var info = stat()
        guard lstat(folder, &info) == 0 else { return .absent }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            return .unsafe("\(folder) 폴더를 다른 사용자도 쓸 수 있어서 연결하지 않았어요. 폴더 권한을 700으로 바꿔 주세요.")
        }
        guard lstat(path, &info) == 0 else { return .absent }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid(), info.st_mode & 0o777 == 0o600 else {
            return .unsafe("\(path) 소켓을 다른 사용자도 쓸 수 있어서 연결하지 않았어요.")
        }
        return canConnect(path) ? .listening : .absent
    }

    private nonisolated static func canConnect(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            bytes.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }
}

/// One connection to the app-server as `CodexLink` uses it: `WebSocket` on this Mac, fakes in tests.
protocol CodexConnection: AnyObject, Sendable {
    /// Completes the connection (the HTTP Upgrade) within `timeout`; blocks.
    func handshake(timeout: Duration) throws
    /// Queues one message; never blocks.
    func send(text: String)
    /// The next message, or nil once the server closed the connection; blocks.
    func receive() throws -> String?
    /// Ends the connection; a handshake or `receive()` blocked on another thread returns.
    func close()
}

/// Keeps the plugin connected while Codex is 연결: makes sure the server runs, connects over
/// WebSocket, hands messages to the bridge, and when the socket closes (or the attempt fails) tries
/// again after `CodexSupervisor.backoff`. Only the current connection reaches the bridge: one that
/// 해제 replaced may still be unwinding on its own thread, and it neither delivers messages nor
/// closes the bridge.
@MainActor
final class CodexLink {
    enum State: Equatable {
        case off
        case connecting
        case connected(CodexServerOwnership)
        /// Waiting to retry after the reason.
        case retrying(String)
    }

    private(set) var state: State = .off {
        didSet { onState?(state) }
    }
    var onState: ((State) -> Void)?
    private let supervisor: CodexSupervisor
    private let bridge: CodexBridge
    private let sleep: @MainActor (Duration) async -> Void
    private let log: @MainActor (String) -> Void
    private let connect: @Sendable (String) throws -> any CodexConnection
    private let handshakeTimeout: Duration
    private var loop: Task<Void, Never>?
    /// The connection from the moment it exists, so 해제 can close it even during the handshake.
    private var connection: (any CodexConnection)?

    init(
        supervisor: CodexSupervisor,
        bridge: CodexBridge,
        log: @escaping @MainActor (String) -> Void,
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        connect: @escaping @Sendable (String) throws -> any CodexConnection = { try WebSocket(unixPath: $0) },
        handshakeTimeout: Duration = .seconds(5)
    ) {
        self.supervisor = supervisor
        self.bridge = bridge
        self.log = log
        self.sleep = sleep
        self.connect = connect
        self.handshakeTimeout = handshakeTimeout
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    /// Disconnects, withdraws the requests and stops the server only when the plugin started it.
    func stop() {
        loop?.cancel()
        loop = nil
        connection?.close()
        connection = nil
        bridge.close()
        supervisor.stop()
        state = .off
    }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            state = .connecting
            do {
                let ownership = try await supervisor.ensure()
                let path = supervisor.endpoint.socketPath
                let connect = connect
                let connection = try await Task.detached { try connect(path) }.value
                guard !Task.isCancelled else {
                    connection.close()
                    return
                }
                self.connection = connection
                let timeout = handshakeTimeout
                do {
                    try await Task.detached { try connection.handshake(timeout: timeout) }.value
                } catch {
                    connection.close()
                    if self.connection === connection { self.connection = nil }
                    throw error
                }
                // 해제 during the handshake closed the connection already.
                guard !Task.isCancelled, self.connection === connection else { return }
                state = .connected(ownership)
                let started = ContinuousClock.now
                await session(connection)
                // A connection 해제 replaced is not this loop's to clean up.
                guard !Task.isCancelled, self.connection === connection else { return }
                self.connection = nil
                bridge.close()
                // A connection that lasted resets the backoff; one that drops at once does not.
                if ContinuousClock.now - started > .seconds(30) { attempt = 0 }
                state = .retrying("app-server와 연결이 끊겼어요.")
            } catch let error as CodexServerError {
                guard !Task.isCancelled else { return }
                state = .retrying(error.description)
            } catch {
                guard !Task.isCancelled else { return }
                log("Could not connect to the codex app-server: \(error)")
                state = .retrying("app-server에 연결하지 못했어요.")
            }
            await sleep(CodexSupervisor.backoff(attempt: attempt))
            attempt += 1
        }
    }

    /// Reads on its own thread until the connection closes; messages reach the bridge in order while
    /// it is still the current connection.
    private func session(_ connection: any CodexConnection) async {
        bridge.open { message in
            connection.send(text: CodexBridge.encode(message))
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread { [weak self] in
                while let text = try? connection.receive() {
                    guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { continue }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, self.connection === connection else { return }
                            _ = self.bridge.receive(message)
                        }
                    }
                }
                connection.close()
                DispatchQueue.main.async { done.resume() }
            }
        }
    }
}
