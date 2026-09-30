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

/// A user-client connection to the AppleSMC driver. Every request and reply is one 80-byte
/// `SMCKeyData_t`; the offsets below are that C struct's fields, written into raw bytes so no Swift
/// struct padding has to match it.
final class SMCConnection {
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

    /// The key's size and type, or nil when this SMC has no such key.
    func key(_ name: String) -> SMCKey? {
        let code = Self.code(name)
        guard let reply = call(.keyInfo, key: code) else { return nil }
        return SMCKey(code: code, size: reply.load(at: Offset.dataSize), type: reply.load(at: Offset.dataType))
    }

    /// The key's value as a number, for the types this plugin reads: `flt ` (temperatures and fan
    /// speeds on Apple silicon), `ui8 ` and `ui32`. nil for any other type or a failed read.
    func value(_ key: SMCKey) -> Double? {
        guard let reply = call(.readKey, key: key.code, dataSize: key.size) else { return nil }
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

    /// Every `flt ` key whose name starts with one of `prefixes`. Walks all keys the SMC has — about
    /// 1,600 on an M2, roughly 0.4 s — so call it once and off the main thread.
    func floatKeys(withPrefixes prefixes: [String]) -> [SMCKey] {
        guard let countKey = key("#KEY"), let count = value(countKey) else { return [] }
        let floatType = Self.code("flt ")
        return (0..<UInt32(count)).compactMap { index in
            guard let reply = call(.keyAtIndex, index: index) else { return nil }
            let name = Self.string(reply.load(at: Offset.key))
            guard prefixes.contains(where: name.hasPrefix), let key = self.key(name), key.type == floatType, key.size == 4
            else { return nil }
            return key
        }
    }

    private func call(_ command: Command, key: UInt32 = 0, dataSize: UInt32 = 0, index: UInt32 = 0) -> [UInt8]? {
        var input = [UInt8](repeating: 0, count: Self.structSize)
        input.store(key, at: Offset.key)
        input.store(dataSize, at: Offset.dataSize)
        input.store(index, at: Offset.index)
        input[Offset.command] = command.rawValue
        var output = [UInt8](repeating: 0, count: Self.structSize)
        var outputSize = Self.structSize
        let result = IOConnectCallStructMethod(connection, Self.handleYPCEvent, input, Self.structSize, &output, &outputSize)
        // A non-zero result byte is the SMC's own error, e.g. 0x84 for a key it does not have.
        guard result == kIOReturnSuccess, output[Offset.result] == 0 else { return nil }
        return output
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

/// Temperatures and fans from the SMC. On Apple silicon the CPU sensors are the `Tp…` keys and the
/// GPU sensors the `Tg…` keys (type `flt `, °C); this M2 has 28 `Tp` and 6 `Tg` keys. `FNum` is the
/// fan count (absent on fanless Macs such as the MacBook Air) and `F<n>Ac` each fan's speed in rpm.
final class SMCSensorSampler: SensorSampler {
    nonisolated static let cpuPrefix = "Tp"
    nonisolated static let gpuPrefix = "Tg"
    /// Some sensors of an M2 report 0 °C or single-digit values while their block sleeps; readings
    /// outside this range are not temperatures and are left out of the averages.
    static let validTemperatures = 10.0...150.0

    private enum Discovery: Sendable {
        case notStarted
        case running
        case finished([SMCKey])
    }

    /// The temperature keys, found once per process: the key list of an SMC does not change.
    private nonisolated static let discovery = OSAllocatedUnfairLock(initialState: Discovery.notStarted)

    private let smc: SMCConnection?
    private let fans: [SMCKey]

    init() {
        smc = SMCConnection()
        fans = smc.map(Self.fanKeys) ?? []
        if smc != nil { Self.startDiscovery() }
    }

    /// Finds the temperature keys on the calling thread. The plugin discovers them in the background
    /// instead; tests call this to read temperatures right away.
    nonisolated static func discoverNow() {
        let keys = SMCConnection()?.floatKeys(withPrefixes: [cpuPrefix, gpuPrefix]) ?? []
        discovery.withLock { $0 = .finished(keys) }
    }

    private static func startDiscovery() {
        let start = discovery.withLock { state in
            guard case .notStarted = state else { return false }
            state = .running
            return true
        }
        guard start else { return }
        Task.detached(priority: .utility) {
            discoverNow()
        }
    }

    private static func fanKeys(_ smc: SMCConnection) -> [SMCKey] {
        guard let countKey = smc.key("FNum"), let count = smc.value(countKey), count > 0 else { return [] }
        return (0..<Int(count)).compactMap { smc.key("F\($0)Ac") }
    }

    func sensors() -> SensorReading? {
        guard let smc else { return nil }
        let keys: [SMCKey] = Self.discovery.withLock { state in
            if case .finished(let keys) = state { return keys }
            return []
        }
        func average(_ prefix: String) -> Double? {
            let values = keys.filter { $0.name.hasPrefix(prefix) }
                .compactMap(smc.value)
                .filter { Self.validTemperatures.contains($0) }
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        return SensorReading(
            cpuTemperature: average(Self.cpuPrefix),
            gpuTemperature: average(Self.gpuPrefix),
            // A fan whose speed cannot be read still counts as a fan.
            fanSpeeds: fans.map { smc.value($0) ?? 0 }
        )
    }
}
