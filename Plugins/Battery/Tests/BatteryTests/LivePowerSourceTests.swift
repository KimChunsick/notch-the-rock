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

@Test(.enabled(if: PowerSourceMonitor.read() != nil, "this Mac has no internal battery"))
func R10__live_power_source_matches_pmset() throws {
    let status = try #require(PowerSourceMonitor.read())
    let pmset = try #require(try pmsetBatt(), "pmset -g batt printed no internal battery line")

    print("pmset: \(pmset.line) | external power: \(pmset.isExternalPowerConnected)")
    print("model: \(status.percentageText); \(status.state); \(status.stateTitle); \(status.remainingText ?? "-") | external power: \(status.isExternalPowerConnected)")

    #expect(abs(status.percentage - pmset.percentage) <= 1)
    #expect(status.state == pmset.state)
    #expect(status.isExternalPowerConnected == pmset.isExternalPowerConnected)
}
