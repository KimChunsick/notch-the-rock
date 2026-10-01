import AppKit
import Foundation
import NotchKit
import SwiftUI
import Testing
@testable import NotchTheRock

/// One class for every kind of home plugin: its manifest name and symbol, tab and tile are set per
/// identifier in `shapes`. The tab's title and symbol differ from the manifest's on purpose.
@MainActor
final class ShapedPlugin: NotchPlugin {
    struct Shape {
        var name: String
        var symbol: String
        var tab = false
        /// The tile's sizes; no tile when empty.
        var sizes: [TileSize] = []
        /// Opening the bundle throws, as when its code cannot load.
        var crashes = false
    }

    struct Crash: Error {}

    static let manifest = PluginManifest(id: "com.example.shaped", name: "Shaped", version: "1.0.0", symbol: "square", sdkVersion: NotchKitSDK.version)
    static var shapes: [String: Shape] = [:]
    /// How many times each plugin's `tile` was read, by identifier.
    static var tileReads: [String: Int] = [:]

    /// Opens every bundle as a `ShapedPlugin` with the manifest of its shape.
    static let opener: PluginOpener = { info in
        let shape = shapes[info.identifier] ?? Shape(name: "?", symbol: "questionmark")
        if shape.crashes { throw Crash() }
        let manifest = PluginManifest(id: info.identifier, name: shape.name, version: "1.0.0", symbol: shape.symbol, sdkVersion: NotchKitSDK.version)
        return (manifest, ShapedPlugin.self)
    }

    let pluginID: String
    var shape: Shape { Self.shapes[pluginID] ?? Shape(name: "?", symbol: "questionmark") }

    init(context: NotchContext) {
        pluginID = context.pluginID
    }

    func activate() {}
    func deactivate() {}

    var expandedTab: PluginTab? {
        guard shape.tab else { return nil }
        return PluginTab(title: "tab title", symbol: "tab.symbol") { [pluginID] in Text(pluginID) }
    }

    var tile: PluginTile? {
        Self.tileReads[pluginID, default: 0] += 1
        let shape = shape
        return PluginTile(supportedSizes: shape.sizes) { size in
            VStack(spacing: 4) {
                Image(systemName: shape.symbol).font(.system(size: size == .large ? 30 : 20))
                Text(shape.name).font(.system(size: 12, weight: .semibold))
            }
        }
    }
}

extension PluginFixture {
    /// A built-in bundle `<bundleName>.notchplugin` whose plugin has `shape`. Built-in bundles load
    /// in bundle name order.
    @discardableResult
    func makeShaped(_ bundleName: String, _ shape: ShapedPlugin.Shape, sdk: String = "1.0") throws -> String {
        let id = newIdentifier()
        ShapedPlugin.shapes[id] = shape
        try makeBundle(in: locations.builtIn!, name: bundleName, identifier: id, sdk: sdk)
        return id
    }

    /// A host keeping its home layout in this fixture's defaults, and a catalog opening `ShapedPlugin`s.
    func shapedCatalog() -> (PluginCatalog, NotchHostModel) {
        let host = NotchHostModel(homeStore: HomeLayoutStore(defaults: defaults))
        return (catalog(host: host, open: ShapedPlugin.opener), host)
    }

    func recordID(of identifier: String, in catalog: PluginCatalog) throws -> PluginRecord.ID {
        try #require(catalog.records.first { $0.identifier == identifier }).id
    }
}

@MainActor
@Suite struct PluginCatalogHomeTests {
    func entry(_ id: String, _ name: String, _ symbol: String, _ kind: HomeEntry.Kind, opens: Bool) -> HomeEntry {
        HomeEntry(pluginID: id, name: name, symbol: symbol, kind: kind, opensDetail: opens)
    }

    @Test func R16__every_enabled_plugin_reaches_the_home_with_its_manifest_name_symbol_tab_and_tile() throws {
        let fixture = try PluginFixture()
        defer { fixture.cleanUp() }
        let both = try fixture.makeShaped("A", .init(name: "타일과 화면", symbol: "a.circle", tab: true, sizes: [.small, .wide]))
        let tabOnly = try fixture.makeShaped("B", .init(name: "화면만", symbol: "b.circle", tab: true))
        let tileOnly = try fixture.makeShaped("C", .init(name: "타일만", symbol: "c.circle", sizes: [.wide]))
        let neither = try fixture.makeShaped("D", .init(name: "둘 다 없음", symbol: "d.circle"))
        let mismatch = try fixture.makeShaped("E", .init(name: "새 SDK", symbol: "e.circle", tab: true, sizes: [.small]), sdk: "9.0")
        let crashed = try fixture.makeShaped("F", .init(name: "고장", symbol: "f.circle", tab: true, sizes: [.small], crashes: true))
        let (catalog, host) = fixture.shapedCatalog()

        catalog.loadAll()

        // One per running, enabled plugin in load order; refused bundles never reach the home.
        #expect(host.plugins.map(\.pluginID) == [both, tabOnly, tileOnly, neither])
        #expect(host.plugins.map(\.name) == ["타일과 화면", "화면만", "타일만", "둘 다 없음"])
        #expect(host.plugins.map(\.symbol) == ["a.circle", "b.circle", "c.circle", "d.circle"])
        #expect(host.plugins.map { $0.tab != nil } == [true, true, false, false])
        #expect(host.plugins.map { $0.tile?.supportedSizes } == [[.small, .wide], nil, [.wide], nil])
        let refused = catalog.records.filter { [mismatch, crashed].contains($0.identifier ?? "") }
        #expect(refused.count == 2 && refused.allSatisfy { if case .failed = $0.state { true } else { false } })
        // Tile and tab: a tile that opens the screen; tab only: a list row; tile only: a tile that
        // opens nothing; neither: not in the home.
        #expect(host.homeEntries == [
            entry(both, "타일과 화면", "a.circle", .tile(.small), opens: true),
            entry(tileOnly, "타일만", "c.circle", .tile(.wide), opens: false),
            entry(tabOnly, "화면만", "b.circle", .row, opens: true),
        ])
    }

    @Test func R16__turning_a_plugin_off_takes_it_and_its_tile_out_of_the_home_and_on_puts_it_back_in_load_order() throws {
        let fixture = try PluginFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.makeShaped("A", .init(name: "첫째", symbol: "1.circle", tab: true, sizes: [.small]))
        let second = try fixture.makeShaped("B", .init(name: "둘째", symbol: "2.circle", tab: true))
        let third = try fixture.makeShaped("C", .init(name: "셋째", symbol: "3.circle", sizes: [.small]))
        let (catalog, host) = fixture.shapedCatalog()
        catalog.loadAll()
        let id = try fixture.recordID(of: first, in: catalog)

        catalog.setEnabled(false, for: id)

        #expect(host.plugins.map(\.pluginID) == [second, third])
        #expect(host.home.layout.tile(for: first) == nil)
        #expect(host.homeEntries.map(\.pluginID) == [third, second])

        catalog.setEnabled(true, for: id)

        #expect(host.plugins.map(\.pluginID) == [first, second, third])
        #expect(host.homeEntries == [
            entry(first, "첫째", "1.circle", .tile(.small), opens: true),
            entry(third, "셋째", "3.circle", .tile(.small), opens: false),
            entry(second, "둘째", "2.circle", .row, opens: true),
        ])
        // The tile is read once, when the plugin loads, like its tab.
        #expect(ShapedPlugin.tileReads[first] == 1)
    }

    @Test func R16__a_stored_layout_keeps_the_place_of_a_disabled_plugin_and_its_tile_returns_on_enable() throws {
        let fixture = try PluginFixture()
        defer { fixture.cleanUp() }
        let shown = try fixture.makeShaped("A", .init(name: "켜짐", symbol: "sun.max", tab: true, sizes: [.small]))
        let off = try fixture.makeShaped("B", .init(name: "꺼짐", symbol: "moon", sizes: [.small, .large]))
        let large = TilePlacement(pluginID: off, size: .large, origin: GridOrigin(column: 4, row: 0))
        HomeLayoutStore(defaults: fixture.defaults).save(HomeLayout(
            tiles: [TilePlacement(pluginID: shown, size: .small, origin: GridOrigin(column: 0, row: 0)), large],
            known: [shown, off]
        ))
        fixture.defaults.set([off], forKey: PluginCatalog.disabledKey)
        let stored = fixture.defaults.data(forKey: HomeLayoutStore.key)
        let (catalog, host) = fixture.shapedCatalog()

        catalog.loadAll()

        #expect(catalog.records.first { $0.identifier == off }?.state == .off)
        #expect(host.plugins.map(\.pluginID) == [shown])
        #expect(host.homeEntries == [entry(shown, "켜짐", "sun.max", .tile(.small), opens: true)])
        #expect(fixture.defaults.data(forKey: HomeLayoutStore.key) == stored)

        catalog.setEnabled(true, for: try fixture.recordID(of: off, in: catalog))

        #expect(host.plugins.map(\.pluginID) == [shown, off])
        #expect(host.home.layout.tile(for: off) == large)
        #expect(host.homeEntries.map(\.kind) == [.tile(.small), .tile(.large)])
        #expect(fixture.defaults.data(forKey: HomeLayoutStore.key) == stored)
    }

    /// The home the built-in plugins make, loaded through the catalog with stand-ins of the same
    /// manifest names, symbols, tabs and tile sizes, rendered to `R16-render-home-T62.png` only when
    /// NOTCH_HOME_CAPTURE_DIR is set.
    @Test func R16__offscreen_home_of_the_built_in_plugins() throws {
        guard let directory = ProcessInfo.processInfo.environment["NOTCH_HOME_CAPTURE_DIR"] else { return }
        let fixture = try PluginFixture()
        defer { fixture.cleanUp() }
        try fixture.makeShaped("Battery", .init(name: "배터리", symbol: "battery.100percent", tab: true, sizes: [.small, .wide]))
        try fixture.makeShaped("Clipboard", .init(name: "클립보드", symbol: "doc.on.clipboard", tab: true, sizes: [.wide, .small]))
        try fixture.makeShaped("Hello", .init(name: "Hello", symbol: "hand.wave"))
        try fixture.makeShaped("MediaKeys", .init(name: "볼륨과 밝기", symbol: "speaker.wave.2.fill", tab: true, sizes: [.small, .wide]))
        try fixture.makeShaped("SystemStats", .init(name: "시스템 상태", symbol: "cpu", tab: true, sizes: [.small, .wide, .large]))
        let (catalog, host) = fixture.shapedCatalog()
        catalog.loadAll()
        #expect(host.homeEntries.map(\.name) == ["배터리", "클립보드", "볼륨과 밝기", "시스템 상태"])

        let renderer = ImageRenderer(content: HomeView(host: host)
            .padding(16)
            .background(Color.black)
            .environment(\.colorScheme, .dark))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("R16-render-home-T62.png"))
    }
}
