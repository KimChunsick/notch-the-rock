import Foundation
import IOKit

/// A connected device with a battery: a Magic Keyboard, Mouse or Trackpad as the I/O Registry lists
/// it, or a Bluetooth device such as AirPods as system_profiler reports it.
struct PeripheralBattery: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case airPods, airPodsPro, headphones, keyboard, mouse, trackpad, other
    }

    /// One battery of the device: AirPods have one in each bud and one in the case.
    struct Level: Equatable, Sendable {
        enum Part: Equatable, Sendable { case main, left, right, `case` }
        var part: Part
        var percentage: Int
    }

    /// The Bluetooth address as hex digits, the same for both tools; the name when there is none.
    var id: String
    var name: String
    var kind: Kind
    var levels: [Level]
}

// MARK: - Reading

extension PeripheralBattery {
    /// An I/O Registry entry with a `BatteryPercent`, as IOKit and `ioreg -r -a -k BatteryPercent`
    /// give it; nil without a percentage or a product name.
    init?(registryEntry entry: [String: Any]) {
        guard let percentage = entry["BatteryPercent"] as? Int,
              let product = entry["Product"] as? String
        else { return nil }
        self.init(
            id: Self.identifier(address: entry["DeviceAddress"] as? String, name: product),
            name: product,
            kind: Self.kind(named: product),
            levels: [Level(part: .main, percentage: percentage)]
        )
    }

    /// One connected device from `system_profiler -json SPBluetoothDataType`; nil when it reports
    /// no battery level.
    init?(bluetoothName name: String, properties: [String: Any]) {
        let parts: [(String, Level.Part)] = [
            ("device_batteryLevelMain", .main),
            ("device_batteryLevelLeft", .left),
            ("device_batteryLevelRight", .right),
            ("device_batteryLevelCase", .case),
        ]
        let levels = parts.compactMap { key, part in Self.percentage(properties[key]).map { Level(part: part, percentage: $0) } }
        guard !levels.isEmpty else { return nil }
        let minorType = (properties["device_minorType"] as? String ?? "").lowercased()
        let kind: Kind
        if ["headphones", "headset", "speaker"].contains(where: minorType.contains) {
            if properties["device_vendorID"] as? String == "0x004C" {
                // The AirPods Pro models paired with the probe Mac; other Apple headphones show as AirPods.
                let pro: Set = ["0x200E", "0x2014", "0x2024", "0x2027"]
                kind = pro.contains(properties["device_productID"] as? String ?? "") ? .airPodsPro : .airPods
            } else {
                kind = .headphones
            }
        } else {
            kind = Self.kind(named: minorType == "" ? name : minorType)
        }
        self.init(id: Self.identifier(address: properties["device_address"] as? String, name: name), name: name, kind: kind, levels: levels)
    }

    /// Every connected device with a battery level in system_profiler's JSON.
    static func bluetoothDevices(systemProfilerJSON data: Data) -> [PeripheralBattery] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]]
        else { return [] }
        return controllers
            .flatMap { $0["device_connected"] as? [[String: [String: Any]]] ?? [] }
            .flatMap { $0.compactMap { PeripheralBattery(bluetoothName: $0.key, properties: $0.value) } }
    }

    /// The registry's devices, then the Bluetooth ones the registry does not list, by name.
    static func merge(hid: [PeripheralBattery], bluetooth: [PeripheralBattery]) -> [PeripheralBattery] {
        var seen = Set<String>()
        return (hid + bluetooth)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func identifier(address: String?, name: String) -> String {
        let digits = (address ?? "").lowercased().filter(\.isHexDigit)
        return digits.isEmpty ? "name:\(name)" : digits
    }

    private static func kind(named name: String) -> Kind {
        let name = name.lowercased()
        if name.contains("keyboard") { return .keyboard }
        if name.contains("mouse") { return .mouse }
        if name.contains("trackpad") { return .trackpad }
        return .other
    }

    /// "80%" as system_profiler prints it, or a plain number.
    private static func percentage(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        guard let text = value as? String else { return nil }
        return Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
    }
}

/// Reads the connected peripherals: the I/O Registry in process, and system_profiler (about 0.2 s)
/// off the caller's thread.
enum PeripheralReader {
    /// A system_profiler still running after 3 s has stalled and is terminated.
    static let systemProfilerTimeout: Duration = .seconds(3)

    static func read() async -> [PeripheralBattery] {
        let bluetooth = (try? await toolOutput("/usr/sbin/system_profiler", ["-json", "SPBluetoothDataType"], timeout: systemProfilerTimeout))
            .map(PeripheralBattery.bluetoothDevices(systemProfilerJSON:)) ?? []
        return PeripheralBattery.merge(hid: registryDevices(), bluetooth: bluetooth)
    }

    /// Every registry entry with a `BatteryPercent`: what `ioreg -r -k BatteryPercent` lists.
    static func registryDevices() -> [PeripheralBattery] {
        var iterator: io_iterator_t = 0
        let matching = [kIOPropertyExistsMatchKey: "BatteryPercent"] as CFDictionary
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var devices: [PeripheralBattery] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let entry = properties?.takeRetainedValue() as? [String: Any],
                  let device = PeripheralBattery(registryEntry: entry)
            else { continue }
            devices.append(device)
        }
        return devices
    }
}

// MARK: - Text

extension PeripheralBattery.Kind {
    /// SF Symbol for the device's row.
    var symbol: String {
        switch self {
        case .airPods: "airpods"
        case .airPodsPro: "airpodspro"
        case .headphones: "headphones"
        case .keyboard: "keyboard"
        case .mouse: "magicmouse"
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .other: "dot.radiowaves.left.and.right"
        }
    }
}

extension PeripheralBattery {
    /// "67%", or "왼쪽 80% · 오른쪽 75% · 케이스 50%" for a device with several batteries.
    var levelsText: String {
        levels.map { level in
            switch level.part {
            case .main: "\(level.percentage)%"
            case .left: "왼쪽 \(level.percentage)%"
            case .right: "오른쪽 \(level.percentage)%"
            case .case: "케이스 \(level.percentage)%"
            }
        }
        .joined(separator: " · ")
    }
}
