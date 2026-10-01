import Foundation
import IOKit
import os

/// A System Management Controller key with the size and type the SMC reports for it.
struct SMCKey: Hashable, Sendable {
    let code: UInt32
    let size: UInt32
    let type: UInt32

    var name: String { SMCConnection.string(code) }
}

/// What the SMC answered to a key lookup. Its "no such key" is an answer about this Mac; a request
/// that failed says nothing about it.
enum SMCLookup {
    case found(SMCKey)
    case notFound
    case failed
}

/// The SMC requests the sensor sampler makes, so tests can script the answers.
protocol SMCReading: AnyObject {
    func key(_ name: String) -> SMCLookup
    /// The key's value as a number, or nil when it cannot be read.
    func value(_ key: SMCKey) -> Double?
}

/// A user-client connection to the AppleSMC driver. Every request and reply is one 80-byte
/// `SMCKeyData_t`; the offsets below are that C struct's fields, written into raw bytes so no Swift
/// struct padding has to match it.
final class SMCConnection: SMCReading {
    private static let structSize = 80
    private static let handleYPCEvent: UInt32 = 2
    private enum Offset {
        static let key = 0
        static let dataSize = 28
        static let dataType = 32
        static let result = 40
        static let command = 42
        static let index = 44
        static let bytes = 48
    }
    private enum Command: UInt8 {
        case readKey = 5
        case keyAtIndex = 8
        case keyInfo = 9
    }
    /// The SMC's result byte for a key it does not have.
    private static let keyNotFound: UInt8 = 0x84
    private enum Reply {
        case data([UInt8])
        case keyNotFound
        case failed
    }

    private let connection: io_connect_t

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
        self.connection = connection
    }

    deinit {
        IOServiceClose(connection)
    }

    static func code(_ name: String) -> UInt32 {
        name.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func string(_ code: UInt32) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, as: UTF8.self)
    }

    /// The key's size and type.
    func key(_ name: String) -> SMCLookup {
        let code = Self.code(name)
        switch call(.keyInfo, key: code) {
        case .data(let reply):
            return .found(SMCKey(code: code, size: reply.load(at: Offset.dataSize), type: reply.load(at: Offset.dataType)))
        case .keyNotFound:
            return .notFound
        case .failed:
            return .failed
        }
    }

    /// The key's value as a number, for the types this plugin reads: `flt ` (temperatures and fan
    /// speeds on Apple silicon), `ui8 ` and `ui32`. nil for any other type or a failed read.
    func value(_ key: SMCKey) -> Double? {
        guard case .data(let reply) = call(.readKey, key: key.code, dataSize: key.size) else { return nil }
        let bytes = Array(reply[Offset.bytes..<Offset.bytes + Int(min(key.size, 32))])
        switch Self.string(key.type) {
        case "flt " where bytes.count == 4:
            return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        case "ui8 " where bytes.count == 1:
            return Double(bytes[0])
        case "ui32" where bytes.count == 4:
            return Double(bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        default:
            return nil
        }
    }

    /// Every `flt ` key whose name starts with one of `prefixes`, or nil when the SMC could not say
    /// how many keys it has. Walks all keys the SMC has — about 1,600 on an M2, roughly 0.4 s — so
    /// call it off the main thread.
    func floatKeys(withPrefixes prefixes: [String]) -> [SMCKey]? {
        guard case .found(let countKey) = key("#KEY"), let count = value(countKey) else { return nil }
        let floatType = Self.code("flt ")
        return (0..<UInt32(count)).compactMap { index in
            guard case .data(let reply) = call(.keyAtIndex, index: index) else { return nil }
            let name = Self.string(reply.load(at: Offset.key))
            guard prefixes.contains(where: name.hasPrefix), case .found(let key) = self.key(name), key.type == floatType,
                  key.size == 4
            else { return nil }
            return key
        }
    }

    private func call(_ command: Command, key: UInt32 = 0, dataSize: UInt32 = 0, index: UInt32 = 0) -> Reply {
        var input = [UInt8](repeating: 0, count: Self.structSize)
        input.store(key, at: Offset.key)
        input.store(dataSize, at: Offset.dataSize)
        input.store(index, at: Offset.index)
        input[Offset.command] = command.rawValue
        var output = [UInt8](repeating: 0, count: Self.structSize)
        var outputSize = Self.structSize
        let result = IOConnectCallStructMethod(connection, Self.handleYPCEvent, input, Self.structSize, &output, &outputSize)
        guard result == kIOReturnSuccess else { return .failed }
        // A non-zero result byte is the SMC's own error.
        switch output[Offset.result] {
        case 0: return .data(output)
        case Self.keyNotFound: return .keyNotFound
        default: return .failed
        }
    }
}

private extension [UInt8] {
    mutating func store(_ value: UInt32, at offset: Int) {
        Swift.withUnsafeBytes(of: value) { self.replaceSubrange(offset..<offset + 4, with: $0) }
    }

    func load(at offset: Int) -> UInt32 {
        self[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }
}

/// Finds the SMC's temperature keys off the main thread. The key list of an SMC does not change, so
/// a list once found is kept for the process. An attempt that could not list the keys (no
/// connection, an unreadable key count) is not an answer about this Mac: it is tried again
/// `retryInterval` seconds later.
final class TemperatureKeyDiscovery: Sendable {
    static let retryInterval = 30.0
    /// The discovery every live sampler shares.
    static let shared = TemperatureKeyDiscovery(listKeys: listSMCKeys)

    /// The CPU and GPU temperature keys of this Mac's SMC, read over a connection of their own.
    @Sendable static func listSMCKeys() -> [SMCKey]? {
        SMCConnection()?.floatKeys(withPrefixes: [SMCSensorSampler.cpuPrefix, SMCSensorSampler.gpuPrefix])
    }

    private enum State: Sendable {
        /// No attempt is running; the next one may start at `retryAt` (-infinity before the first).
        case waiting(retryAt: Double)
        case running
        case found([SMCKey])
    }

    private let state = OSAllocatedUnfairLock(initialState: State.waiting(retryAt: -.infinity))
    private let listKeys: @Sendable () -> [SMCKey]?
    private let start: @Sendable (@escaping @Sendable () -> Void) -> Void

    /// - Parameters:
    ///   - listKeys: the temperature keys of the SMC, or nil when it could not list them.
    ///   - start: runs an attempt; by default in a background task. Tests run it at once.
    init(
        start: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { work in Task.detached(priority: .utility) { work() } },
        listKeys: @escaping @Sendable () -> [SMCKey]?
    ) {
        self.start = start
        self.listKeys = listKeys
    }

    /// The temperature keys, empty until they are found. Starts an attempt when none is running and
    /// the last failed one is `retryInterval` old; `time` is seconds on a monotonic clock.
    func keys(at time: Double) -> [SMCKey] {
        let begins = state.withLock { state in
            guard case .waiting(let retryAt) = state, time >= retryAt else { return false }
            state = .running
            return true
        }
        if begins {
            start { [self] in
                let keys = listKeys()
                state.withLock { $0 = keys.map(State.found) ?? .waiting(retryAt: time + Self.retryInterval) }
            }
        }
        return state.withLock { state in
            if case .found(let keys) = state { return keys }
            return []
        }
    }
}

/// Temperatures and fans from the SMC. On Apple silicon the CPU sensors are the `Tp…` keys and the
/// GPU sensors the `Tg…` keys (type `flt `, °C); this M2 has 28 `Tp` and 6 `Tg` keys. `FNum` is the
/// fan count and `F<n>Ac` each fan's speed in rpm. A fanless Mac such as the MacBook Air has no
/// `FNum` key at all: its SMC answers "no such key" (0x84).
final class SMCSensorSampler: SensorSampler {
    nonisolated static let cpuPrefix = "Tp"
    nonisolated static let gpuPrefix = "Tg"
    /// Some sensors of an M2 report 0 °C or single-digit values while their block sleeps; readings
    /// outside this range are not temperatures and are left out of the averages.
    static let validTemperatures = 10.0...150.0
    /// Seconds to wait before asking the SMC for the fans again after it could not tell.
    static let fanRetryInterval = 30.0

    private let smc: (any SMCReading)?
    private let discovery: TemperatureKeyDiscovery
    private let now: () -> Double
    /// The speed key of every fan, empty on a Mac without fans; nil until the SMC has told.
    private var fans: [SMCKey]?
    private var nextFanLookup = -Double.infinity

    /// Reads this Mac's SMC; its temperature sensors are found in the background on the first reading.
    convenience init() {
        self.init(smc: SMCConnection())
    }

    /// - Parameters:
    ///   - discovery: finds the temperature keys whose values `smc` reads.
    ///   - now: seconds on a monotonic clock, for spacing the fan lookups and discovery attempts.
    init(
        smc: (any SMCReading)?,
        discovery: TemperatureKeyDiscovery = .shared,
        now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.smc = smc
        self.discovery = discovery
        self.now = now
    }

    /// The speed key of every fan: none when the SMC has no `FNum` key or counts 0 fans. nil when the
    /// SMC could not tell: a request failed, `FNum` could not be read, or a fan it counts has no
    /// speed key.
    private static func fanKeys(_ smc: any SMCReading) -> [SMCKey]? {
        switch smc.key("FNum") {
        case .notFound:
            return []
        case .failed:
            return nil
        case .found(let countKey):
            guard let count = smc.value(countKey).flatMap({ Int(exactly: $0) }), count >= 0 else { return nil }
            var keys: [SMCKey] = []
            for index in 0..<count {
                guard case .found(let key) = smc.key("F\(index)Ac") else { return nil }
                keys.append(key)
            }
            return keys
        }
    }

    func sensors() -> SensorReading? {
        guard let smc else { return nil }
        let time = now()
        if fans == nil, time >= nextFanLookup {
            fans = Self.fanKeys(smc)
            nextFanLookup = time + Self.fanRetryInterval
        }
        let keys = discovery.keys(at: time)
        func average(_ prefix: String) -> Double? {
            let values = keys.filter { $0.name.hasPrefix(prefix) }
                .compactMap(smc.value)
                .filter { Self.validTemperatures.contains($0) }
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        return SensorReading(
            cpuTemperature: average(Self.cpuPrefix),
            gpuTemperature: average(Self.gpuPrefix),
            fans: fans.map { $0.isEmpty ? .noFans : .speeds($0.map(smc.value)) } ?? .unavailable
        )
    }
}
