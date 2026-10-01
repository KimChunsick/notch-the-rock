import NotchKit
import Observation

/// One item of the home in the order it is shown: grid tiles row by row, then the list.
struct HomeEntry: Equatable {
    enum Kind: Equatable {
        case tile(TileSize)
        case row
    }

    let pluginID: String
    let name: String
    let symbol: String
    let kind: Kind
    /// Whether choosing the entry opens the plugin's screen (the plugin has a tab).
    let opensDetail: Bool
}

/// A tile on the grid with the plugin it shows.
struct HomeTile {
    let placement: TilePlacement
    let plugin: HomePlugin
}

/// The home's plugins, their arrangement and edit mode. `NotchHostModel` owns it and sets
/// `plugins`; the home view reads it. Every edit is saved at once, so the arrangement is the same at
/// the next launch.
@MainActor
@Observable
final class HomeModel {
    /// Plugins in load order. The arrangement follows them without writing anything (see
    /// `HomeLayout.reconciled(with:)`).
    var plugins: [HomePlugin] = [] {
        didSet { layout = stored.reconciled(with: plugins) }
    }

    /// The arrangement shown now.
    private(set) var layout: HomeLayout
    private(set) var isEditing = false
    /// The plugin whose tile is being dragged in edit mode.
    private(set) var draggedTile: String?

    /// The arrangement saved by the last edit, or loaded at launch.
    @ObservationIgnored private var stored: HomeLayout
    @ObservationIgnored private let store: HomeLayoutStore

    init(store: HomeLayoutStore) {
        self.store = store
        stored = store.load()
        layout = stored
    }

    /// Grid tiles row by row, left to right.
    var tiles: [HomeTile] {
        layout.tiles
            .sorted { ($0.origin.row, $0.origin.column) < ($1.origin.row, $1.origin.column) }
            .compactMap { placement in plugin(placement.pluginID).map { HomeTile(placement: placement, plugin: $0) } }
    }

    /// Home plugins not on the grid, in load order: rows that open a plugin screen, and
    /// display-only tiles taken off the grid, which edit mode can add back.
    var list: [HomePlugin] {
        plugins.filter { $0.isInHome && layout.tile(for: $0.pluginID) == nil }
    }

    var entries: [HomeEntry] {
        tiles.map { Self.entry($0.plugin, kind: .tile($0.placement.size)) } + list.map { Self.entry($0, kind: .row) }
    }

    func plugin(_ pluginID: String) -> HomePlugin? {
        plugins.first { $0.pluginID == pluginID }
    }

    // MARK: Edit mode

    func beginEditing() {
        isEditing = true
    }

    /// Also ends a tile drag: drags only happen in edit mode.
    func finishEditing() {
        isEditing = false
        draggedTile = nil
    }

    /// A tile is being dragged in edit mode; the drag holds the notch open until `endDrag(_:)`.
    func beginDrag(_ pluginID: String) {
        guard isEditing else { return }
        draggedTile = pluginID
    }

    /// The drag of `pluginID`'s tile ended, dropped or cancelled.
    func endDrag(_ pluginID: String) {
        if draggedTile == pluginID { draggedTile = nil }
    }

    /// Takes a tile off the grid into the list.
    func remove(_ pluginID: String) {
        edit { layout in
            layout.remove(pluginID)
            return true
        }
    }

    func canAdd(_ pluginID: String) -> Bool {
        guard let tile = plugin(pluginID)?.tile, layout.tile(for: pluginID) == nil else { return false }
        return layout.firstFit(tile.defaultSize) != nil
    }

    /// Puts a listed plugin's tile on the grid at the first fit, at its default size.
    @discardableResult
    func add(_ pluginID: String) -> Bool {
        guard let tile = plugin(pluginID)?.tile else { return false }
        return edit { $0.add(pluginID, size: tile.defaultSize) }
    }

    func canResize(_ pluginID: String, to size: TileSize) -> Bool {
        var copy = layout
        return supports(pluginID, size) && copy.resize(pluginID, to: size)
    }

    /// Changes a tile to one of the sizes its plugin supports; see `HomeLayout.resize(_:to:)`.
    @discardableResult
    func resize(_ pluginID: String, to size: TileSize) -> Bool {
        supports(pluginID, size) && edit { $0.resize(pluginID, to: size) }
    }

    @discardableResult
    func move(_ pluginID: String, to origin: GridOrigin) -> Bool {
        edit { $0.move(pluginID, to: origin) }
    }

    private func supports(_ pluginID: String, _ size: TileSize) -> Bool {
        plugin(pluginID)?.tile?.supportedSizes.contains(size) ?? false
    }

    /// Applies `change` to the shown arrangement and saves it when it changed something.
    @discardableResult
    private func edit(_ change: (inout HomeLayout) -> Bool) -> Bool {
        var changed = layout
        guard change(&changed) else { return false }
        layout = changed
        stored = changed
        store.save(changed)
        return true
    }

    private static func entry(_ plugin: HomePlugin, kind: HomeEntry.Kind) -> HomeEntry {
        HomeEntry(pluginID: plugin.pluginID, name: plugin.name, symbol: plugin.symbol, kind: kind, opensDetail: plugin.tab != nil)
    }
}
