import NotchKit
import SwiftUI

/// The home: the plugin tile grid and, below it, a strip of round icons for the plugins without a
/// grid place, or the quick search while it is open. Always as wide as the grid; as tall as the rows
/// in use and the strip. The keyboard's focus ring (`HomeKeyboard.focus`) is drawn around its tile
/// or icon.
struct HomeView: View {
    let host: NotchHostModel

    var body: some View {
        if host.keyboard.query != nil {
            QuickSearchView(host: host)
                .frame(width: HomeGrid.size.width, alignment: .topLeading)
        } else {
            plugins
        }
    }

    private var plugins: some View {
        let home = host.home
        let tiles = home.tiles
        let list = home.list
        return VStack(alignment: .leading, spacing: HomeGrid.gap) {
            if !tiles.isEmpty || home.isEditing {
                HomeGridView(host: host, tiles: tiles)
            }
            if !list.isEmpty {
                HomeStrip(host: host, plugins: list)
            }
            if home.isEditing, let notice = home.notice {
                Text(notice)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            if tiles.isEmpty && list.isEmpty && !home.isEditing {
                Text("아직 켠 플러그인이 없어요")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
        }
        .foregroundStyle(.white)
        .frame(width: HomeGrid.size.width, alignment: .topLeading)
    }
}

/// The tiles at their grid places. In edit mode the grid shows both rows with its free slots.
private struct HomeGridView: View {
    let host: NotchHostModel
    let tiles: [HomeTile]

    var body: some View {
        let editing = host.home.isEditing
        let rows = editing ? HomeLayout.unitRows : tiles.map { $0.placement.origin.row + $0.placement.size.rows }.max() ?? 0
        ZStack(alignment: .topLeading) {
            if editing {
                ForEach(0..<(HomeLayout.columns / TileSize.small.columns * HomeLayout.maxRows), id: \.self) { slot in
                    let columns = HomeLayout.columns / TileSize.small.columns
                    let frame = HomeGrid.frame(of: TilePlacement(
                        pluginID: "",
                        size: .small,
                        origin: GridOrigin(column: slot % columns * TileSize.small.columns, row: slot / columns * HomeLayout.rowHeight)
                    ))
                    RoundedRectangle(cornerRadius: HomeGrid.cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
            ForEach(tiles, id: \.placement.pluginID) { tile in
                TileView(host: host, tile: tile)
            }
        }
        .frame(width: HomeGrid.size.width, height: HomeGrid.length(rows), alignment: .topLeading)
    }
}

/// One tile: the plugin's own, or the host's default tile (`DefaultTile`) for a plugin without one.
/// Tapping it opens the plugin's screen. In edit mode it shows
/// a remove button and a size menu, and it can be dragged to another grid place; the home knows
/// about the drag from its start to its drop or cancellation, so the notch stays open meanwhile.
private struct TileView: View {
    let host: NotchHostModel
    let tile: HomeTile
    @State private var drag: CGSize = .zero
    /// Resets when the drag ends, also when it is cancelled.
    @GestureState private var isDragging = false

    private static let snap = Animation.spring(response: 0.3, dampingFraction: 0.8)

    var body: some View {
        let home = host.home
        let editing = home.isEditing
        let placement = tile.placement
        let frame = HomeGrid.frame(of: placement)
        let shape = RoundedRectangle(cornerRadius: HomeGrid.cornerRadius, style: .continuous)
        ZStack {
            // Opaque, so the free slots drawn in edit mode do not show through.
            shape.fill(Color(white: editing ? 0.15 : 0.11))
            (tile.plugin.tile?.content(placement.size) ?? AnyView(DefaultTile(plugin: tile.plugin)))
                .frame(width: frame.width, height: frame.height)
                .clipShape(shape)
                .allowsHitTesting(!editing)
        }
        .frame(width: frame.width, height: frame.height)
        .contentShape(shape)
        .homeFocusRing(!editing && host.keyboard.focus == placement.pluginID, cornerRadius: HomeGrid.cornerRadius)
        .overlay(alignment: .topLeading) {
            if editing {
                Button {
                    withAnimation(Self.snap) { home.remove(placement.pluginID) }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.black, .white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("위젯에서 빼기")
                .offset(x: -5, y: -5)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if editing, let sizes = tile.plugin.tile?.supportedSizes, sizes.count > 1 {
                Menu {
                    ForEach(sizes, id: \.self) { size in
                        Button {
                            withAnimation(Self.snap) { _ = home.resize(placement.pluginID, to: size) }
                        } label: {
                            if size == placement.size {
                                Label(Self.title(of: size), systemImage: "checkmark")
                            } else {
                                Text(Self.title(of: size))
                            }
                        }
                        .disabled(size != placement.size && !home.canResize(placement.pluginID, to: size))
                    }
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.white.opacity(0.85)))
                        .foregroundStyle(.black)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
                .help("크기 바꾸기")
                .padding(6)
            }
        }
        .offset(drag)
        .zIndex(drag == .zero ? 0 : 1)
        .offset(x: frame.minX, y: frame.minY)
        .onTapGesture { host.tapHomePlugin(placement.pluginID) }
        .gesture(
            DragGesture(minimumDistance: 3)
                .updating($isDragging) { _, dragging, _ in dragging = true }
                .onChanged { drag = $0.translation }
                .onEnded { value in
                    let corner = CGPoint(x: frame.minX + value.translation.width, y: frame.minY + value.translation.height)
                    withAnimation(Self.snap) {
                        _ = home.move(placement.pluginID, to: HomeGrid.origin(nearest: corner, for: placement.size))
                        drag = .zero
                    }
                },
            including: editing ? .all : .subviews
        )
        .onChange(of: isDragging) { _, dragging in
            if dragging {
                home.beginDrag(placement.pluginID)
            } else {
                home.endDrag(placement.pluginID)
                // A cancelled drag has no drop: the tile springs back.
                if drag != .zero { withAnimation(Self.snap) { drag = .zero } }
            }
        }
        .onDisappear { home.endDrag(placement.pluginID) }
    }

    static func title(of size: TileSize) -> String {
        switch size {
        case .small: "작게 (2x2)"
        case .wide: "넓게 (4x2)"
        case .large: "크게 (4x4)"
        @unknown default: "\(size.columns)x\(size.rows)"
        }
    }
}

/// The host's tile for a plugin without one of its own: the plugin's symbol over its name.
private struct DefaultTile: View {
    let plugin: HomePlugin

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: plugin.symbol)
                .font(.system(size: 24, weight: .medium))
            Text(plugin.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(8)
    }
}

/// The host's screen for a plugin without one of its own: the plugin's symbol and name on a card as
/// wide as the host offers and, when the plugin has a settings page, a button that opens it. Like
/// any plugin's screen it adds no padding of its own.
struct DefaultScreen: View {
    let plugin: HomePlugin
    let openSettings: @MainActor (_ pluginID: String?) -> Void

    /// What 설정 열기 does; nil for a plugin without a settings page, which has no button.
    var settingsAction: (@MainActor () -> Void)? {
        guard plugin.hasSettings else { return nil }
        return { [openSettings, plugin] in openSettings(plugin.pluginID) }
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: plugin.symbol)
                .font(.system(size: 28, weight: .medium))
            Text(plugin.name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let settingsAction {
                Button(action: settingsAction) {
                    Text("설정 열기")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 14)
                        .background(Capsule().fill(.white.opacity(0.14)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: HomeGrid.cornerRadius, style: .continuous).fill(Color(white: 0.11)))
    }
}
