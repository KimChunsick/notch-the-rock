import AppKit
import Foundation
import NotchKit
import SwiftUI
import Testing
@testable import NotchTheRock

/// Every built-in plugin under `Plugins/`, packaged by `scripts/build-plugin.sh` once per test
/// process, and what `notchkit-probe` prints for it. The probe creates each plugin the way the app
/// does, with a temporary home, so a plugin that looks at the home folder when it is created sees an
/// empty one, never the user's `~/.claude` or `~/.codex`.
enum BuiltInFixture {
    struct Probed: Sendable {
        let name: String
        let bundle: URL
        let lines: [String]
    }

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static let plugins: Result<[Probed], FixtureFailure> = build()

    private static func build() -> Result<[Probed], FixtureFailure> {
        let manager = FileManager.default
        let home = manager.temporaryDirectory.appendingPathComponent("NotchTheRockTests-home-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: home) }
        do {
            try manager.createDirectory(at: home, withIntermediateDirectories: true)
            let plugins = root.appendingPathComponent("Plugins")
            let names = try manager.contentsOfDirectory(atPath: plugins.path)
                .filter { manager.fileExists(atPath: plugins.appendingPathComponent("\($0)/Package.swift").path) }
                .sorted()
            let out = root.appendingPathComponent(".build/test-fixtures/builtins")
            let built = try names.map { name in
                let path = try run("/bin/bash", [root.appendingPathComponent("scripts/build-plugin.sh").path, plugins.appendingPathComponent(name).path, "--out", out.path])
                return (name, URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            let probePackage = root.appendingPathComponent("SDK/NotchKit/Probe").path
            let binPath = try run("/usr/bin/swift", ["build", "-c", "release", "--package-path", probePackage, "--show-bin-path"])
            let probe = binPath.trimmingCharacters(in: .whitespacesAndNewlines) + "/notchkit-probe"
            let environment = ["CFFIXED_USER_HOME": home.path, "HOME": home.path, "CODEX_HOME": home.appendingPathComponent(".codex").path]
            return .success(try built.map { name, bundle in
                let output = try run(probe, [bundle.path], environment: environment)
                return Probed(name: name, bundle: bundle, lines: output.components(separatedBy: "\n"))
            })
        } catch let failure as FixtureFailure {
            return .failure(failure)
        } catch {
            return .failure(FixtureFailure(description: "\(error)"))
        }
    }

    /// Runs a program and returns its standard output; its standard error goes into the failure.
    private static func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
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
            throw FixtureFailure(description: "\(executable) \(arguments.last ?? "") exited \(process.terminationStatus):\n\(log.suffix(3000))")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Stands in for a built-in plugin's type in a catalog: creates the real plugin with the catalog's
/// context but never activates it, so its page can be drawn without it starting its work (reading
/// the pasteboard, sampling, polling folders).
@MainActor
private final class InertBuiltIn: NotchPlugin {
    static let manifest = PluginManifest(id: "com.example.inert", name: "Inert", version: "1.0.0", symbol: "gearshape", sdkVersion: NotchKitSDK.version)
    static var wrapped: (any NotchPlugin.Type)?

    private let plugin: any NotchPlugin

    init(context: NotchContext) {
        plugin = Self.wrapped!.init(context: context)
    }

    func activate() {}
    func deactivate() {}
    var settingsView: AnyView? { plugin.settingsView }
    var pluginDescription: PluginDescription? { plugin.pluginDescription }
}

@MainActor
@Suite struct BuiltInPluginPageTests {
    static let builtIns = ["Agents", "Battery", "Brightness", "Clipboard", "DStack", "Hello", "NowPlaying", "SystemStats", "Volume"]

    /// The permission kinds each built-in plugin declares, as the probe names them, and its settings.
    static let declared: [String: (permissions: [String], settings: String)] = [
        "Agents": (["otherAppSettings(Claude Code)", "files(~/.claude/projects/*)", "files($CODEX_HOME/sessions)", "helperProcesses", "automation(터미널)"], "choice approvalWaitSeconds"),
        "Battery": (["helperProcesses"], "none"),
        "Brightness": (["accessibility"], "none"),
        "Clipboard": (["pasteboard", "keychain"], "none"),
        "DStack": (["files(~/.claude/projects)", "files(프로젝트 폴더/.dstack)"], "none"),
        "Hello": ([], "toggle showsGreeting"),
        "NowPlaying": (["helperProcesses"], "none"),
        "SystemStats": ([], "none"),
        "Volume": (["accessibility"], "none"),
    ]

    /// R48: every built-in plugin, created from its bundle the way the app creates it, declares a
    /// summary and its permissions, each with a reason (`none` is the page's "쓰는 권한 없음"), and
    /// moves its simple settings into declared items.
    @Test func R48__every_built_in_plugin_declares_a_summary_and_its_permissions() async throws {
        let plugins = try await Task.detached { try BuiltInFixture.plugins.get() }.value
        #expect(plugins.map(\.name) == Self.builtIns)
        for plugin in plugins {
            let lines = plugin.lines
            let summary = try #require(lines.firstIndex { $0.hasPrefix("description: ") }, "\(plugin.name): \(lines)")
            #expect(lines[summary] != "description: none", "\(plugin.name) declares no description")
            let permissions = try #require(lines.firstIndex { $0.hasPrefix("permissions: ") }, "\(plugin.name) declares no permissions")
            let settings = try #require(lines.firstIndex { $0.hasPrefix("settings: ") }, "\(plugin.name)")
            #expect(summary < permissions && permissions < settings)
            let text = String(lines[summary].dropFirst("description: ".count))
            #expect(text.count >= 20 && text.hasSuffix("요."), "\(plugin.name): one or two sentences, got \(text)")
            let listed = String(lines[permissions].dropFirst("permissions: ".count))
            let entries = listed == "none" ? [] : listed.components(separatedBy: "; ")
            let expected = try #require(Self.declared[plugin.name])
            let split = entries.map { entry in
                entry.range(of: " (").map { (String(entry[..<$0.lowerBound]), String(entry[$0.upperBound...])) } ?? (entry, "")
            }
            #expect(split.map(\.0) == expected.permissions, "\(plugin.name): \(listed)")
            for (kind, reason) in split {
                #expect(reason.hasSuffix("요.)") && reason.count > 12, "\(plugin.name) \(kind): give a reason")
            }
            #expect(lines[settings] == "settings: \(expected.settings)", "\(plugin.name)")
        }
    }

    /// The real plugin types, loaded from their bundles, give pages in the uniform order: summary,
    /// permissions, declared settings, then only what the declaration cannot express.
    @Test func R48__built_in_pages_follow_the_uniform_order() async throws {
        let plugins = try await Task.detached { try BuiltInFixture.plugins.get() }.value
        let expected: [String: [String]] = [
            "Battery": ["설명", "권한"],
            "Clipboard": ["설명", "권한", "추가 설정"],
            "Hello": ["설명", "권한", "설정"],
        ]
        for (name, titles) in expected {
            let fixture = try PluginFixture()
            defer { fixture.cleanUp() }
            let (catalog, record) = try load(try #require(plugins.first { $0.name == name }), fixture: fixture)
            let page = try #require(catalog.page(for: record))
            let description = try #require(page.description, "\(name)")
            #expect(PluginPagePart.parts(of: description, hasCustomView: page.customView != nil).map(\.title) == titles, "\(name)")
        }
    }

    /// Renders of the Agents, Clipboard and Battery pages through the host's pane. Written only when
    /// NOTCH_SETTINGS_CAPTURE_DIR is set; the Agents page only when CFFIXED_USER_HOME also points the
    /// home elsewhere, because creating that plugin reads `~/.claude`.
    @Test func R48__renders_of_built_in_settings_pages() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["NOTCH_SETTINGS_CAPTURE_DIR"] else { return }
        let plugins = try await Task.detached { try BuiltInFixture.plugins.get() }.value
        var pages: [(String, CGFloat, String)] = [
            ("Clipboard", 560, "R48-render-clipboard-T159.png"),
            ("Battery", 400, "R48-render-battery-T159.png"),
        ]
        if environment["CFFIXED_USER_HOME"] != nil {
            pages.insert(("Agents", 1180, "R48-render-agents-T159.png"), at: 0)
        }
        for (name, height, file) in pages {
            let fixture = try PluginFixture()
            defer { fixture.cleanUp() }
            let (catalog, _) = try load(try #require(plugins.first { $0.name == name }), fixture: fixture)
            try PluginSettingsPageTests.render(PluginSettingsPane(catalog: catalog), height: height, to: URL(fileURLWithPath: directory).appendingPathComponent(file))
        }
    }

    /// A catalog with one built-in record whose plugin is `probed`'s real type, created but not activated.
    private func load(_ probed: BuiltInFixture.Probed, fixture: PluginFixture) throws -> (catalog: PluginCatalog, record: PluginRecord.ID) {
        let loaded = try PluginLoader.load(try PluginBundleInfo(contentsOf: probed.bundle))
        let manifest = loaded.manifest
        InertBuiltIn.wrapped = loaded.pluginType
        let bundle = try fixture.makeBundle(in: fixture.locations.builtIn!, name: probed.name, identifier: fixture.newIdentifier(), sdk: manifest.sdkVersion.description)
        let catalog = fixture.catalog(open: { info in
            (PluginManifest(id: info.identifier, name: manifest.name, version: manifest.version, symbol: manifest.symbol, sdkVersion: manifest.sdkVersion), InertBuiltIn.self)
        })
        catalog.loadAll()
        return (catalog, bundle.path)
    }
}
