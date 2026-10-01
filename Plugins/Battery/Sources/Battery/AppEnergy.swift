import Darwin
import Foundation

/// One app's energy impact: top's POWER score (the one Activity Monitor shows as energy impact),
/// summed over every process that runs from the app's bundle.
struct AppEnergy: Equatable, Sendable {
    /// The outermost `.app` the processes run from; Chrome's helper apps count toward Chrome.
    var bundlePath: String
    var name: String
    var power: Double
}

/// Ranks apps by top's energy impact. The score needs task ports that only top may read, so the
/// reader runs top itself instead of computing a different measure (see the R28 probe).
enum AppEnergyReader {
    /// How many apps the screen shows.
    static let limit = 3

    /// Two samples a second apart: the first sample's POWER is always 0, the second covers that second.
    static let topArguments = ["-l", "2", "-s", "1", "-stats", "pid,power"]

    /// The two samples take about 1.5 s; a top still running after 5 s has stalled and is terminated.
    static let topTimeout: Duration = .seconds(5)

    /// The apps using the most energy right now, highest first. Takes about 1.5 s; processes outside
    /// an app (daemons, command line tools, top itself) are not counted, and NotchTheRock counts like
    /// any other app.
    static func read() async throws -> [AppEnergy] {
        let output = try await toolOutput("/usr/bin/top", topArguments, environment: ["LC_ALL": "C"], timeout: topTimeout)
        let power = parseTop(String(decoding: output, as: UTF8.self))
        let apps = rank(power) { pid in executablePath(of: pid).flatMap(appBundlePath(forExecutable:)) }
        return Array(apps.prefix(limit))
    }

    /// pid → POWER from the last sample of top's output: the first column is the pid and the last
    /// the score, whatever columns lie between.
    static func parseTop(_ output: String) -> [Int32: Double] {
        let lines = output.split(separator: "\n")
        guard let header = lines.lastIndex(where: { $0.hasPrefix("PID") }) else { return [:] }
        var power: [Int32: Double] = [:]
        for line in lines[(header + 1)...] {
            let fields = line.split(separator: " ")
            guard let first = fields.first, let pid = Int32(first),
                  let last = fields.last, fields.count >= 2, let value = Double(last)
            else { continue }
            power[pid] = value
        }
        return power
    }

    /// Sums the scores per app, drops processes outside an app and apps at 0, and orders the rest
    /// highest first (by name on a tie, so equal scores keep their places).
    static func rank(_ power: [Int32: Double], appPath: (Int32) -> String?) -> [AppEnergy] {
        var totals: [String: Double] = [:]
        for (pid, value) in power where value > 0 {
            guard let path = appPath(pid) else { continue }
            totals[path, default: 0] += value
        }
        return totals
            .map { AppEnergy(bundlePath: $0.key, name: appName(atBundlePath: $0.key), power: $0.value) }
            .sorted { ($0.power, $1.name) > ($1.power, $0.name) }
    }

    /// The outermost `.app` in an executable's path, or nil when it does not run from an app.
    static func appBundlePath(forExecutable path: String) -> String? {
        let components = URL(fileURLWithPath: path).pathComponents
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return NSString.path(withComponents: Array(components[...index]))
    }

    /// The executable a process runs, or nil when it has exited or belongs to another user.
    static func executablePath(of pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer[..<Int(length)], as: UTF8.self)
    }

    /// The name Finder shows for the app, without the `.app` extension.
    static func appName(atBundlePath path: String) -> String {
        let name = FileManager.default.displayName(atPath: path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
