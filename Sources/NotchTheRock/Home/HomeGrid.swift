import CoreGraphics
import NotchKit

/// Point sizes of the home grid. A unit is 40 pt and tiles are 10 pt apart, so a small tile is
/// 90 × 90, a wide one 190 × 90 and a large one 190 × 190, and the 8-column grid is 390 pt wide:
/// Control Center's four small tiles to a row at the notch's scale.
enum HomeGrid {
    static let unit: CGFloat = 40
    static let gap: CGFloat = 10
    /// Concentric with the shape's bottom corners, one padding further in.
    static let cornerRadius: CGFloat = NotchLayout.openBottom - NotchSizing.padding

    /// Points spanned by `units` grid units and the gaps between them.
    static func length(_ units: Int) -> CGFloat {
        CGFloat(units) * unit + CGFloat(max(units - 1, 0)) * gap
    }

    /// The whole grid: 8 columns, 2 rows of 2 units.
    static var size: CGSize {
        CGSize(width: length(HomeLayout.columns), height: length(HomeLayout.unitRows))
    }

    static func size(of tile: TileSize) -> CGSize {
        CGSize(width: length(tile.columns), height: length(tile.rows))
    }

    static func frame(of placement: TilePlacement) -> CGRect {
        CGRect(
            origin: CGPoint(x: CGFloat(placement.origin.column) * (unit + gap), y: CGFloat(placement.origin.row) * (unit + gap)),
            size: size(of: placement.size)
        )
    }

    /// Width and height of an icon in the strip under the grid.
    static let stripIcon: CGFloat = 36

    /// The grid place nearest to a tile of `size` whose top-left corner is at `point`: the nearest
    /// cell's column and the nearest row, kept inside the grid.
    static func origin(nearest point: CGPoint, for size: TileSize) -> GridOrigin {
        let step = unit + gap
        let cell = step * CGFloat(HomeLayout.columnStep)
        let column = Int((point.x / cell).rounded()) * HomeLayout.columnStep
        let row = Int((point.y / (step * CGFloat(HomeLayout.rowHeight))).rounded()) * HomeLayout.rowHeight
        return GridOrigin(
            column: min(max(column, 0), HomeLayout.columns - size.columns),
            row: min(max(row, 0), HomeLayout.unitRows - size.rows)
        )
    }
}

/// Widths of the home's controls in the top band (see `BandLayout`).
enum HomeChrome {
    static let editWidth: CGFloat = 44
    static let gearWidth: CGFloat = 26
}
