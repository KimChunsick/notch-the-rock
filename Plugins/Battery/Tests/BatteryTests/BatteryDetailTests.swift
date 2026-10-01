import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Battery

// MARK: - Recorded outputs

/// `top -l 2 -o power -stats pid,command,power -n 8` as the R28 probe recorded it on this Mac. The
/// first sample's POWER is always 0.0: only the last sample counts.
private let recordedTop = """
Processes: 549 total, 3 running, 546 sleeping, 3668 threads
2026/10/01 22:45:25

PID    COMMAND          POWER
98492  iconservicesd    0.0
98045  naturallanguaged 0.0
Processes: 550 total, 6 running, 544 sleeping, 3664 threads
2026/10/01 22:45:26
Load Avg: 3.34, 5.47, 5.61

PID    COMMAND          POWER
8281   swift-frontend   69.4
71892  Google Chrome He 26.3
458    WindowServer     18.8
2710   com.docker.backe 12.0
465    coreaudiod       10.0
1      launchd          8.0
8447   top              5.3
1590   Google Chrome    5.3
"""

/// Where each recorded pid ran from (top truncates COMMAND, so the reader asks for the path).
private let recordedPaths: [Int32: String] = [
    8281: "/Library/Developer/CommandLineTools/usr/bin/swift-frontend",
    71892: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/140.0/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)",
    458: "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer",
    2710: "/Applications/Docker.app/Contents/MacOS/com.docker.backend",
    465: "/usr/sbin/coreaudiod",
    1: "/sbin/launchd",
    8447: "/usr/bin/top",
    1590: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
]

/// `ioreg -r -a -k BatteryPercent` for a Magic Keyboard and a Magic Mouse. Synthesized in the shape
/// ioreg prints (nothing with a battery was connected when the R28 probe ran).
private let recordedIoreg = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
  <dict>
    <key>IOObjectClass</key><string>AppleDeviceManagementHIDEventService</string>
    <key>Product</key><string>Magic Keyboard</string>
    <key>DeviceAddress</key><string>d0-c0-50-11-22-33</string>
    <key>Transport</key><string>Bluetooth</string>
    <key>BatteryPercent</key><integer>67</integer>
  </dict>
  <dict>
    <key>IOObjectClass</key><string>AppleDeviceManagementHIDEventService</string>
    <key>Product</key><string>Magic Mouse</string>
    <key>DeviceAddress</key><string>d0-c0-50-44-55-66</string>
    <key>BatteryPercent</key><integer>9</integer>
  </dict>
</array>
</plist>
"""

/// `system_profiler -json SPBluetoothDataType`: the structure and the not-connected AirPods are as
/// the R28 probe recorded them; the connected section is synthesized with the battery keys the
/// reporter names (device_batteryLevelLeft/Right/Case/Main). The keyboard is the same one ioreg lists.
private let recordedSystemProfiler = """
{
  "SPBluetoothDataType" : [
    {
      "controller_properties" : { "controller_state" : "attrib_on" },
      "device_connected" : [
        { "AirPods Pro" : {
            "device_address" : "00:11:22:33:44:55", "device_minorType" : "Headphones",
            "device_productID" : "0x2027", "device_vendorID" : "0x004C",
            "device_batteryLevelCase" : "50%", "device_batteryLevelLeft" : "80%", "device_batteryLevelRight" : "75%" } },
        { "Magic Keyboard" : {
            "device_address" : "D0:C0:50:11:22:33", "device_minorType" : "Keyboard",
            "device_batteryLevelMain" : "67%" } },
        { "Bose QC" : { "device_address" : "AA:BB:CC:DD:EE:FF", "device_minorType" : "Headphones" } }
      ],
      "device_not_connected" : [
        { "Spare AirPods Pro" : {
            "device_address" : "00:11:22:33:44:66", "device_minorType" : "Headphones",
            "device_productID" : "0x200E", "device_vendorID" : "0x004C" } }
      ]
    }
  ]
}
"""

// MARK: - Readers

@Test func R28__top_output_ranks_apps_by_their_summed_power() {
    let power = AppEnergyReader.parseTop(recordedTop)
    #expect(power[71892] == 26.3)
    #expect(power[98492] == nil, "the first sample does not count")

    let apps = AppEnergyReader.rank(power) { recordedPaths[$0].flatMap(AppEnergyReader.appBundlePath(forExecutable:)) }
    // Chrome's helper app counts toward Chrome; processes outside an .app are not apps.
    #expect(apps == [
        AppEnergy(bundlePath: "/Applications/Google Chrome.app", name: "Google Chrome", power: 26.3 + 5.3),
        AppEnergy(bundlePath: "/Applications/Docker.app", name: "Docker", power: 12.0),
    ])
}

@Test func R28__ioreg_and_system_profiler_outputs_parse_to_connected_peripherals() throws {
    let entries = try #require(try PropertyListSerialization.propertyList(from: Data(recordedIoreg.utf8), format: nil) as? [[String: Any]])
    let hid = entries.compactMap(PeripheralBattery.init(registryEntry:))
    #expect(hid == [
        PeripheralBattery(id: "d0c050112233", name: "Magic Keyboard", kind: .keyboard, levels: [.init(part: .main, percentage: 67)]),
        PeripheralBattery(id: "d0c050445566", name: "Magic Mouse", kind: .mouse, levels: [.init(part: .main, percentage: 9)]),
    ])

    // Only connected devices that report a level; the keyboard is listed by both tools.
    let bluetooth = PeripheralBattery.bluetoothDevices(systemProfilerJSON: Data(recordedSystemProfiler.utf8))
    #expect(bluetooth.map(\.name) == ["AirPods Pro", "Magic Keyboard"])
    let airPods = try #require(bluetooth.first)
    #expect(airPods.id == "001122334455")
    #expect(airPods.kind == .airPodsPro)
    #expect(airPods.levels == [.init(part: .left, percentage: 80), .init(part: .right, percentage: 75), .init(part: .case, percentage: 50)])
    #expect(airPods.levelsText == "왼쪽 80% · 오른쪽 75% · 케이스 50%")

    let merged = PeripheralBattery.merge(hid: hid, bluetooth: bluetooth)
    #expect(merged.map(\.id).sorted() == ["001122334455", "d0c050112233", "d0c050445566"])
    #expect(merged.map(\.name) == merged.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    for kind in [PeripheralBattery.Kind.airPods, .airPodsPro, .headphones, .keyboard, .mouse, .trackpad, .other] {
        #expect(NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil) != nil, "\(kind.symbol)")
    }
}

// MARK: - Screen

private let injectedApps = [
    AppEnergy(bundlePath: "/Applications/Safari.app", name: "Safari", power: 41.2),
    AppEnergy(bundlePath: "/System/Applications/Music.app", name: "음악", power: 12.5),
    AppEnergy(bundlePath: "/System/Applications/Calendar.app", name: "캘린더", power: 3.1),
]

private let injectedPeripherals = [
    PeripheralBattery(id: "001122334455", name: "AirPods Pro", kind: .airPodsPro,
                      levels: [.init(part: .left, percentage: 80), .init(part: .right, percentage: 75), .init(part: .case, percentage: 50)]),
    PeripheralBattery(id: "d0c050112233", name: "Magic Keyboard", kind: .keyboard, levels: [.init(part: .main, percentage: 67)]),
    PeripheralBattery(id: "d0c050445566", name: "Magic Mouse", kind: .mouse, levels: [.init(part: .main, percentage: 9)]),
]

private let onBattery = PowerStatus(percentage: 70, isExternalPowerConnected: false, isCharging: false, isFullyCharged: false,
                                    timeToEmpty: .minutes(339), timeToFull: nil)

@MainActor
private func screen(apps: [AppEnergy], peripherals: [PeripheralBattery]) -> BatteryView {
    let model = BatteryModel(sampler: nil)
    model.status = onBattery
    model.detail = BatteryDetail(apps: apps, peripherals: peripherals)
    return BatteryView(model: model)
}

/// With app energy rows and peripherals injected, both lists show below the MacBook battery; a list
/// with nothing in it takes no room. The screen still draws to its edges and fits the notch.
@MainActor
@Test func R28__battery_screen_shows_power_hungry_apps_and_peripherals() throws {
    let cases: [(String, [AppEnergy], [PeripheralBattery])] = [
        ("none", [], []),
        ("apps", injectedApps, []),
        ("peripherals", [], injectedPeripherals),
        ("both", injectedApps, injectedPeripherals),
    ]
    var heights: [String: CGFloat] = [:]
    for (name, apps, peripherals) in cases {
        let view = screen(apps: apps, peripherals: peripherals)
        let size = NSHostingView(rootView: view).fittingSize
        heights[name] = size.height
        print("R28 render \(name): \(size)")
        #expect(size.width <= 390 && size.height <= 400, "\(name): \(size) does not fit the notch's 390×400")
        var insets = try inkInsets(view)
        insets.left -= try inkInsets(Image(systemName: onBattery.glyph).font(.system(size: 44))).left
        expectNoOuterSpace(insets, "R28 \(name)")
        try captureRender(view, named: "R28-render-\(name)")
    }
    let none = try #require(heights["none"]), apps = try #require(heights["apps"])
    let peripherals = try #require(heights["peripherals"]), both = try #require(heights["both"])
    #expect(apps > none + 60, "the app list adds its heading and three rows")
    #expect(peripherals > none + 60, "the peripheral list adds its heading and three rows")
    #expect(both > apps + 60 && both > peripherals + 60)
}

/// The screen samples only while it is on screen: mounting it starts sampling, taking it away
/// stops it and forgets the readings, so the next visit does not show old ones.
@MainActor
@Test func R28__screen_samples_only_while_it_is_shown() async throws {
    let counter = SampleCounter()
    let model = BatteryModel(sampler: {
        await counter.increment()
        return BatteryDetail(apps: injectedApps, peripherals: injectedPeripherals)
    }, interval: .milliseconds(20))
    model.status = onBattery
    #expect(await counter.count == 0)

    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 390, height: 400), styleMask: [.borderless], backing: .buffered, defer: true)
    window.contentView = NSHostingView(rootView: BatteryView(model: model))
    for _ in 0..<100 where await counter.count < 3 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(await counter.count >= 3, "sampling started and repeated while shown")
    #expect(model.detail.apps == injectedApps)

    window.contentView = nil
    try await Task.sleep(for: .milliseconds(200))
    let stopped = await counter.count
    try await Task.sleep(for: .milliseconds(200))
    #expect(await counter.count == stopped, "no sampling after the screen went away")
    #expect(model.detail == BatteryDetail())
}

private actor SampleCounter {
    var count = 0
    func increment() { count += 1 }
}

@MainActor
private func captureRender(_ view: some View, named name: String) throws {
    guard let directory = ProcessInfo.processInfo.environment["BATTERY_CAPTURE_DIR"] else { return }
    let hosting = NSHostingView(rootView: view.padding(16).background(.black).environment(\.colorScheme, .dark))
    hosting.appearance = NSAppearance(named: .darkAqua)
    hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
    hosting.layoutSubtreeIfNeeded()
    let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    let png = try #require(rep.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
}

// MARK: - Live, against the system tools at the same time

/// Runs a tool and returns what it printed.
private func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let environment { process.environment = environment }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return data
}

/// pid → POWER from the last sample of an independent `top -l 2 -o power` run, read with its own
/// pattern rather than the reader's parser.
private func referenceTop() async throws -> [Int32: Double] {
    let output = try await Task.detached {
        String(decoding: try run("/usr/bin/top", ["-l", "2", "-s", "1", "-o", "power", "-stats", "pid,power"], environment: ["LC_ALL": "C"]), as: UTF8.self)
    }.value
    let lastSample = try #require(output.components(separatedBy: "PID ").last)
    var power: [Int32: Double] = [:]
    for match in lastSample.matches(of: /(?m)^\s*(\d+)\s+(\d+(?:\.\d+)?)\s*$/) {
        if let pid = Int32(match.1), let value = Double(match.2) { power[pid] = value }
    }
    return power
}

/// Two scores agree when they are within 2 points or 30% of the larger one: top's energy impact
/// moves from second to second, and two tops never sample exactly the same instant.
private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= max(2, 0.3 * max(a, b)) }

/// The top apps the reader ranks while an independent `top -o power` samples the same second
/// come in the order top's scores put them, allowing for ties and apps moving between samples
/// (`close`), and no app top scores clearly higher is missing. Up to three attempts, each printed.
@Test func R28__live_top_apps_match_top_power_order() async throws {
    var failures: [String] = []
    for attempt in 1...3 {
        async let ours = AppEnergyReader.read()
        async let reference = referenceTop()
        let (apps, power) = try await (ours, reference)
        let referenceApps = AppEnergyReader.rank(power) { pid in
            AppEnergyReader.executablePath(of: pid).flatMap(AppEnergyReader.appBundlePath(forExecutable:))
        }
        let score = Dictionary(referenceApps.map { ($0.bundlePath, $0.power) }, uniquingKeysWith: +)
        print("R28 attempt \(attempt) reader: \(apps.map { "\($0.name) \($0.power)" })")
        print("R28 attempt \(attempt) top -o power: \(referenceApps.prefix(5).map { "\($0.name) \($0.power)" })")

        var problems: [String] = []
        for (earlier, later) in zip(apps, apps.dropFirst()) {
            let (a, b) = (score[earlier.bundlePath] ?? 0, score[later.bundlePath] ?? 0)
            if b > a && !close(a, b) { problems.append("\(later.name) (\(b)) is clearly above \(earlier.name) (\(a)) in top") }
        }
        let floor = apps.count == AppEnergyReader.limit ? apps.last.map { score[$0.bundlePath] ?? 0 } ?? 0 : 0
        for app in referenceApps where !apps.contains(where: { $0.bundlePath == app.bundlePath }) {
            if app.power > floor && !close(app.power, floor) { problems.append("\(app.name) (\(app.power)) is missing") }
        }
        if problems.isEmpty { return }
        failures.append("attempt \(attempt): \(problems.joined(separator: "; "))")
    }
    Issue.record("the reader's order did not match top -o power: \(failures.joined(separator: " | "))")
}

/// Peripherals with a battery that ioreg or system_profiler lists right now.
private func toolPeripherals() throws -> [PeripheralBattery] {
    let ioreg = try run("/usr/sbin/ioreg", ["-r", "-a", "-k", "BatteryPercent"])
    let entries = ioreg.isEmpty ? [] : (try PropertyListSerialization.propertyList(from: ioreg, format: nil) as? [[String: Any]]) ?? []
    let bluetooth = PeripheralBattery.bluetoothDevices(systemProfilerJSON: try run("/usr/sbin/system_profiler", ["-json", "SPBluetoothDataType"]))
    return PeripheralBattery.merge(hid: entries.compactMap(PeripheralBattery.init(registryEntry:)), bluetooth: bluetooth)
}

private let somePeripheralConnected = ((try? toolPeripherals()) ?? []).isEmpty == false

/// The reader's peripherals equal what ioreg and system_profiler report at the same time. Read
/// twice, interleaved, so a level ticking between the reads retries instead of failing.
@Test(.enabled(if: somePeripheralConnected, "no peripheral with a battery is connected: ioreg -k BatteryPercent and system_profiler's device_connected list none"))
func R28__live_peripherals_match_ioreg_and_system_profiler() async throws {
    for attempt in 1...3 {
        let ours = await PeripheralReader.read()
        let tools = try toolPeripherals()
        let oursAgain = await PeripheralReader.read()
        print("R28 attempt \(attempt) reader: \(ours.map { "\($0.name) \($0.levelsText)" })")
        print("R28 attempt \(attempt) ioreg + system_profiler: \(tools.map { "\($0.name) \($0.levelsText)" })")
        if ours == oursAgain {
            #expect(ours == tools)
            #expect(!ours.isEmpty)
            return
        }
    }
    Issue.record("the peripherals changed during every attempt")
}
