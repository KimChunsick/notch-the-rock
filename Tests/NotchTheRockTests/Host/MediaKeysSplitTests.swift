import Foundation
import NotchKit
import Testing
@testable import NotchTheRock

/// The volume and brightness keys used to be one plugin, `com.notchtherock.mediakeys`. What the
/// app saved about it becomes the volume plugin's, with the brightness plugin beside it, at the
/// first launch with the two plugins; the defaults are a throwaway suite, never the app's own.
@MainActor
@Suite struct MediaKeysSplitTests {
    private let suiteName = "notchtherock-tests.mediakeys-split.\(UUID().uuidString)"
    private var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

    private let old = "com.notchtherock.mediakeys"
    private let volume = "com.notchtherock.volume"
    private let brightness = "com.notchtherock.brightness"

    private func stored(_ tiles: [TilePlacement], known: Set<String>) {
        HomeLayoutStore(defaults: defaults).save(HomeLayout(tiles: tiles, known: known))
    }

    private func tile(_ id: String, _ size: TileSize, _ column: Int, _ row: Int) -> TilePlacement {
        TilePlacement(pluginID: id, size: size, origin: GridOrigin(column: column, row: row))
    }

    @Test func R26__a_media_keys_tile_becomes_volume_with_brightness_beside_it() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        stored([tile("com.notchtherock.battery", .small, 0, 0), tile(old, .small, 2, 0)], known: ["com.notchtherock.battery", old])

        MediaKeysSplit.migrate(defaults)
        let layout = HomeLayoutStore(defaults: defaults).load()
        #expect(layout.tile(for: volume) == tile(volume, .small, 2, 0))
        #expect(layout.tile(for: brightness) == tile(brightness, .small, 4, 0))
        #expect(layout.tile(for: old) == nil)
        #expect(layout.known == ["com.notchtherock.battery", volume, brightness])

        // Once: the user moving the brightness tile away is not undone at the next launch.
        var edited = layout
        edited.remove(brightness)
        HomeLayoutStore(defaults: defaults).save(edited)
        MediaKeysSplit.migrate(defaults)
        #expect(HomeLayoutStore(defaults: defaults).load() == edited)
    }

    @Test func R26__without_room_beside_it_brightness_is_left_to_the_first_fit() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // The wide tile ends at the grid's right edge and a tile sits to its left.
        stored([tile("com.notchtherock.battery", .small, 2, 0), tile(old, .wide, 4, 0)], known: ["com.notchtherock.battery", old])

        MediaKeysSplit.migrate(defaults)
        let layout = HomeLayoutStore(defaults: defaults).load()
        #expect(layout.tile(for: volume) == tile(volume, .wide, 4, 0))
        #expect(layout.tile(for: brightness) == nil)
        // Not known yet, so the home places it like any new plugin, at the first free place.
        #expect(!layout.known.contains(brightness))
        #expect(!layout.known.contains(old))
    }

    @Test func R26__a_media_keys_list_row_becomes_two_list_rows() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        stored([], known: [old])

        MediaKeysSplit.migrate(defaults)
        let layout = HomeLayoutStore(defaults: defaults).load()
        #expect(layout.tiles.isEmpty)
        #expect(layout.known == [volume, brightness])
    }

    @Test func R26__disabled_media_keys_disables_both_and_nothing_else_is_written() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["com.notchtherock.clipboard", old], forKey: PluginCatalog.disabledKey)

        MediaKeysSplit.migrate(defaults)
        #expect(defaults.stringArray(forKey: PluginCatalog.disabledKey) == [brightness, "com.notchtherock.clipboard", volume])
        // No layout was saved, so none is written: the home keeps its defaults.
        #expect(defaults.data(forKey: HomeLayoutStore.key) == nil)

        // A user who never had the old plugin keeps everything as it is.
        defaults.set(["com.notchtherock.clipboard"], forKey: PluginCatalog.disabledKey)
        MediaKeysSplit.migrate(defaults)
        #expect(defaults.stringArray(forKey: PluginCatalog.disabledKey) == ["com.notchtherock.clipboard"])
    }
}
