import Foundation
import NotchKit

/// The volume and brightness keys were one built-in plugin, `com.notchtherock.mediakeys`, before
/// they became two that turn on and off apart. What the app saved about the old one becomes theirs:
/// its home tile is the volume plugin's, with the brightness plugin's small tile beside it when
/// there is room; its list row becomes both list rows; turned off, both are off. Afterwards nothing
/// names the old plugin, so this changes what it finds once and leaves later edits alone. Runs at
/// launch, before the home and the catalog read the defaults.
@MainActor
enum MediaKeysSplit {
    static let retiredID = "com.notchtherock.mediakeys"
    static let volumeID = "com.notchtherock.volume"
    static let brightnessID = "com.notchtherock.brightness"

    static func migrate(_ defaults: UserDefaults) {
        if let disabled = defaults.stringArray(forKey: PluginCatalog.disabledKey), disabled.contains(retiredID) {
            let migrated = Set(disabled).subtracting([retiredID]).union([volumeID, brightnessID])
            defaults.set(migrated.sorted(), forKey: PluginCatalog.disabledKey)
        }
        let store = HomeLayoutStore(defaults: defaults)
        if let layout = migrated(store.load()) {
            store.save(layout)
        }
    }

    /// `layout` with the old plugin's tile and list row handed over, or nil when it does not name
    /// the old plugin. A brightness tile with no room beside the volume one is left out and not
    /// marked known, so the home gives it the first free place as it does any new plugin.
    static func migrated(_ layout: HomeLayout) -> HomeLayout? {
        guard layout.known.contains(retiredID) || layout.tile(for: retiredID) != nil else { return nil }
        let known = layout.known.subtracting([retiredID]).union([volumeID])
        guard let old = layout.tile(for: retiredID) else {
            return HomeLayout(tiles: layout.tiles, known: known.union([brightnessID]))
        }
        let tiles = layout.tiles.map { $0.pluginID == retiredID ? TilePlacement(pluginID: volumeID, size: old.size, origin: old.origin) : $0 }
        let result = HomeLayout(tiles: tiles, known: known)
        let besides = [
            GridOrigin(column: old.origin.column + old.size.columns, row: old.origin.row),
            GridOrigin(column: old.origin.column - TileSize.small.columns, row: old.origin.row),
        ]
        guard let origin = besides.first(where: { result.fits(.small, at: $0) }) else { return result }
        return HomeLayout(
            tiles: tiles + [TilePlacement(pluginID: brightnessID, size: .small, origin: origin)],
            known: known.union([brightnessID])
        )
    }
}
