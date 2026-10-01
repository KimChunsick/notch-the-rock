import Foundation
import NotchKit

/// A plugin as the home shows it (docs/plugins.md, "홈과 타일"). Every plugin is in the home: as a tile
/// on the grid or as an icon in the strip under it. A plugin's own tile (`tile`) takes the first free
/// place when the plugin first appears; a plugin without one can be put on the grid as the host's
/// default tile, small, with its symbol and name. A tile or icon opens the plugin's screen when it
/// has one (`tab`).
struct HomePlugin {
    let pluginID: String
    /// The plugin's name, shown on its default tile and as its icon's tooltip, and searched by name.
    let name: String
    /// SF Symbol of the plugin's strip icon and default tile.
    let symbol: String
    let tab: PluginTab?
    let tile: PluginTile?
    /// Whether the plugin has a page in the Settings window (`NotchPlugin.settingsView`), which the
    /// gear on its screen opens.
    var hasSettings = false

    /// The sizes its grid tile can take, the first being the one it starts at: its own tile's, or
    /// small only for the host's default tile.
    var tileSizes: [TileSize] { tile?.supportedSizes ?? [.small] }
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
/// on unit row 0 or 2. A cell is a small tile wide, so tiles start on unit column 0, 2, 4 or 6, never
/// half a cell over. Tiles stay inside the grid and never overlap. Edits that would break a rule
/// are refused and change nothing: the tile stays where it was (a move or a resize), or the plugin
/// stays in the strip (an add). The layout stored from an earlier launch is checked again against
/// the plugins present now (`reconciled(with:)`).
struct HomeLayout: Equatable {
    static let columns = 8
    static let rowHeight = 2
    static let maxRows = 2
    static var unitRows: Int { maxRows * rowHeight }
    /// Units from one cell's column to the next.
    static let columnStep = TileSize.small.columns

    /// No tiles and no plugin known yet: every plugin with its own tile is placed first-fit in order.
    static let empty = HomeLayout()

    private(set) var tiles: [TilePlacement]
    /// Plugins this layout has already placed or put in the strip. A plugin with its own tile that is
    /// not known is new and gets a place at the first fit; a known plugin off the grid stays in the
    /// strip.
    private(set) var known: Set<String>

    init(tiles: [TilePlacement] = [], known: Set<String> = []) {
        self.tiles = tiles
        self.known = known
    }

    func tile(for pluginID: String) -> TilePlacement? {
        tiles.first { $0.pluginID == pluginID }
    }

    /// Whether a tile of `size` at `origin` lies inside the grid and starts on a row. Any stored
    /// coordinate is checked without overflowing. A tile stored half a cell over is inside; it is
    /// moved onto a cell by `reconciled(with:)`.
    static func isInside(_ size: TileSize, at origin: GridOrigin) -> Bool {
        origin.column >= 0 && origin.column <= columns - size.columns
            && origin.row >= 0 && origin.row <= unitRows - size.rows
            && origin.row % rowHeight == 0
    }

    /// Whether a tile of `size` at `origin` fits inside the grid on a cell without covering another tile.
    func fits(_ size: TileSize, at origin: GridOrigin, ignoring pluginID: String? = nil) -> Bool {
        guard Self.isInside(size, at: origin), origin.column % Self.columnStep == 0 else { return false }
        let cells = Self.cells(of: size, at: origin)
        return !tiles.contains { $0.pluginID != pluginID && $0.cellsIntersect(cells) }
    }

    /// The first place a tile of `size` fits, row by row and left to right.
    func firstFit(_ size: TileSize, ignoring pluginID: String? = nil) -> GridOrigin? {
        for row in stride(from: 0, to: Self.unitRows, by: Self.rowHeight) {
            for column in stride(from: 0, to: Self.columns, by: Self.columnStep) {
                let origin = GridOrigin(column: column, row: row)
                if fits(size, at: origin, ignoring: pluginID) { return origin }
            }
        }
        return nil
    }

    /// The layout for the plugins present now. Tiles of plugins that are gone, that lost the tile's
    /// size, or that break a rule (the earlier tile wins an overlap) leave the grid; a tile stored half
    /// a cell over, before tiles kept to cells, moves to the nearest free cell of its row after the
    /// others are placed, or leaves the grid when its row is full. New plugins with their own tile
    /// take the first fit at their default size, in plugin order, or go to the strip when nothing
    /// fits. Only present plugins stay known.
    ///
    /// Plugins arrive one at a time while the catalog loads them, so this never writes anything: the
    /// stored layout keeps the places of plugins that have not arrived yet.
    func reconciled(with plugins: [HomePlugin]) -> HomeLayout {
        let present = Dictionary(plugins.map { ($0.pluginID, $0) }, uniquingKeysWith: { first, _ in first })
        var result = HomeLayout(known: Set(plugins.map(\.pluginID)))
        var offCell: [TilePlacement] = []
        for placement in tiles {
            guard let plugin = present[placement.pluginID],
                  plugin.tileSizes.contains(placement.size),
                  result.tile(for: placement.pluginID) == nil
            else { continue }
            if result.fits(placement.size, at: placement.origin) {
                result.tiles.append(placement)
            } else if Self.isInside(placement.size, at: placement.origin), placement.origin.column % Self.columnStep != 0 {
                offCell.append(placement)
            }
        }
        for var placement in offCell where result.tile(for: placement.pluginID) == nil {
            guard let origin = result.nearestFit(placement.size, to: placement.origin) else { continue }
            placement.origin = origin
            result.tiles.append(placement)
        }
        for plugin in plugins where !known.contains(plugin.pluginID) {
            guard let tile = plugin.tile, result.tile(for: plugin.pluginID) == nil else { continue }
            result.add(plugin.pluginID, size: tile.defaultSize)
        }
        return result
    }

    /// The free place on `origin`'s row nearest to its column, the left one of two as near.
    private func nearestFit(_ size: TileSize, to origin: GridOrigin) -> GridOrigin? {
        stride(from: 0, through: Self.columns - size.columns, by: Self.columnStep)
            .map { GridOrigin(column: $0, row: origin.row) }
            .filter { fits(size, at: $0) }
            .min { abs($0.column - origin.column) < abs($1.column - origin.column) }
    }

    // MARK: Edits

    /// Takes the tile off the grid; the plugin stays known, so it shows in the strip from now on.
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

    /// Moves the tile to `origin`. Refused outside the grid, off a row or a cell, or onto another tile.
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
