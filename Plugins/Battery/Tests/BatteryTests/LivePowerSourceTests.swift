import Foundation
import Testing
@testable import Battery

/// What `pmset -g batt` prints for the internal battery.
private struct PmsetReading {
    let percentage: Int
    let state: PowerStatus.State
    let isExternalPowerConnected: Bool
    let line: String
}

/// Parses e.g. "Now drawing from 'Battery Power'" and
/// " -InternalBattery-0 (id=25952355)	60%; discharging; 7:09 remaining present: true".
private func pmsetBatt() throws -> PmsetReading? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = ["-g", "batt"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()

    guard let line = output.split(separator: "\n").first(where: { $0.contains("InternalBattery") }),
          let match = line.firstMatch(of: /(\d+)%; ([^;]+);/),
          let percentage = Int(match.1)
    else { return nil }
    let state: PowerStatus.State
    switch match.2 {
    case "charging", "finishing charge": state = .charging
    case "charged": state = .charged
    case "AC attached": state = .notCharging
    case "discharging": state = .discharging
    default: return nil
    }
    return PmsetReading(
        percentage: percentage,
        state: state,
        isExternalPowerConnected: output.contains("Now drawing from 'AC Power'"),
        line: line.trimmingCharacters(in: .whitespaces)
    )
}

/// An IOKit reading and a `pmset -g batt` reading taken while neither source changed. The two are
/// read twice, interleaved (IOKit, pmset, IOKit, pmset), so a level or state change landing between
/// any two reads makes one source differ from its own second read instead of passing as a mismatch.
/// Only the compared fields count: the remaining time moves too often to wait for.
private func stableReadings(attempts: Int = 5) throws -> (status: PowerStatus, pmset: PmsetReading)? {
    for attempt in 1...attempts {
        let status = PowerSourceMonitor.read()
        let pmset = try pmsetBatt()
        let statusAgain = PowerSourceMonitor.read()
        let pmsetAgain = try pmsetBatt()
        if let status, let pmset, let statusAgain, let pmsetAgain,
           (status.percentage, status.state, status.isExternalPowerConnected)
               == (statusAgain.percentage, statusAgain.state, statusAgain.isExternalPowerConnected),
           (pmset.percentage, pmset.state, pmset.isExternalPowerConnected)
               == (pmsetAgain.percentage, pmsetAgain.state, pmsetAgain.isExternalPowerConnected) {
            return (status, pmset)
        }
        if attempt < attempts { Thread.sleep(forTimeInterval: 1) }
    }
    return nil
}

@Test(.enabled(if: PowerSourceMonitor.read() != nil, "this Mac has no internal battery"))
func R10__live_power_source_matches_pmset() throws {
    let (status, pmset) = try #require(
        try stableReadings(),
        "IOKit and pmset -g batt gave no stable internal battery reading in 5 attempts"
    )

    print("pmset: \(pmset.line) | external power: \(pmset.isExternalPowerConnected)")
    print("model: \(status.percentageText); \(status.state); \(status.stateTitle); \(status.remainingText ?? "-") | external power: \(status.isExternalPowerConnected)")

    #expect(status.percentage == pmset.percentage)
    #expect(status.state == pmset.state)
    #expect(status.isExternalPowerConnected == pmset.isExternalPowerConnected)
}
