import SwiftUI

/// The size of a tile in the home grid, in grid units. The grid is 8 columns wide and each row is
/// 2 units tall. How many points a unit takes is the host's decision.
public enum TileSize: Hashable, Sendable, CaseIterable {
    /// 2 × 2 units.
    case small
    /// 4 × 2 units.
    case wide
    /// 4 × 4 units.
    case large

    public var columns: Int {
        switch self {
        case .small: 2
        case .wide, .large: 4
        }
    }

    public var rows: Int {
        switch self {
        case .small, .wide: 2
        case .large: 4
        }
    }
}

/// A plugin's tile in the home: the sizes it can be shown at and the view for each size.
///
/// When the plugin also has an `expandedTab`, tapping the tile opens that tab; without one the tile
/// only shows information. The view should have a definite intrinsic size (no `.infinity` frames):
/// the host places it in the tile's frame.
public struct PluginTile {
    /// The sizes the user can choose from, never empty. The first is the size a new tile starts at.
    public let supportedSizes: [TileSize]
    /// The view for one of `supportedSizes`. The host calls it on the main actor.
    public let content: @MainActor (TileSize) -> AnyView

    /// Returns nil when `supportedSizes` is empty: the plugin then has no tile. A plugin runs inside
    /// the app, so this mistake leaves the tile out instead of stopping the app.
    public init?<Content: View>(
        supportedSizes: [TileSize],
        @ViewBuilder content: @escaping @MainActor (TileSize) -> Content
    ) {
        guard !supportedSizes.isEmpty else { return nil }
        self.supportedSizes = supportedSizes
        self.content = { AnyView(content($0)) }
    }

    /// The size a new tile starts at: the first of `supportedSizes`.
    public var defaultSize: TileSize { supportedSizes[0] }
}
