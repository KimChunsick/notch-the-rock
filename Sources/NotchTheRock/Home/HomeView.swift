import NotchKit
import SwiftUI

/// The home: the plugin tile grid and, below it, one row per plugin without a grid place, or the
/// quick search while it is open. Always as wide as the grid; as tall as the rows in use and the
/// list. The keyboard's focus ring (`HomeKeyboard.focus`) is drawn around its tile or row.
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
                HomeList(host: host, plugins: list)
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

/// One tile. Tapping it opens the plugin's screen when the plugin has one. In edit mode it shows
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
            tile.plugin.tile?.content(placement.size)
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
                .help("목록으로 옮기기")
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
        .onTapGesture {
            if !editing, tile.plugin.tab != nil { host.open(pluginID: placement.pluginID) }
        }
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

/// One row per plugin without a grid place. Long lists scroll after six rows, and to the row with
/// the keyboard's focus ring (`NotchHostModel.listScrollTarget`).
private struct HomeList: View {
    let host: NotchHostModel
    let plugins: [HomePlugin]

    static let rowHeight: CGFloat = 28
    static let spacing: CGFloat = 4
    static let visibleRows = 6

    var body: some View {
        if plugins.count > Self.visibleRows {
            ScrollViewReader { proxy in
                ScrollView { rows }
                    .scrollIndicators(.never)
                    .frame(height: CGFloat(Self.visibleRows) * Self.rowHeight + CGFloat(Self.visibleRows - 1) * Self.spacing)
                    // The focus also outlives a visit to a plugin's screen, where the list is gone.
                    .onAppear { if let target = host.listScrollTarget { proxy.scrollTo(target) } }
                    .onChange(of: host.listScrollTarget) { _, target in
                        if let target { proxy.scrollTo(target) }
                    }
            }
        } else {
            rows
        }
    }

    private var rows: some View {
        VStack(spacing: Self.spacing) {
            ForEach(plugins, id: \.pluginID) { plugin in
                HomeRow(host: host, plugin: plugin)
                    .id(plugin.pluginID)
            }
        }
    }
}

/// The plugin's icon and name. It opens the plugin's screen; in edit mode a plugin with a tile has
/// a button that puts the tile on the grid.
private struct HomeRow: View {
    let host: NotchHostModel
    let plugin: HomePlugin

    var body: some View {
        let home = host.home
        let editing = home.isEditing
        HStack(spacing: 8) {
            Image(systemName: plugin.symbol)
                .frame(width: 20)
            Text(plugin.name)
                .lineLimit(1)
            Spacer(minLength: 0)
            if editing {
                if plugin.tile != nil {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { _ = home.add(plugin.pluginID) }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                    }
                    .buttonStyle(.plain)
                    .disabled(!home.canAdd(plugin.pluginID))
                    .help("격자에 넣기")
                }
            } else if plugin.tab != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: HomeList.rowHeight, maxHeight: HomeList.rowHeight)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.08)))
        .homeFocusRing(!editing && host.keyboard.focus == plugin.pluginID, cornerRadius: 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if !editing, plugin.tab != nil { host.open(pluginID: plugin.pluginID) }
        }
    }
}

/// A plugin's screen's controls in the top band, where the home has its own: ‹ and the plugin's
/// name in the left wing, back to the home, and the plugin's settings gear in the right wing when it
/// has a settings page. The shape grows until the left wing holds the whole name, up to its widest;
/// a name longer than that is cut short, never under the camera's clearance.
struct PluginBand: View {
    let host: NotchHostModel
    let plugin: HomePlugin
    let notchSize: CGSize
    let width: CGFloat
    let openSettings: @MainActor (_ pluginID: String?) -> Void

    /// The narrowest expanded shape that shows the plugin's whole name beside the camera.
    static func minimumWidth(notch: CGSize, plugin: HomePlugin) -> CGFloat {
        BandLayout.minimumWidth(notch: notch, leading: backWidth(plugin.name), trailing: plugin.hasSettings ? HomeChrome.gearWidth : 0)
    }

    /// The back control's own width with the whole name, measured once per name.
    static func backWidth(_ name: String) -> CGFloat {
        if let width = backWidths[name] { return width }
        let width = NSHostingView(rootView: BackLabel(name: name)).fittingSize.width.rounded(.up)
        backWidths[name] = width
        return width
    }

    private static var backWidths: [String: CGFloat] = [:]

    func back() {
        host.back()
    }

    /// What the gear does; nil for a plugin without a settings page, which has no gear.
    var settingsAction: (@MainActor () -> Void)? {
        guard plugin.hasSettings else { return nil }
        return { [openSettings, plugin] in openSettings(plugin.pluginID) }
    }

    var body: some View {
        let leading = min(Self.backWidth(plugin.name), BandLayout.wingRoom(notch: notchSize, width: width))
        let layout = BandLayout(notch: notchSize, width: width, leading: leading, trailing: HomeChrome.gearWidth)
        ZStack(alignment: .topLeading) {
            Button(action: back) {
                BackLabel(name: plugin.name)
                    .frame(width: layout.leadingFrame.width, height: layout.leadingFrame.height, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .help("홈으로")
            .accessibilityLabel("\(plugin.name), 홈으로 돌아가기")
            .position(x: layout.leadingFrame.midX, y: layout.leadingFrame.midY)
            if let settingsAction {
                BandGear(frame: layout.trailingFrame, label: "\(plugin.name) 설정", action: settingsAction)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.9))
        .frame(width: width, height: notchSize.height, alignment: .topLeading)
    }
}

/// ‹ and a plugin's name, on one line that is cut short at the end when it has to be.
private struct BackLabel: View {
    let name: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.left")
                .font(.system(size: 12, weight: .semibold))
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// The settings gear in the band's right wing, on the home and on a plugin's screen.
private struct BandGear: View {
    let frame: CGRect
    let label: String
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .medium))
                .frame(width: frame.width, height: frame.height)
                .contentShape(Rectangle())
        }
        .help(label)
        .accessibilityLabel(label)
        .position(x: frame.midX, y: frame.midY)
    }
}

/// The home's controls in the top band: 편집/완료 in the left wing, the settings gear in the right.
struct HomeBand: View {
    let home: HomeModel
    let notchSize: CGSize
    let width: CGFloat
    let openSettings: @MainActor (_ pluginID: String?) -> Void

    var body: some View {
        let layout = BandLayout(notch: notchSize, width: width, leading: HomeChrome.editWidth, trailing: HomeChrome.gearWidth)
        ZStack(alignment: .topLeading) {
            Button {
                if home.isEditing { home.finishEditing() } else { home.beginEditing() }
            } label: {
                Text(home.isEditing ? "완료" : "편집")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: layout.leadingFrame.width, height: layout.leadingFrame.height)
                    .background(Capsule().fill(.white.opacity(home.isEditing ? 0.24 : 0.1)))
                    .contentShape(Capsule())
            }
            .help(home.isEditing ? "편집 마치기" : "홈 편집")
            .position(x: layout.leadingFrame.midX, y: layout.leadingFrame.midY)
            BandGear(frame: layout.trailingFrame, label: "설정") { openSettings(nil) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.9))
        .frame(width: width, height: notchSize.height, alignment: .topLeading)
    }
}
