import AppKit
import Foundation
import SwiftUI
import Testing
@testable import NotchKit

@MainActor
final class TilePlugin: NotchPlugin {
    static let manifest = PluginManifest(
        id: "com.example.tile",
        name: "Tile",
        version: "1.0.0",
        symbol: "square.grid.2x2",
        sdkVersion: NotchKitSDK.version
    )
    init(context: NotchContext) {}
    func activate() {}
    func deactivate() {}
    var tile: PluginTile? {
        PluginTile(supportedSizes: [.wide, .small]) { size in
            Text("\(size.columns)x\(size.rows)")
        }
    }
}

@MainActor
@Suite struct PluginTileTests {
    @Test func R16__tile_sizes_are_grid_units() {
        #expect(TileSize.allCases == [.small, .wide, .large])
        #expect(TileSize.small.columns == 2 && TileSize.small.rows == 2)
        #expect(TileSize.wide.columns == 4 && TileSize.wide.rows == 2)
        #expect(TileSize.large.columns == 4 && TileSize.large.rows == 4)
    }

    @Test func R16__first_supported_size_is_the_default() throws {
        let tile = try #require(PluginTile(supportedSizes: [.large, .small]) { _ in Text("tile") })
        #expect(tile.supportedSizes == [.large, .small])
        #expect(tile.defaultSize == .large)
    }

    @Test func R16__tile_without_sizes_is_rejected() {
        #expect(PluginTile(supportedSizes: []) { _ in Text("tile") } == nil)
    }

    @Test func R16__plugin_without_tile_reads_nil_through_protocol_default() throws {
        let plugins: [any NotchPlugin] = [
            SamplePlugin(context: try makeContext(RecordingHost())),
            TilePlugin(context: try makeContext(RecordingHost(), id: "com.example.tile")),
        ]
        #expect(plugins[0].tile == nil)
        #expect(plugins[1].tile?.supportedSizes == [.wide, .small])
    }

    @Test func R16__sdk_has_the_additive_tile_api_of_1_1() {
        #expect(NotchKitSDK.version.supports(SDKVersion(major: 1, minor: 1)))
        #expect(NotchKitSDK.version.supports(SDKVersion(major: 1, minor: 0)))
    }

    /// The host sizes the expanded notch from what a view reports; a view without `.infinity`
    /// fills must measure to a finite, non-zero size for every tile size it supports.
    @Test func R15__intrinsically_sized_views_measure_to_a_definite_size() throws {
        let tile = try #require(PluginTile(supportedSizes: TileSize.allCases) { size in
            VStack(spacing: 4) {
                Image(systemName: "sparkles").font(.title)
                Text("\(size.columns)x\(size.rows)")
            }
            .padding()
        })
        let tab = PluginTab(title: "Tab", symbol: "sparkles") {
            VStack(spacing: 8) {
                Image(systemName: "sparkles").font(.largeTitle)
                Text("펼친 화면이에요.")
            }
            .padding()
        }
        let views = tile.supportedSizes.map { tile.content($0) } + [tab.content]
        for view in views {
            let size = NSHostingView(rootView: view).fittingSize
            #expect(size.width > 0 && size.width.isFinite, "width \(size.width)")
            #expect(size.height > 0 && size.height.isFinite, "height \(size.height)")
        }
    }
}

/// Plugin bundles and the probe built by `SDK/NotchKit/Tests/sdk-compat-test.sh`. `scripts/test.sh`
/// does not build them, so there these tests are reported as skipped.
enum CompatFixture {
    static let environment = ProcessInfo.processInfo.environment
    /// The plugin template built against NotchKit 1.0.
    static let sdk10Bundle = environment["NOTCHKIT_COMPAT_SDK10_BUNDLE"]
    /// The plugin template built against the current NotchKit.
    static let currentBundle = environment["NOTCHKIT_COMPAT_CURRENT_BUNDLE"]
    /// `notchkit-probe` built against the current NotchKit. It loads a bundle with the current
    /// `PluginLoader` in a process holding the single shared `libNotchKit.dylib`, as the app does;
    /// this test process links NotchKit statically, so a plugin loaded here would bind to another copy.
    static let probe = environment["NOTCHKIT_PROBE"]
    static let isBuilt = sdk10Bundle != nil && currentBundle != nil && probe != nil

    /// Copies `bundle` into a fresh temporary folder, so the test loads its own copy.
    static func copy(_ bundle: String) throws -> URL {
        let source = URL(fileURLWithPath: bundle)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NotchKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    /// Runs the probe on `bundle` and returns its exit status and combined output.
    static func probe(_ bundle: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(probe))
        process.arguments = [bundle.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        print("notchkit-probe \(bundle.lastPathComponent) (exit \(process.terminationStatus)):\n\(output)")
        return (process.terminationStatus, output)
    }
}

@Suite(.enabled(if: CompatFixture.isBuilt, "SDK/NotchKit/Tests/sdk-compat-test.sh builds the fixtures"))
struct SDKCompatibilityTests {
    @Test func R16__sdk_1_0_bundle_loads_with_current_loader_and_nil_tile() throws {
        let bundle = try CompatFixture.copy(try #require(CompatFixture.sdk10Bundle))
        #expect(try PluginBundleInfo(contentsOf: bundle).sdkVersion == SDKVersion(major: 1, minor: 0))
        let (status, output) = try CompatFixture.probe(bundle)
        #expect(status == 0)
        #expect(output.contains("sdk: 1.0 (bundle 1.0, host \(NotchKitSDK.version))"))
        #expect(output.contains("tile: none"))
        #expect(output.contains("setup: none"), "built before SDK 1.3: no onboarding step")
        #expect(output.contains("description: none"), "built before SDK 1.4: no description")
        #expect(output.contains("OK:"))
    }

    @Test func R16__probe_prints_the_tile_sizes() throws {
        let bundle = try CompatFixture.copy(try #require(CompatFixture.currentBundle))
        let (status, output) = try CompatFixture.probe(bundle)
        #expect(status == 0)
        #expect(output.contains("sdk: \(NotchKitSDK.version) (bundle \(NotchKitSDK.version), host \(NotchKitSDK.version))"))
        #expect(output.contains("tile: small (2x2)\n"))
        #expect(output.contains("permissions: none\n"), "the template declares that it uses no permission")
        #expect(output.contains("settings: toggle showsStatus\n"))
        #expect(!output.contains("description: none"))
    }
}
