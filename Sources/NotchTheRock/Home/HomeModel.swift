import NotchKit
import Observation

/// One item of the home in the order it is shown: grid tiles row by row, then the strip's icons
/// (`row`).
struct HomeEntry: Equatable {
    enum Kind: Equatable {
        case tile(TileSize)
        case row
    }

    let pluginID: String
    let name: String
    let symbol: String
    let kind: Kind
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
    /// Why the last add in edit mode put nothing on the grid; cleared by the next edit and when
    /// editing ends.
    private(set) var notice: String?
    /// The strip icon under the pointer, whose name shows in a bubble over it.
    private(set) var hoveredIcon: String?

    static let fullGridNotice = "빈 칸이 없어서 위젯으로 올릴 수 없어요"

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

    /// Plugins not on the grid, in load order: the icons of the strip under it, which edit mode
    /// puts on the grid.
    var list: [HomePlugin] {
        plugins.filter { layout.tile(for: $0.pluginID) == nil }
    }

    var entries: [HomeEntry] {
        tiles.map { Self.entry($0.plugin, kind: .tile($0.placement.size)) } + list.map { Self.entry($0, kind: .row) }
    }

    func plugin(_ pluginID: String) -> HomePlugin? {
        plugins.first { $0.pluginID == pluginID }
    }

    /// The pointer entered (`true`) or left a strip icon. A leave reported after the pointer
    /// entered the next icon does not clear that one.
    func setHovering(_ hovering: Bool, icon pluginID: String) {
        if hovering {
            hoveredIcon = pluginID
        } else if hoveredIcon == pluginID {
            hoveredIcon = nil
        }
    }

    // MARK: Edit mode

    func beginEditing() {
        isEditing = true
    }

    /// Also ends a tile drag: drags only happen in edit mode.
    func finishEditing() {
        isEditing = false
        draggedTile = nil
        notice = nil
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

    /// Takes a tile off the grid into the strip.
    func remove(_ pluginID: String) {
        edit { layout in
            layout.remove(pluginID)
            return true
        }
    }

    func canAdd(_ pluginID: String) -> Bool {
        guard let plugin = plugin(pluginID), layout.tile(for: pluginID) == nil else { return false }
        return layout.firstFit(plugin.tileSizes[0]) != nil
    }

    /// Puts a plugin from the strip on the grid at the first fit, at its default size: its own tile's
    /// first size, or the default tile's. When nothing fits nothing moves, and `notice` says why.
    @discardableResult
    func add(_ pluginID: String) -> Bool {
        guard let plugin = plugin(pluginID), layout.tile(for: pluginID) == nil else { return false }
        let added = edit { $0.add(pluginID, size: plugin.tileSizes[0]) }
        if !added { notice = Self.fullGridNotice }
        return added
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
        plugin(pluginID)?.tileSizes.contains(size) ?? false
    }

    /// Applies `change` to the shown arrangement and saves it when it changed something.
    @discardableResult
    private func edit(_ change: (inout HomeLayout) -> Bool) -> Bool {
        var changed = layout
        guard change(&changed) else { return false }
        layout = changed
        stored = changed
        notice = nil
        store.save(changed)
        return true
    }

    private static func entry(_ plugin: HomePlugin, kind: HomeEntry.Kind) -> HomeEntry {
        HomeEntry(pluginID: plugin.pluginID, name: plugin.name, symbol: plugin.symbol, kind: kind)
    }
}
