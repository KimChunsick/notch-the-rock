import Foundation
import NotchKit

/// A plugin as the home shows it. Which of `tab` and `tile` it has decides its place (docs/plugins.md,
/// "홈과 타일"): a tile and a tab make a tile that opens the plugin's screen, a tab only makes a list
/// row, a tile only makes a display-only tile, and neither keeps the plugin out of the home.
struct HomePlugin {
    let pluginID: String
    /// The plugin's name, shown in the list and searched by name.
    let name: String
    /// SF Symbol of the plugin's list row.
    let symbol: String
    let tab: PluginTab?
    let tile: PluginTile?
    /// Whether the plugin has a page in the Settings window (`NotchPlugin.settingsView`), which the
    /// gear on its screen opens.
    var hasSettings = false

    /// Whether the plugin appears in the home at all.
    var isInHome: Bool { tab != nil || tile != nil }
}

/// Where a tile starts in the home grid, in grid units from the top-left corner.
struct GridOrigin: Hashable {
    var column: Int
    var row: Int
}

/// One tile in the home grid.
struct TilePlacement: Hashable {
    let pluginID: String
    var size: TileSize
    var origin: GridOrigin
}

/// The arrangement of the home grid in grid units, with the rules every arrangement keeps.
///
/// The grid is 8 columns wide; a row is 2 units tall and there are at most 2 rows, so tiles start
/// on unit row 0 or 2. Tiles stay inside the grid and never overlap. Edits that would break a rule
/// are refused and change nothing: the tile stays where it was (a move or a resize), or the plugin
/// stays in the list (an add). The layout stored from an earlier launch is checked again against
/// the plugins present now (`reconciled(with:)`).
struct HomeLayout: Equatable {
    static let columns = 8
    static let rowHeight = 2
    static let maxRows = 2
    static var unitRows: Int { maxRows * rowHeight }

    /// No tiles and no plugin known yet: every plugin with a tile is placed first-fit in order.
    static let empty = HomeLayout()

    private(set) var tiles: [TilePlacement]
    /// Plugins this layout has already placed or listed. A plugin with a tile that is not known is
    /// new and gets a place at the first fit; a known plugin without a tile stays in the list.
    private(set) var known: Set<String>

    init(tiles: [TilePlacement] = [], known: Set<String> = []) {
        self.tiles = tiles
        self.known = known
    }

    func tile(for pluginID: String) -> TilePlacement? {
        tiles.first { $0.pluginID == pluginID }
    }

    /// Whether a tile of `size` at `origin` lies inside the grid and starts on a row. Any stored
    /// coordinate is checked without overflowing.
    static func isInside(_ size: TileSize, at origin: GridOrigin) -> Bool {
        origin.column >= 0 && origin.column <= columns - size.columns
            && origin.row >= 0 && origin.row <= unitRows - size.rows
            && origin.row % rowHeight == 0
    }

    /// Whether a tile of `size` at `origin` fits inside the grid without covering another tile.
    func fits(_ size: TileSize, at origin: GridOrigin, ignoring pluginID: String? = nil) -> Bool {
        guard Self.isInside(size, at: origin) else { return false }
        let cells = Self.cells(of: size, at: origin)
        return !tiles.contains { $0.pluginID != pluginID && $0.cellsIntersect(cells) }
    }

    /// The first place a tile of `size` fits, row by row and left to right.
    func firstFit(_ size: TileSize, ignoring pluginID: String? = nil) -> GridOrigin? {
        for row in stride(from: 0, to: Self.unitRows, by: Self.rowHeight) {
            for column in 0..<Self.columns {
                let origin = GridOrigin(column: column, row: row)
                if fits(size, at: origin, ignoring: pluginID) { return origin }
            }
        }
        return nil
    }

    /// The layout for the plugins present now. Tiles of plugins that are gone, that lost their tile
    /// or the tile's size, or that break a rule (the earlier tile wins an overlap) leave the grid;
    /// new plugins with a tile take the first fit at their default size, in plugin order, or go to
    /// the list when nothing fits. Only present plugins stay known.
    ///
    /// Plugins arrive one at a time while the catalog loads them, so this never writes anything: the
    /// stored layout keeps the places of plugins that have not arrived yet.
    func reconciled(with plugins: [HomePlugin]) -> HomeLayout {
        let present = Dictionary(plugins.map { ($0.pluginID, $0) }, uniquingKeysWith: { first, _ in first })
        var result = HomeLayout(known: Set(plugins.filter(\.isInHome).map(\.pluginID)))
        for placement in tiles {
            guard let tile = present[placement.pluginID]?.tile,
                  tile.supportedSizes.contains(placement.size),
                  result.tile(for: placement.pluginID) == nil,
                  result.fits(placement.size, at: placement.origin)
            else { continue }
            result.tiles.append(placement)
        }
        for plugin in plugins where !known.contains(plugin.pluginID) {
            guard let tile = plugin.tile, result.tile(for: plugin.pluginID) == nil else { continue }
            result.add(plugin.pluginID, size: tile.defaultSize)
        }
        return result
    }

    // MARK: Edits

    /// Takes the tile off the grid; the plugin stays known, so it shows in the list from now on.
    mutating func remove(_ pluginID: String) {
        tiles.removeAll { $0.pluginID == pluginID }
        known.insert(pluginID)
    }

    /// Puts the plugin on the grid at the first fit. Refused when it is already there or nothing fits.
    @discardableResult
    mutating func add(_ pluginID: String, size: TileSize) -> Bool {
        known.insert(pluginID)
        guard tile(for: pluginID) == nil, let origin = firstFit(size) else { return false }
        tiles.append(TilePlacement(pluginID: pluginID, size: size, origin: origin))
        return true
    }

    /// Changes the tile's size where it is, or at the first fit when it does not fit there.
    /// Refused when it fits nowhere.
    @discardableResult
    mutating func resize(_ pluginID: String, to size: TileSize) -> Bool {
        guard let index = tiles.firstIndex(where: { $0.pluginID == pluginID }) else { return false }
        let current = tiles[index].origin
        guard let origin = fits(size, at: current, ignoring: pluginID) ? current : firstFit(size, ignoring: pluginID) else {
            return false
        }
        tiles[index].size = size
        tiles[index].origin = origin
        return true
    }

    /// Moves the tile to `origin`. Refused outside the grid, off a row or onto another tile.
    @discardableResult
    mutating func move(_ pluginID: String, to origin: GridOrigin) -> Bool {
        guard let index = tiles.firstIndex(where: { $0.pluginID == pluginID }),
              fits(tiles[index].size, at: origin, ignoring: pluginID)
        else { return false }
        tiles[index].origin = origin
        return true
    }

    // MARK: Cells

    fileprivate struct Cells {
        let columns: Range<Int>
        let rows: Range<Int>
    }

    fileprivate static func cells(of size: TileSize, at origin: GridOrigin) -> Cells {
        Cells(columns: origin.column..<(origin.column + size.columns), rows: origin.row..<(origin.row + size.rows))
    }
}

private extension TilePlacement {
    func cellsIntersect(_ cells: HomeLayout.Cells) -> Bool {
        let own = HomeLayout.cells(of: size, at: origin)
        return own.columns.overlaps(cells.columns) && own.rows.overlaps(cells.rows)
    }
}

// MARK: - Storage

/// Saves the home layout as JSON in the app's own defaults, under a key with the format version.
/// Missing or unreadable data gives the default layout (`HomeLayout.empty`); nothing is written
/// until the user edits the home.
struct HomeLayoutStore {
    static let key = "HomeLayout.v1"

    let defaults: UserDefaults

    func load() -> HomeLayout {
        guard let data = defaults.data(forKey: Self.key),
              let stored = try? JSONDecoder().decode(StoredLayout.self, from: data)
        else { return .empty }
        return stored.layout
    }

    func save(_ layout: HomeLayout) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(StoredLayout(layout)) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// The JSON form: `{"tiles":[{"plugin":…,"size":"small|wide|large","column":…,"row":…}],"known":[…]}`.
/// An unknown size name or a tile outside the grid makes the whole layout unreadable.
private struct StoredLayout: Codable {
    struct Tile: Codable {
        let plugin: String
        let size: String
        let column: Int
        let row: Int
    }

    let tiles: [Tile]
    let known: [String]

    init(_ layout: HomeLayout) {
        tiles = layout.tiles.map { Tile(plugin: $0.pluginID, size: Self.name(of: $0.size), column: $0.origin.column, row: $0.origin.row) }
        known = layout.known.sorted()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tiles = try container.decode([Tile].self, forKey: .tiles)
        known = try container.decode([String].self, forKey: .known)
        for tile in tiles {
            guard let size = Self.size(named: tile.size) else {
                throw DecodingError.dataCorruptedError(forKey: .tiles, in: container, debugDescription: "unknown tile size \(tile.size)")
            }
            guard HomeLayout.isInside(size, at: GridOrigin(column: tile.column, row: tile.row)) else {
                throw DecodingError.dataCorruptedError(forKey: .tiles, in: container, debugDescription: "tile of \(tile.plugin) outside the grid")
            }
        }
    }

    var layout: HomeLayout {
        HomeLayout(
            tiles: tiles.compactMap { tile in
                Self.size(named: tile.size).map { TilePlacement(pluginID: tile.plugin, size: $0, origin: GridOrigin(column: tile.column, row: tile.row)) }
            },
            known: Set(known)
        )
    }

    private static func name(of size: TileSize) -> String {
        switch size {
        case .small: "small"
        case .wide: "wide"
        case .large: "large"
        @unknown default: "small"
        }
    }

    private static func size(named name: String) -> TileSize? {
        TileSize.allCases.first { self.name(of: $0) == name }
    }
}
