import Foundation
import NotchKit
import Testing
@testable import NotchTheRock

struct FixtureFailure: Error, CustomStringConvertible {
    let description: String
}

/// The template plugin, scaffolded by `scripts/new-plugin.sh` and packaged by
/// `scripts/build-plugin.sh` once per test process. The package stays in the repository's `.build/`
/// so later runs rebuild incrementally.
enum SampleFixture {
    static let bundle: Result<URL, FixtureFailure> = build()

    private static func build() -> Result<URL, FixtureFailure> {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = root.appendingPathComponent(".build/test-fixtures")
        let package = fixtures.appendingPathComponent("Sample")
        do {
            if !FileManager.default.fileExists(atPath: package.appendingPathComponent("Package.swift").path) {
                try? FileManager.default.removeItem(at: package)
                try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
                _ = try run(root.appendingPathComponent("scripts/new-plugin.sh"), ["Sample", "--dir", fixtures.path])
            }
            let out = fixtures.appendingPathComponent("out")
            let built = try run(root.appendingPathComponent("scripts/build-plugin.sh"), [package.path, "--out", out.path])
            return .success(URL(fileURLWithPath: built.trimmingCharacters(in: .whitespacesAndNewlines)))
        } catch let failure as FixtureFailure {
            return .failure(failure)
        } catch {
            return .failure(FixtureFailure(description: "\(error)"))
        }
    }

    /// Runs a script and returns its standard output; its standard error goes into the failure.
    private static func run(_ script: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        let errors = FileManager.default.temporaryDirectory.appendingPathComponent("NotchTheRockTests-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errors) }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = try FileHandle(forWritingTo: errors)
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let log = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
            throw FixtureFailure(description: "\(script.lastPathComponent) exited \(process.terminationStatus):\n\(log.suffix(3000))")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
@Suite struct TemplatePluginTests {
    /// R03's acceptance through the real loader: a plugin made from the template, put in the user
    /// folder, is listed as needing consent after a reload; once allowed its tab appears, and turning
    /// it off removes the tab and what it showed.
    @Test func R03__template_plugin_needs_consent_then_shows_its_tab_and_hides_it_when_turned_off() async throws {
        let built = try await Task.detached { try SampleFixture.bundle.get() }.value
        let fixture = try PluginFixture()
        defer { fixture.cleanUp() }
        let host = NotchHostModel()
        let catalog = fixture.catalog(host: host)
        catalog.loadAll()
        #expect(catalog.records.isEmpty)

        let installed = fixture.locations.user.appendingPathComponent("Sample.notchplugin")
        try FileManager.default.copyItem(at: built, to: installed)
        catalog.reload()
        #expect(catalog.records.map(\.state) == [.needsConsent(PluginCatalog.unknownReason)])
        #expect(catalog.records.first?.name == "Sample")
        #expect(host.tabs.isEmpty)

        try catalog.consent(to: installed.path)
        catalog.reload()
        #expect(catalog.records.map(\.state) == [.on])
        #expect(host.tabs.map(\.pluginID) == ["com.example.sample"])
        #expect(host.tabs.first?.tab.title == "Sample")
        #expect(host.liveActivity?.pluginID == "com.example.sample")

        catalog.setEnabled(false, for: installed.path)
        #expect(catalog.records.map(\.state) == [.off])
        #expect(host.tabs.isEmpty)
        #expect(host.liveActivity == nil)
    }
}
