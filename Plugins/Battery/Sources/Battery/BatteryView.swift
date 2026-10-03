import AppKit
import SwiftUI

/// The expanded tab at the size of what it draws; the host adds the margin around it. Two rows: the
/// battery symbol and the percentage with the state and the remaining time, and below them the
/// apps using the most energy as icons and the connected peripherals as chips, each item's name (and a
/// peripheral's readings) in a bubble while the pointer is on it; a lower row wider than the screen is
/// offered scrolls sideways. Offered more width (under a wider band), the top row, or
/// without a reading a small dimmed symbol and the message, goes to either end.
struct BatteryView: View {
    /// An item of the lower row, the one whose name shows in a bubble.
    enum Hovered: Hashable {
        /// An app, by its bundle path.
        case app(String)
        /// A peripheral, by its `PeripheralBattery.id`.
        case peripheral(String)
    }

    /// The battery symbol's size, the room its image keeps left of the outline and the outline's
    /// height at that size (measured in a render, the same for every battery symbol; the image of
    /// the charging one is taller, with the outline in its middle). The room is taken off so the
    /// outline sits on the screen's leading edge like the content of the other screens, and the
    /// symbol takes only its outline's height in the row.
    private static let glyphSize: CGFloat = 44
    private static let glyphLeadingRoom: CGFloat = 5.5
    private static let glyphOutlineHeight: CGFloat = 30
    /// The percentage's size, and how far its line reaches above the digits' cap height and below
    /// their baseline: taken off so the digits centre on the symbol and the row is only as tall as
    /// what it draws.
    private static let percentageSize: CGFloat = 32
    private static let percentageRoom: (top: CGFloat, bottom: CGFloat) = {
        let system = NSFont.systemFont(ofSize: percentageSize, weight: .semibold)
        let font = system.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: percentageSize) } ?? system
        return (font.ascender - font.capHeight, -font.descender)
    }()
    /// An app icon's side and a peripheral chip's height.
    private static let itemSize: CGFloat = 22
    private static let maxApps = 5

    let model: BatteryModel
    /// The item under the pointer; a test passes one in to show its bubble.
    @State private var hovered: Hovered?
    /// The ends of the lower row its scroll view cuts off, while the row is wider than the screen.
    @State private var cutEdges = CutEdges()

    init(model: BatteryModel, hovered: Hovered? = nil) {
        self.model = model
        _hovered = State(initialValue: hovered)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let status = model.status {
                HStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Image(systemName: status.glyph)
                            .font(.system(size: Self.glyphSize))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(status.state == .charging ? Color.green : Color.primary)
                            .padding(.leading, -Self.glyphLeadingRoom)
                            .frame(height: Self.glyphOutlineHeight)
                        Text(status.percentageText)
                            .font(.system(size: Self.percentageSize, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .padding(.top, -Self.percentageRoom.top)
                            .padding(.bottom, -Self.percentageRoom.bottom)
                    }
                    // Its own width: the symbol's negative padding must not cut the percentage short.
                    .fixedSize()
                    Spacer(minLength: 16)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(status.stateTitle)
                            .font(.headline)
                        if let remaining = status.remainingText {
                            Text(remaining)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                // A dimmed battery and the message at either end of what the screen is offered.
                HStack(spacing: 0) {
                    Image(systemName: "battery.0percent")
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 10)
                    Text("이 Mac에서 배터리를 찾지 못했어요.")
                        .foregroundStyle(.secondary)
                }
            }
            itemRow(model.detail)
        }
        // Over the rows, so a bubble never changes the screen's size.
        .overlayPreferenceValue(NameBubbleKey.self) { bubble in
            if let bubble {
                GeometryReader { proxy in
                    BubblePlacement(item: proxy[bubble.item]) { NameBubble(name: bubble.name, detail: bubble.detail) }
                }
                .allowsHitTesting(false)
            }
        }
        // Mounted only while the screen is shown, so sampling runs only then.
        .task { await model.sampleWhileShown() }
    }

    /// The apps' icons and, after a thin divider, the peripherals' chips, each group under its
    /// caption in one row; nothing when both lists are empty. Wider than the screen is offered, the row
    /// scrolls sideways as the home's icon strip does, without a scroll bar, and fades out at each end
    /// it cuts; every icon and chip keeps its own width, so each reading stays whole.
    @ViewBuilder
    private func itemRow(_ detail: BatteryDetail) -> some View {
        let apps = Array(detail.apps.prefix(Self.maxApps))
        let peripherals = detail.peripherals
        if !apps.isEmpty || !peripherals.isEmpty {
            let row = HStack(alignment: .top, spacing: 12) {
                if !apps.isEmpty {
                    group("전력을 많이 쓰는 앱") {
                        ForEach(apps, id: \.bundlePath) { app in
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundlePath))
                                .resizable()
                                .frame(width: Self.itemSize, height: Self.itemSize)
                                .named(app.name, as: .app(app.bundlePath), hovered: $hovered)
                        }
                    }
                }
                if !apps.isEmpty && !peripherals.isEmpty {
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: 1)
                }
                if !peripherals.isEmpty {
                    group("주변 기기") {
                        ForEach(peripherals) { device in
                            HStack(spacing: 4) {
                                Image(systemName: device.kind.symbol)
                                Text(device.compactLevelsText)
                                    .monospacedDigit()
                            }
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 6)
                            .frame(height: Self.itemSize)
                            .background(Capsule().fill(.white.opacity(0.08)))
                            .named(device.name, detail: device.levelsText, value: device.levelsText,
                                   as: .peripheral(device.id), hovered: $hovered)
                        }
                    }
                }
            }
            // Its own width, and the divider runs the height of the groups beside it.
            .fixedSize()
            RowViewport {
                ScrollView(.horizontal) {
                    row.onGeometryChange(for: CutEdges.self) { proxy in
                        CutEdges(visible: proxy.bounds(of: .scrollView) ?? .zero, content: proxy.size)
                    } action: { cutEdges = $0 }
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .mask { EdgeFade(edges: cutEdges) }
            }
        }
    }

    private func group(_ caption: String, @ViewBuilder items: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 6) {
                items()
            }
        }
    }
}

private extension View {
    /// Gives VoiceOver the item's name (and `value`), and shows the name (and `detail` after it) in a
    /// bubble over the item while the pointer is on it.
    func named(_ name: String, detail: String? = nil, value: String = "", as item: BatteryView.Hovered,
               hovered: Binding<BatteryView.Hovered?>) -> some View {
        let shows = hovered.wrappedValue == item
        return contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    hovered.wrappedValue = item
                } else if hovered.wrappedValue == item {
                    hovered.wrappedValue = nil
                }
            }
            // A list update can take the item away under the pointer, which then reports no exit.
            .onDisappear { if hovered.wrappedValue == item { hovered.wrappedValue = nil } }
            .anchorPreference(key: NameBubbleKey.self, value: .bounds) { bounds in
                shows ? NameBubbleKey.Bubble(name: name, detail: detail, item: bounds) : nil
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name)
            .accessibilityValue(value)
    }
}

/// The lower row's item whose name shows.
private struct NameBubbleKey: PreferenceKey {
    struct Bubble {
        let name: String
        let detail: String?
        let item: Anchor<CGRect>
    }

    static var defaultValue: Bubble? { nil }

    static func reduce(value: inout Bubble?, nextValue: () -> Bubble?) {
        if value == nil { value = nextValue() }
    }
}

/// An item's name on a small light capsule, on one line, as the home's icon strip shows a plugin's
/// name, with a peripheral's readings after it, each with its part. A name too wide for the screen ends
/// in an ellipsis and the readings stay whole (VoiceOver keeps all of it).
struct NameBubble: View {
    let name: String
    var detail: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .lineLimit(1)
                .truncationMode(.tail)
            if let detail {
                Text(detail)
                    .fontWeight(.regular)
                    .monospacedDigit()
                    .foregroundStyle(.black.opacity(0.7))
                    .fixedSize()
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.black)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(.white.opacity(0.92)))
    }
}

/// Places its one subview, the bubble, just above `item`: centred on it, but no wider than the
/// screen and kept within its bounds.
private struct BubblePlacement: Layout {
    let item: CGRect

    static let gap: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let bubble = subviews.first else { return }
        let size = bubble.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        let x = max(min(item.midX - size.width / 2, bounds.width - size.width), 0)
        let y = max(item.minY - Self.gap - size.height, 0)
        bubble.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
    }
}

/// Which ends of the lower row lie outside its scroll view.
private struct CutEdges: Equatable {
    var leading = false
    var trailing = false

    init() {}

    /// From the scroll view's bounds in the row's own space and the row's size.
    init(visible: CGRect, content: CGSize) {
        leading = visible.minX > 0.5
        trailing = visible.maxX < content.width - 0.5
    }
}

/// Lays out the lower row's scroll view at the row's own size, or only as wide as the screen is offered
/// when that is narrower, so the row scrolls; either way as tall as the row.
private struct RowViewport: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let scrollView = subviews.first else { return .zero }
        let row = scrollView.sizeThatFits(.unspecified)
        return CGSize(width: min(row.width, proposal.width ?? row.width), height: row.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// The lower row's mask while it scrolls: opaque, fading out over the last points at each cut end.
private struct EdgeFade: View {
    let edges: CutEdges

    static let width: CGFloat = 20

    var body: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [edges.leading ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: Self.width)
            Color.black
            LinearGradient(colors: [.black, edges.trailing ? .clear : .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: Self.width)
        }
    }
}
