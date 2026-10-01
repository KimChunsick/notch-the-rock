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
    <key>DeviceAddress</key><string>00-11-22-aa-bb-01</string>
    <key>Transport</key><string>Bluetooth</string>
    <key>BatteryPercent</key><integer>67</integer>
  </dict>
  <dict>
    <key>IOObjectClass</key><string>AppleDeviceManagementHIDEventService</string>
    <key>Product</key><string>Magic Mouse</string>
    <key>DeviceAddress</key><string>00-11-22-aa-bb-02</string>
    <key>BatteryPercent</key><integer>9</integer>
  </dict>
</array>
</plist>
"""

/// `system_profiler -json SPBluetoothDataType`: the structure is as the R28 probe recorded it; the
/// connected section is synthesized with the battery keys the reporter names
/// (device_batteryLevelLeft/Right/Case/Main). The keyboard is the same one ioreg lists. Device names
/// and addresses here are made up: real paired-device output stays out of tracked files.
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
            "device_address" : "00:11:22:AA:BB:01", "device_minorType" : "Keyboard",
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
        PeripheralBattery(id: "001122aabb01", name: "Magic Keyboard", kind: .keyboard, levels: [.init(part: .main, percentage: 67)]),
        PeripheralBattery(id: "001122aabb02", name: "Magic Mouse", kind: .mouse, levels: [.init(part: .main, percentage: 9)]),
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
    #expect(merged.map(\.id).sorted() == ["001122334455", "001122aabb01", "001122aabb02"])
    #expect(merged.map(\.name) == merged.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending })

    // The live test's own extraction finds the same devices and levels in the same output.
    let reference = toolPeripherals(ioreg: Data(recordedIoreg.utf8), systemProfiler: Data(recordedSystemProfiler.utf8))
    #expect(reference.map(\.key).sorted() == [
        "AirPods Pro: case 50, left 80, right 75", "Magic Keyboard: main 67", "Magic Mouse: main 9",
    ])
    #expect(merged.map(ToolPeripheral.init(shown:)).map(\.key).sorted() == reference.map(\.key).sorted())
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
    PeripheralBattery(id: "001122aabb01", name: "Magic Keyboard", kind: .keyboard, levels: [.init(part: .main, percentage: 67)]),
    PeripheralBattery(id: "001122aabb02", name: "Magic Mouse", kind: .mouse, levels: [.init(part: .main, percentage: 9)]),
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

/// The screen closes while its sample is still running and opens again: the new visit shows its
/// sample, and when the closed visit's late sample finally comes back, that old run neither shows
/// it nor clears the new visit's lists. Calls the same `sampleWhileShown()` the view's `.task` runs,
/// so the test can wait for the old run to end.
@MainActor
@Test func R28__a_closed_visit_leaves_the_lists_of_a_newer_visit_alone() async throws {
    let stale = BatteryDetail(apps: [injectedApps[0]], peripherals: [])
    let fresh = BatteryDetail(apps: injectedApps, peripherals: injectedPeripherals)
    let sampler = HeldSampler(first: stale, later: fresh)
    // A long interval: the new visit samples once, so it cannot cover up what the old run does.
    let model = BatteryModel(sampler: { await sampler.sample() }, interval: .seconds(60))

    let closed = Task { await model.sampleWhileShown() }
    for _ in 0..<200 where await !sampler.isHolding { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await sampler.isHolding, "the first visit's sample is still running")
    closed.cancel()

    let reopened = Task { await model.sampleWhileShown() }
    for _ in 0..<200 where model.detail != fresh { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.detail == fresh, "the new visit shows its sample")

    await sampler.release()
    await closed.value
    #expect(model.detail == fresh, "the closed visit's late sample and its cleanup leave the new lists alone")

    reopened.cancel()
    await reopened.value
    #expect(model.detail == BatteryDetail(), "closing the current visit still forgets its readings")
}

/// The first sample waits until `release()`, like a slow top; every later one returns at once.
private actor HeldSampler {
    let first: BatteryDetail
    let later: BatteryDetail
    private var calls = 0
    private var held: CheckedContinuation<Void, Never>?

    init(first: BatteryDetail, later: BatteryDetail) {
        self.first = first
        self.later = later
    }

    var isHolding: Bool { held != nil }

    func sample() async -> BatteryDetail {
        calls += 1
        guard calls == 1 else { return later }
        await withCheckedContinuation { held = $0 }
        return first
    }

    func release() {
        held?.resume()
        held = nil
    }
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


// MARK: - Tools

/// A stand-in for a stalled tool: a shell that writes its pid to a file and then becomes
/// `/bin/sleep 8` under the same pid.
private func stalledTool() -> (arguments: [String], pidFile: URL) {
    let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("battery-tool-\(UUID().uuidString).pid")
    return (["-c", "echo $$ > \"$0\"; exec /bin/sleep 8", pidFile.path], pidFile)
}

/// The pid the stalled tool wrote, once it has.
private func launchedPid(_ pidFile: URL) async throws -> pid_t {
    for _ in 0..<300 {
        if let text = try? String(contentsOf: pidFile, encoding: .utf8),
           let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return pid
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CocoaError(.fileReadNoSuchFile)
}

/// Whether the process is gone within 2 s, reaped too: an unreaped zombie still answers `kill(pid, 0)`.
private func processEnded(_ pid: pid_t) async throws -> Bool {
    for _ in 0..<200 {
        if kill(pid, 0) == -1 && errno == ESRCH { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return false
}

/// Closing the screen cancels its sample: the tool it runs is terminated and the call returns at
/// once instead of waiting for the tool.
@Test func R28__cancelling_a_tool_run_ends_the_tool() async throws {
    let (arguments, pidFile) = stalledTool()
    defer { try? FileManager.default.removeItem(at: pidFile) }
    let run = Task { try await toolOutput("/bin/sh", arguments, timeout: .seconds(30)) }
    let pid = try await launchedPid(pidFile)
    let cancelled = ContinuousClock.now
    run.cancel()
    let result = await run.result
    let waited = ContinuousClock.now - cancelled
    print("R28 cancelled tool \(pid): returned after \(waited)")
    #expect(waited < .seconds(2), "the call returns on cancellation instead of waiting for the tool")
    #expect(throws: CancellationError.self) { try result.get() }
    #expect(try await processEnded(pid), "the tool is gone after the cancellation")
}

/// A tool that runs past its timeout is terminated and the call reports the timeout, distinct from a
/// tool that exits with an error.
@Test func R28__a_tool_past_its_timeout_is_ended() async throws {
    let (arguments, pidFile) = stalledTool()
    defer { try? FileManager.default.removeItem(at: pidFile) }
    let started = ContinuousClock.now
    let run = Task { try await toolOutput("/bin/sh", arguments, timeout: .seconds(1)) }
    let pid = try await launchedPid(pidFile)
    let result = await run.result
    let waited = ContinuousClock.now - started
    print("R28 timed-out tool \(pid): returned after \(waited)")
    #expect(waited >= .seconds(1) && waited < .seconds(3), "the call returns at its 1 s timeout, not when the 8 s tool ends")
    #expect(throws: ToolError.timedOut(executable: "/bin/sh", after: .seconds(1))) { try result.get() }
    #expect(try await processEnded(pid), "the tool is gone after the timeout")
    await #expect(throws: ToolError.exited(executable: "/bin/sh", status: 3)) {
        try await toolOutput("/bin/sh", ["-c", "exit 3"], timeout: .seconds(5))
    }
}

// MARK: - Live: the screen against the system tools at the same time

/// Runs a tool and returns what it printed and its exit status.
private func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws -> (output: Data, status: Int32) {
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
    return (data, process.terminationStatus)
}

/// Shows the screen with the readers the plugin gives it and returns the first detail it publishes,
/// i.e. what the view renders, with `reference` read from the system tools while the screen samples.
@MainActor
private func showScreen<Reference: Sendable>(
    meanwhile reference: @escaping @Sendable () async throws -> Reference
) async throws -> (shown: BatteryDetail, reference: Reference) {
    let model = BatteryModel(sampler: BatteryDetail.sample)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 390, height: 400), styleMask: [.borderless], backing: .buffered, defer: true)
    async let tools = reference()
    window.contentView = NSHostingView(rootView: BatteryView(model: model))
    for _ in 0..<200 where model.detail == BatteryDetail() { try await Task.sleep(for: .milliseconds(50)) }
    let shown = model.detail
    window.contentView = nil
    return (shown, try await tools)
}

/// What an independent `top -l 2 -o power -stats pid,power` run left: what it printed once it exited
/// with status 0, or why it did not.
private enum TopReference: Sendable {
    case printed(String)
    case failed(String)
}

/// An independent `top -l 2 -o power` run, read with the test's own pattern rather than the reader's
/// parser.
@Sendable private func referenceTop() async -> TopReference {
    await Task.detached {
        do {
            let (output, status) = try run("/usr/bin/top", ["-l", "2", "-s", "1", "-o", "power", "-stats", "pid,power"], environment: ["LC_ALL": "C"])
            return status == 0 ? .printed(String(decoding: output, as: UTF8.self)) : .failed("top exited with status \(status)")
        } catch {
            return .failed("top did not launch: \(error)")
        }
    }.value
}

/// Two scores agree when they are within 2 points or 30% of the larger one: top's energy impact
/// moves from second to second, and two tops never sample exactly the same instant.
private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= max(2, 0.3 * max(a, b)) }

/// How the apps a screen shows compare with one reference top run.
private enum AppOrderCheck: Equatable {
    /// top's scores put the apps in the screen's order and no app top scores clearly higher is missing.
    case agrees
    /// What top's scores contradict on the screen.
    case disagrees([String])
    /// Why the run cannot judge the screen.
    case inconclusive(String)
}

/// Whether `apps` come in the order the last sample of `top` puts them (pid → POWER, apps summed by
/// `appPath` like the reader does), allowing for ties and apps moving between samples (`close`), with
/// no app top scores clearly higher missing. A run that failed, printed no pid/POWER row or scored no
/// app above 0 is inconclusive; with apps above 0 an empty screen disagrees. Also returns top's apps,
/// highest first, for printing.
private func checkAppOrder(_ apps: [AppEnergy], against top: TopReference, appPath: (Int32) -> String?) -> (check: AppOrderCheck, top: [AppEnergy]) {
    let output: String
    switch top {
    case .printed(let printed): output = printed
    case .failed(let reason): return (.inconclusive(reason), [])
    }
    let samples = output.components(separatedBy: "PID ")
    guard samples.count > 1, let lastSample = samples.last else { return (.inconclusive("top printed no PID header"), []) }
    var power: [Int32: Double] = [:]
    for match in lastSample.matches(of: /(?m)^\s*(\d+)\s+(\d+(?:\.\d+)?)\s*$/) {
        if let pid = Int32(match.1), let value = Double(match.2) { power[pid] = value }
    }
    guard !power.isEmpty else { return (.inconclusive("top's last sample has no pid/POWER row"), []) }
    let referenceApps = AppEnergyReader.rank(power, appPath: appPath)
    guard !referenceApps.isEmpty else { return (.inconclusive("top scored no app above 0 (\(power.count) processes)"), []) }
    guard !apps.isEmpty else { return (.disagrees(["the screen shows no app while top scores \(referenceApps.count) above 0"]), referenceApps) }
    let score = Dictionary(referenceApps.map { ($0.bundlePath, $0.power) }, uniquingKeysWith: +)
    var problems: [String] = []
    for (earlier, later) in zip(apps, apps.dropFirst()) {
        let (a, b) = (score[earlier.bundlePath] ?? 0, score[later.bundlePath] ?? 0)
        if b > a && !close(a, b) { problems.append("\(later.name) (\(b)) is clearly above \(earlier.name) (\(a)) in top") }
    }
    let floor = apps.count == AppEnergyReader.limit ? apps.last.map { score[$0.bundlePath] ?? 0 } ?? 0 : 0
    for app in referenceApps where !apps.contains(where: { $0.bundlePath == app.bundlePath }) {
        if app.power > floor && !close(app.power, floor) { problems.append("\(app.name) (\(app.power)) is missing") }
    }
    return (problems.isEmpty ? .agrees : .disagrees(problems), referenceApps)
}

/// A reference top run that failed, printed nothing usable or scored no app above 0 cannot judge the
/// screen: it is inconclusive, never agreement. A usable run still catches a wrong order.
@Test func R28__app_order_check_needs_a_usable_top_reference() {
    let paths: [Int32: String] = [101: "/Applications/Alpha.app/Contents/MacOS/Alpha",
                                  102: "/Applications/Beta.app/Contents/MacOS/Beta",
                                  103: "/usr/libexec/somedaemon"]
    let appPath = { (pid: Int32) in paths[pid].flatMap(AppEnergyReader.appBundlePath(forExecutable:)) }
    let alpha = AppEnergy(bundlePath: "/Applications/Alpha.app", name: "Alpha", power: 30)
    let beta = AppEnergy(bundlePath: "/Applications/Beta.app", name: "Beta", power: 5)
    let usable = """
    Processes: 400 total, 2 running, 398 sleeping, 2000 threads

    PID    POWER
    101    0.0
    102    0.0
    Processes: 400 total, 3 running, 397 sleeping, 2001 threads

    PID    POWER
    101    30.2
    102    4.8
    103    50.0
    """
    let allZero = usable.replacingOccurrences(of: "30.2", with: "0.0").replacingOccurrences(of: "4.8", with: "0.0")

    func isInconclusive(_ check: AppOrderCheck) -> Bool {
        if case .inconclusive = check { return true }
        return false
    }
    #expect(isInconclusive(checkAppOrder([alpha, beta], against: .printed(""), appPath: appPath).check), "an empty top output")
    #expect(isInconclusive(checkAppOrder([alpha, beta], against: .printed("top: failed to sample\n"), appPath: appPath).check), "an unparseable top output")
    #expect(isInconclusive(checkAppOrder([alpha, beta], against: .printed(allZero), appPath: appPath).check), "a sample with every app at 0")
    #expect(isInconclusive(checkAppOrder([alpha, beta], against: .failed("top exited with status 1"), appPath: appPath).check), "a failed top run")
    #expect(checkAppOrder([alpha, beta], against: .printed(usable), appPath: appPath).check == .agrees)
    #expect(checkAppOrder([beta, alpha], against: .printed(usable), appPath: appPath).check == .disagrees(["Alpha (30.2) is clearly above Beta (4.8) in top"]))
    #expect(checkAppOrder([], against: .printed(usable), appPath: appPath).check == .disagrees(["the screen shows no app while top scores 2 above 0"]))
}

/// The apps the running screen shows, while an independent `top -o power` samples the same second,
/// agree with top (`checkAppOrder`). Up to three attempts, each printed; an attempt whose top run
/// cannot judge the screen is retried, and when none can, the test is skipped with their reasons.
@MainActor
@Test func R28__live_screen_apps_match_top_power_order() async throws {
    var failures: [String] = []
    var inconclusive: [String] = []
    for attempt in 1...3 {
        let (shown, top) = try await showScreen(meanwhile: referenceTop)
        let (check, topApps) = checkAppOrder(shown.apps, against: top) { pid in
            AppEnergyReader.executablePath(of: pid).flatMap(AppEnergyReader.appBundlePath(forExecutable:))
        }
        print("R28 attempt \(attempt) screen: \(shown.apps.map { "\($0.name) \($0.power)" })")
        print("R28 attempt \(attempt) top -o power: \(topApps.prefix(5).map { "\($0.name) \($0.power)" }) — \(check)")
        switch check {
        case .agrees: return
        case .disagrees(let problems): failures.append("attempt \(attempt): \(problems.joined(separator: "; "))")
        case .inconclusive(let reason): inconclusive.append("attempt \(attempt): \(reason)")
        }
    }
    if failures.isEmpty { try Test.cancel("no top -o power run could judge the screen: \(inconclusive.joined(separator: " | "))") }
    Issue.record("the screen's app order did not match top -o power: \((failures + inconclusive).joined(separator: " | "))")
}

/// A connected device with a battery as the test reads it from the tools' raw output: its name and
/// each battery's level by part ("main", "left", "right", "case").
private struct ToolPeripheral: Equatable, Sendable {
    var name: String
    var levels: [String: Int]

    /// "AirPods Pro: case 50, left 80, right 75", for comparing and printing.
    var key: String { "\(name): " + levels.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") }
}

extension ToolPeripheral {
    /// A row of the screen in the same terms.
    init(shown device: PeripheralBattery) {
        self.init(name: device.name, levels: Dictionary(device.levels.map { (String(describing: $0.part), $0.percentage) }, uniquingKeysWith: { $1 }))
    }
}

/// The connected devices with a battery level in raw `ioreg -r -a -k BatteryPercent` and
/// `system_profiler -json SPBluetoothDataType` output, extracted here rather than with the reader's
/// parser and merge: every registry entry with a product name, then each connected Bluetooth device
/// that reports a level and whose address the registry does not list.
private func toolPeripherals(ioreg: Data, systemProfiler: Data) -> [ToolPeripheral] {
    func address(_ value: Any?) -> String? {
        let digits = "\(value ?? "")".lowercased().filter(\.isHexDigit)
        return digits.isEmpty ? nil : digits
    }
    var devices: [ToolPeripheral] = []
    var registryAddresses = Set<String>()
    let registry = (try? PropertyListSerialization.propertyList(from: ioreg, format: nil)) as? [[String: Any]] ?? []
    for entry in registry {
        guard let name = entry["Product"] as? String, let level = entry["BatteryPercent"] as? Int else { continue }
        if let address = address(entry["DeviceAddress"]) { registryAddresses.insert(address) }
        devices.append(ToolPeripheral(name: name, levels: ["main": level]))
    }
    let root = (try? JSONSerialization.jsonObject(with: systemProfiler)) as? [String: Any]
    for controller in root?["SPBluetoothDataType"] as? [[String: Any]] ?? [] {
        for group in controller["device_connected"] as? [[String: [String: Any]]] ?? [] {
            for (name, properties) in group {
                if let address = address(properties["device_address"]), registryAddresses.contains(address) { continue }
                var levels: [String: Int] = [:]
                for (key, value) in properties where key.hasPrefix("device_batteryLevel") {
                    let part = key.dropFirst("device_batteryLevel".count).lowercased()
                    if let level = Int("\(value)".replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) {
                        levels[part] = level
                    }
                }
                if !levels.isEmpty { devices.append(ToolPeripheral(name: name, levels: levels)) }
            }
        }
    }
    return devices
}

/// What ioreg and system_profiler list right now.
@Sendable private func rawToolPeripherals() async throws -> [ToolPeripheral] {
    try await Task.detached {
        toolPeripherals(ioreg: try run("/usr/sbin/ioreg", ["-r", "-a", "-k", "BatteryPercent"]).output,
                        systemProfiler: try run("/usr/sbin/system_profiler", ["-json", "SPBluetoothDataType"]).output)
    }.value
}

/// Whether the raw tool output shows any connected device with a battery; nothing else skips the test.
private let rawPeripheralConnected: Bool = {
    guard let ioreg = try? run("/usr/sbin/ioreg", ["-r", "-a", "-k", "BatteryPercent"]).output,
          let systemProfiler = try? run("/usr/sbin/system_profiler", ["-json", "SPBluetoothDataType"]).output
    else { return false }
    return !toolPeripherals(ioreg: ioreg, systemProfiler: systemProfiler).isEmpty
}()

/// The peripherals the running screen shows equal what ioreg and system_profiler report while it
/// samples. A level ticking between the two reads retries, up to three attempts, each printed.
@MainActor
@Test(.enabled(if: rawPeripheralConnected, "no connected device with a battery: raw ioreg -k BatteryPercent and system_profiler device_connected output list none"))
func R28__live_screen_peripherals_match_ioreg_and_system_profiler() async throws {
    var failures: [String] = []
    for attempt in 1...3 {
        let (shown, tools) = try await showScreen(meanwhile: rawToolPeripherals)
        let screen = shown.peripherals.map(ToolPeripheral.init(shown:)).map(\.key).sorted()
        let expected = tools.map(\.key).sorted()
        print("R28 attempt \(attempt) screen: \(screen)")
        print("R28 attempt \(attempt) ioreg + system_profiler: \(expected)")
        if screen == expected && !expected.isEmpty { return }
        failures.append("attempt \(attempt): screen \(screen) vs tools \(expected)")
    }
    Issue.record("the screen's peripherals did not match ioreg and system_profiler: \(failures.joined(separator: " | "))")
}

// MARK: - A wider offer

/// Offered more width than its own, as the host does when the band beside the camera makes the
/// notch wider than the screen, the screen spreads to both edges of the offer without wrapping; at
/// its own width it keeps today's size.
@MainActor
@Test func R15__battery_screen_fills_a_wider_offer() throws {
    // Today's sizes: the battery alone, and with both lists.
    let cases: [(String, [AppEnergy], [PeripheralBattery], CGSize)] = [
        ("none", [], [], CGSize(width: 165, height: 76)),
        ("both", injectedApps, injectedPeripherals, CGSize(width: 335, height: 277)),
    ]
    for (name, apps, peripherals, today) in cases {
        let view = screen(apps: apps, peripherals: peripherals)
        let ideal = NSHostingView(rootView: view).fittingSize
        #expect(abs(ideal.width - today.width) <= 0.5 && abs(ideal.height - today.height) <= 0.5, "\(name): the screen's own size changed: \(ideal)")
        let offered = ideal.width + 80
        let wide = NSHostingView(rootView: view.frame(width: offered)).fittingSize
        #expect(abs(wide.height - ideal.height) <= 1, "\(name): wrapped or cut at \(offered) pt: \(wide) vs \(ideal)")
        var insets = try inkInsets(view.frame(width: offered))
        insets.left -= try inkInsets(Image(systemName: onBattery.glyph).font(.system(size: 44))).left
        print("R15 battery \(name) ideal \(ideal), offered \(offered) pt: ink insets left \(insets.left) right \(insets.right)")
        #expect(insets.left <= 2 && insets.right <= 2, "\(name): the screen does not reach both edges of a \(offered) pt offer: \(insets)")
    }
}
