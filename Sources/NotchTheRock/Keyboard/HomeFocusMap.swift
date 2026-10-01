/// Arrow-key movement of the focus ring over the home: spatially between grid tiles, left and right
/// along the strip under the grid, and from the grid's bottom into the strip and back.
enum HomeDirection {
    case up
    case down
    case left
    case right
}

struct HomeFocusMap {
    let tiles: [TilePlacement]
    /// The strip's icons from left to right.
    let list: [String]

    /// The entry an arrow moves the focus to. With no focus (or a focus on an entry that is gone)
    /// any arrow focuses the first entry; at an edge the focus stays.
    func target(from current: String?, _ direction: HomeDirection) -> String? {
        let ordered = tiles.sorted { ($0.origin.row, $0.origin.column) < ($1.origin.row, $1.origin.column) }
        guard let current else { return ordered.first?.pluginID ?? list.first }
        if let index = list.firstIndex(of: current) {
            switch direction {
            case .right: return list[min(index + 1, list.count - 1)]
            case .left: return list[max(index - 1, 0)]
            case .up: return bottomTile(ordered)?.pluginID ?? current
            case .down: return current
            }
        }
        guard let tile = ordered.first(where: { $0.pluginID == current }) else {
            return ordered.first?.pluginID ?? list.first
        }
        if let next = nearest(to: tile, direction, among: ordered) { return next.pluginID }
        if direction == .down, let first = list.first { return first }
        return current
    }

    /// The closest tile in `direction`: one that shares rows (left, right) or columns (up, down)
    /// with `tile` comes first, then the smaller gap, then the closer center; ties go in reading order.
    private func nearest(to tile: TilePlacement, _ direction: HomeDirection, among ordered: [TilePlacement]) -> TilePlacement? {
        let from = Cells(tile)
        let scored = ordered.compactMap { candidate -> (TilePlacement, Int, Int, Int)? in
            let to = Cells(candidate)
            let gap: Int
            let overlap: Int
            let offset: Int
            switch direction {
            case .right: (gap, overlap, offset) = (to.minX - from.maxX, from.overlapY(to), abs(to.midY2 - from.midY2))
            case .left: (gap, overlap, offset) = (from.minX - to.maxX, from.overlapY(to), abs(to.midY2 - from.midY2))
            case .down: (gap, overlap, offset) = (to.minY - from.maxY, from.overlapX(to), abs(to.midX2 - from.midX2))
            case .up: (gap, overlap, offset) = (from.minY - to.maxY, from.overlapX(to), abs(to.midX2 - from.midX2))
            }
            guard candidate.pluginID != tile.pluginID, gap >= 0 else { return nil }
            return (candidate, overlap > 0 ? 0 : 1, gap, offset)
        }
        // `min(by:)` keeps the first of equals, which is the earlier one in reading order.
        return scored.min { ($0.1, $0.2, $0.3) < ($1.1, $1.2, $1.3) }?.0
    }

    /// The lowest tile, leftmost first: where Up from the strip goes.
    private func bottomTile(_ ordered: [TilePlacement]) -> TilePlacement? {
        ordered.min { (-Cells($0).maxY, $0.origin.column) < (-Cells($1).maxY, $1.origin.column) }
    }

    /// A tile's extent in grid units; centers are doubled to stay whole numbers.
    private struct Cells {
        let minX: Int
        let maxX: Int
        let minY: Int
        let maxY: Int

        init(_ tile: TilePlacement) {
            minX = tile.origin.column
            maxX = tile.origin.column + tile.size.columns
            minY = tile.origin.row
            maxY = tile.origin.row + tile.size.rows
        }

        var midX2: Int { minX + maxX }
        var midY2: Int { minY + maxY }

        func overlapX(_ other: Cells) -> Int { min(maxX, other.maxX) - max(minX, other.minX) }
        func overlapY(_ other: Cells) -> Int { min(maxY, other.maxY) - max(minY, other.minY) }
    }
}
