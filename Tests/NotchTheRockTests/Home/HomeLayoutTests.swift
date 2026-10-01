import Foundation
import NotchKit
import SwiftUI
import Testing
@testable import NotchTheRock

/// A plugin as the home sees it, with a tile in `sizes` (none when empty) and a tab when `tab`.
@MainActor
func homePlugin(_ id: String, sizes: [TileSize] = [.small], tab: Bool = true, name: String? = nil) -> HomePlugin {
    HomePlugin(
        pluginID: id,
        name: name ?? id,
        symbol: "circle",
        tab: tab ? PluginTab(title: name ?? id, symbol: "circle") { Text(id) } : nil,
        tile: PluginTile(supportedSizes: sizes) { _ in Text(id) }
    )
}

/// An isolated defaults suite stored in a temporary file, so nothing reaches the app's own domain.
@MainActor
final class HomeDefaults {
    let defaults: UserDefaults
    private let suiteName: String
    private let root: URL

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NotchTheRockHomeTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = root.appendingPathComponent("defaults").path
        defaults = UserDefaults(suiteName: suiteName)!
    }

    var store: HomeLayoutStore { HomeLayoutStore(defaults: defaults) }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
struct HomeLayoutTests {
    func origin(_ column: Int, _ row: Int) -> GridOrigin { GridOrigin(column: column, row: row) }

    @Test func R16__grid_is_8_columns_and_2_rows_of_2_units() {
        #expect(HomeLayout.columns == 8)
        #expect(HomeLayout.rowHeight == 2)
        #expect(HomeLayout.maxRows == 2)
        // Inside: the last column and the second row.
        #expect(HomeLayout.isInside(.small, at: origin(6, 2)))
        #expect(HomeLayout.isInside(.wide, at: origin(4, 0)))
        #expect(HomeLayout.isInside(.large, at: origin(4, 0)))
        // Outside: past column 8, a third row, a large tile starting on the second row.
        #expect(!HomeLayout.isInside(.small, at: origin(7, 0)))
        #expect(!HomeLayout.isInside(.wide, at: origin(5, 0)))
        #expect(!HomeLayout.isInside(.small, at: origin(0, 4)))
        #expect(!HomeLayout.isInside(.large, at: origin(0, 2)))
        #expect(!HomeLayout.isInside(.small, at: origin(-1, 0)))
        // A row is 2 units tall: tiles start on unit row 0 or 2 only.
        #expect(!HomeLayout.isInside(.small, at: origin(0, 1)))
    }

    @Test func R16__new_plugins_fill_first_fit_and_overflow_goes_to_the_list() {
        let plugins = (0..<9).map { homePlugin("p\($0)") }
        let layout = HomeLayout.empty.reconciled(with: plugins)
        // Four small tiles per row, two rows: the ninth does not fit.
        #expect(layout.tiles.count == 8)
        #expect(layout.tile(for: "p0")?.origin == origin(0, 0))
        #expect(layout.tile(for: "p3")?.origin == origin(6, 0))
        #expect(layout.tile(for: "p4")?.origin == origin(0, 2))
        #expect(layout.tile(for: "p8") == nil)
        #expect(layout.known.contains("p8"))
    }

    @Test func R16__first_fit_uses_the_default_size_and_skips_occupied_cells() {
        let plugins = [
            homePlugin("large", sizes: [.large, .small]),
            homePlugin("wide", sizes: [.wide]),
            homePlugin("small", sizes: [.small, .wide]),
            homePlugin("wide2", sizes: [.wide]),
        ]
        let layout = HomeLayout.empty.reconciled(with: plugins)
        #expect(layout.tile(for: "large") == TilePlacement(pluginID: "large", size: .large, origin: origin(0, 0)))
        #expect(layout.tile(for: "wide") == TilePlacement(pluginID: "wide", size: .wide, origin: origin(4, 0)))
        #expect(layout.tile(for: "small") == TilePlacement(pluginID: "small", size: .small, origin: origin(4, 2)))
        // Two columns are left; a wide tile needs four.
        #expect(layout.tile(for: "wide2") == nil)
    }

    @Test func R16__tiles_never_overlap() {
        var layout = HomeLayout.empty.reconciled(with: [homePlugin("a", sizes: [.wide]), homePlugin("b")])
        #expect(layout.tile(for: "b")?.origin == origin(4, 0))
        // Onto the wide tile: refused, nothing moves.
        let moved1 = layout.move("b", to: origin(2, 0))
        #expect(!moved1)
        #expect(layout.tile(for: "b")?.origin == origin(4, 0))
        let moved2 = layout.move("b", to: origin(6, 2))
        #expect(moved2)
        #expect(layout.tile(for: "b")?.origin == origin(6, 2))
        // Moving off the grid or between rows is refused as well.
        let moved3 = layout.move("b", to: origin(7, 2))
        #expect(!moved3)
        let moved4 = layout.move("b", to: origin(0, 1))
        #expect(!moved4)

        // Stored tiles that overlap keep the first; the later one goes to the list.
        let stored = HomeLayout(
            tiles: [
                TilePlacement(pluginID: "a", size: .wide, origin: origin(0, 0)),
                TilePlacement(pluginID: "b", size: .small, origin: origin(2, 0)),
            ],
            known: ["a", "b"]
        )
        let shown = stored.reconciled(with: [homePlugin("a", sizes: [.wide]), homePlugin("b")])
        #expect(shown.tiles.map(\.pluginID) == ["a"])
    }

    @Test func R16__resize_keeps_the_origin_or_takes_the_first_fit_or_is_refused() {
        var layout = HomeLayout.empty.reconciled(with: [homePlugin("a"), homePlugin("b"), homePlugin("c"), homePlugin("d")])
        // a at (0,0) cannot grow over b at (2,0): it moves to the first free 4x2 place.
        let resized5 = layout.resize("a", to: .wide)
        #expect(resized5)
        #expect(layout.tile(for: "a") == TilePlacement(pluginID: "a", size: .wide, origin: origin(0, 2)))
        // No 4x4 place is free anywhere for d: refused, unchanged.
        let resized6 = layout.resize("d", to: .large)
        #expect(!resized6)
        #expect(layout.tile(for: "d")?.size == .small)
        let resized7 = layout.resize("a", to: .small)
        #expect(resized7)
        #expect(layout.tile(for: "a") == TilePlacement(pluginID: "a", size: .small, origin: origin(0, 2)))
    }

    @Test func R16__remove_moves_to_the_list_and_add_takes_the_first_fit() {
        var layout = HomeLayout.empty.reconciled(with: [homePlugin("a"), homePlugin("b")])
        layout.remove("a")
        #expect(layout.tile(for: "a") == nil)
        #expect(layout.known.contains("a"))
        // A removed tile stays in the list: it is no longer new.
        #expect(layout.reconciled(with: [homePlugin("a"), homePlugin("b")]).tile(for: "a") == nil)
        let added8 = layout.add("a", size: .small)
        #expect(added8)
        #expect(layout.tile(for: "a")?.origin == origin(0, 0))
    }

    @Test func R16__vanished_plugins_leave_the_grid_and_return_as_new() {
        let layout = HomeLayout.empty.reconciled(with: [homePlugin("a"), homePlugin("b")])
        let without = layout.reconciled(with: [homePlugin("b")])
        #expect(without.tiles.map(\.pluginID) == ["b"])
        #expect(without.known == ["b"])
        // Its cells are free for others, and it comes back as a new plugin at the first fit.
        let back = without.reconciled(with: [homePlugin("b"), homePlugin("a")])
        #expect(back.tile(for: "a")?.origin == origin(0, 0))
    }

    @Test func R16__stored_tiles_with_unsupported_sizes_go_to_the_list() {
        let stored = HomeLayout(tiles: [TilePlacement(pluginID: "a", size: .large, origin: origin(0, 0))], known: ["a"])
        let shown = stored.reconciled(with: [homePlugin("a", sizes: [.small, .wide])])
        #expect(shown.tile(for: "a") == nil)
        // A plugin that lost its tile cannot keep a grid place either.
        let tabOnly = HomeLayout(tiles: [TilePlacement(pluginID: "t", size: .small, origin: origin(0, 0))], known: ["t"])
        #expect(tabOnly.reconciled(with: [homePlugin("t", sizes: [])]).tiles.isEmpty)
    }
}

@MainActor
struct HomeModelTests {
    let fixture = HomeDefaults()

    @Test func R16__four_home_rules_classify_tiles_rows_and_absent_plugins() {
        defer { fixture.cleanUp() }
        let home = HomeModel(store: fixture.store)
        home.plugins = [
            homePlugin("both", sizes: [.wide], name: "둘 다"),
            homePlugin("tabOnly", sizes: [], name: "탭만"),
            homePlugin("tileOnly", sizes: [.small], tab: false, name: "타일만"),
            homePlugin("neither", sizes: [], tab: false, name: "없음"),
        ]
        #expect(home.entries == [
            HomeEntry(pluginID: "both", name: "둘 다", symbol: "circle", kind: .tile(.wide), opensDetail: true),
            HomeEntry(pluginID: "tileOnly", name: "타일만", symbol: "circle", kind: .tile(.small), opensDetail: false),
            HomeEntry(pluginID: "tabOnly", name: "탭만", symbol: "circle", kind: .row, opensDetail: true),
        ])
        // A tile-only plugin taken off the grid is a display-only row, so it can be added back.
        home.remove("tileOnly")
        #expect(home.list.map(\.pluginID) == ["tabOnly", "tileOnly"])
        #expect(home.entries.last == HomeEntry(pluginID: "tileOnly", name: "타일만", symbol: "circle", kind: .row, opensDetail: false))
    }

    @Test func R16__layout_survives_a_relaunch() {
        defer { fixture.cleanUp() }
        let plugins = [homePlugin("a", sizes: [.small, .wide]), homePlugin("b"), homePlugin("c")]
        let first = HomeModel(store: fixture.store)
        first.plugins = plugins
        first.beginEditing()
        #expect(first.move("b", to: GridOrigin(column: 0, row: 2)))
        #expect(first.resize("a", to: .wide))
        first.remove("c")
        first.finishEditing()

        let relaunched = HomeModel(store: fixture.store)
        // Plugins arrive one at a time while the catalog loads them; nothing is lost on the way.
        relaunched.plugins = [plugins[1]]
        relaunched.plugins = [plugins[1], plugins[0]]
        relaunched.plugins = plugins
        #expect(relaunched.layout == first.layout)
        #expect(relaunched.entries.map(\.pluginID) == ["a", "b", "c"])
        #expect(relaunched.tiles.map(\.placement) == [
            TilePlacement(pluginID: "a", size: .wide, origin: GridOrigin(column: 0, row: 0)),
            TilePlacement(pluginID: "b", size: .small, origin: GridOrigin(column: 0, row: 2)),
        ])
    }

    @Test func R16__corrupt_or_missing_data_gives_the_default_layout() {
        defer { fixture.cleanUp() }
        #expect(fixture.store.load() == .empty)
        fixture.defaults.set(Data("{\"tiles\": 3".utf8), forKey: HomeLayoutStore.key)
        #expect(fixture.store.load() == .empty)
        fixture.defaults.set("not data", forKey: HomeLayoutStore.key)
        #expect(fixture.store.load() == .empty)
        let unknownSize = #"{"tiles":[{"plugin":"a","size":"huge","column":0,"row":0}],"known":["a"]}"#
        fixture.defaults.set(Data(unknownSize.utf8), forKey: HomeLayoutStore.key)
        #expect(fixture.store.load() == .empty)

        let home = HomeModel(store: fixture.store)
        home.plugins = [homePlugin("a")]
        #expect(home.tiles.map(\.placement) == [TilePlacement(pluginID: "a", size: .small, origin: GridOrigin(column: 0, row: 0))])
    }

    @Test func R16__persistence_round_trip() {
        defer { fixture.cleanUp() }
        let layout = HomeLayout(
            tiles: [
                TilePlacement(pluginID: "a", size: .large, origin: GridOrigin(column: 0, row: 0)),
                TilePlacement(pluginID: "b", size: .wide, origin: GridOrigin(column: 4, row: 2)),
                TilePlacement(pluginID: "c", size: .small, origin: GridOrigin(column: 6, row: 0)),
            ],
            known: ["a", "b", "c", "d"]
        )
        fixture.store.save(layout)
        #expect(fixture.store.load() == layout)
    }

    @Test func R16__edits_are_limited_to_supported_sizes() {
        defer { fixture.cleanUp() }
        let home = HomeModel(store: fixture.store)
        home.plugins = [homePlugin("a", sizes: [.small, .wide]), homePlugin("t", sizes: [])]
        #expect(!home.resize("a", to: .large))
        #expect(home.tiles.first?.placement.size == .small)
        #expect(home.canResize("a", to: .wide))
        #expect(!home.canResize("a", to: .large))
        // A plugin without a tile cannot be added to the grid.
        #expect(!home.canAdd("t"))
        #expect(!home.add("t"))
    }

    @Test func R16__a_full_grid_refuses_adding() {
        defer { fixture.cleanUp() }
        let home = HomeModel(store: fixture.store)
        home.plugins = (0..<9).map { homePlugin("p\($0)") }
        #expect(home.list.map(\.pluginID) == ["p8"])
        #expect(!home.canAdd("p8"))
        #expect(!home.add("p8"))
        home.remove("p0")
        #expect(home.add("p8"))
        #expect(home.list.map(\.pluginID) == ["p0"])
    }
}
