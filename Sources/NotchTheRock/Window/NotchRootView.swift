import AppKit
import NotchKit
import SwiftUI

/// Everything drawn in the notch window. The black shape hangs from the top edge of the canvas,
/// which is the top edge of the screen; the rest of the canvas stays transparent.
///
/// Every presentation but the collapsed notch and the HUD is measured at its own size and the shape
/// grows to it with the same padding on every side (`NotchSizing`); a change of size springs like
/// opening does, also between the home and a plugin's screen. A plugin's screen or an attention
/// narrower than its band is offered the width between the shape's paddings, never more, so the
/// shape keeps the band's width whatever the content measures. The HUD widens the collapsed notch
/// sideways by wings measured like a live activity's.
struct NotchRootView: View {
    let host: NotchHostModel
    let notchSize: CGSize
    /// Opens the Settings window: on the plugin's page for a plugin's id, as it was for nil.
    let openSettings: @MainActor (_ pluginID: String?) -> Void
    /// Told the metrics the shape is heading to whenever they change, so pointer tracking follows it.
    var metricsChanged: @MainActor (NotchLayout.Metrics) -> Void = { _ in }
    /// Told the shape as drawn, every frame while it springs toward new metrics.
    var shapeDrawn: @MainActor (NotchLayout.Metrics) -> Void = { _ in }
    /// Told when a tile drag in the home starts (`true`) and ends, dropped or cancelled (`false`).
    var dragChanged: @MainActor (Bool) -> Void = { _ in }

    /// The measured size of what the current state shows.
    @State private var contentSize: CGSize = .zero
    /// Each wing's width for the live activity, as `ActivityWings` measures its views.
    @State private var activityWing: CGFloat = 0
    /// What the live activity's leading and trailing views draw inside their layout boxes, measured
    /// once per post.
    @State private var activityInk: [ActivityInk?] = []
    /// Each wing's width for the HUD, and its symbol's ink, measured as the live activity's are.
    @State private var hudWing: CGFloat = 0
    @State private var hudInk: [ActivityInk?] = []
    @Environment(\.displayScale) private var displayScale

    /// Opening is a little lively; closing settles without overshoot.
    private static let openSpring = Animation.spring(response: 0.42, dampingFraction: 0.74)
    private static let closeSpring = Animation.spring(response: 0.34, dampingFraction: 0.92)

    var body: some View {
        let state = host.state
        let detail = state == .expanded ? shownPlugin : nil
        let attention = state == .attention ? host.attention : nil
        let bandWidth: CGFloat = if let attention {
            AttentionBand.minimumWidth(notch: notchSize, request: attention.request)
        } else if state != .expanded {
            0
        } else if let detail {
            PluginBand.minimumWidth(notch: notchSize, plugin: detail)
        } else {
            BandLayout.minimumWidth(notch: notchSize, leading: HomeChrome.editWidth, trailing: HomeChrome.gearWidth)
        }
        let metrics = NotchLayout.metrics(
            for: state,
            notch: notchSize,
            activityWing: state == .hud ? hudWing : host.liveActivity == nil ? 0 : activityWing,
            content: contentSize,
            minWidth: bandWidth
        )
        NotchSurface(metrics: metrics) {
            content(for: state, screenWidth: detail == nil && attention == nil ? 0 : NotchSizing.contentWidth(filling: bandWidth))
        } band: {
            if state == .expanded {
                if let detail {
                    PluginBand(host: host, plugin: detail, notchSize: notchSize, width: metrics.size.width, openSettings: openSettings)
                        .id(detail.pluginID)
                        .transition(Self.contentTransition)
                } else {
                    HomeBand(home: host.home, notchSize: notchSize, width: metrics.size.width, openSettings: openSettings)
                        .transition(Self.contentTransition)
                }
            } else if let attention {
                AttentionBand(pending: attention, notchSize: notchSize, width: metrics.size.width) {
                    host.respond(.dismissed, to: attention.id)
                }
                .id(attention.id)
                .transition(Self.contentTransition)
            }
        }
        .contentShape(metrics.shape)
        .contextMenu {
            Button("설정…") { openSettings(nil) }
            Button("종료") { NSApplication.shared.terminate(nil) }
        }
        .frame(width: NotchLayout.canvasSize.width, height: NotchLayout.canvasSize.height, alignment: .top)
        .ignoresSafeArea()
        .modifier(DrawnShapeReporter(metrics: metrics, report: shapeDrawn))
        .animation(state == .collapsed ? Self.closeSpring : Self.openSpring, value: metrics)
        .animation(Self.openSpring, value: state)
        .environment(\.colorScheme, .dark)
        .onChange(of: metrics, initial: true) { _, metrics in metricsChanged(metrics) }
        .onChange(of: host.home.draggedTile != nil) { _, dragging in dragChanged(dragging) }
    }

    /// - Parameter screenWidth: the width a plugin's screen or an attention is offered when it is
    ///   narrower, from the band's width and never from the measured content, so measuring cannot
    ///   widen the shape.
    @ViewBuilder
    private func content(for state: NotchState, screenWidth: CGFloat) -> some View {
        switch state {
        case .collapsed:
            if let posted = host.liveActivity {
                ActivityWings(notch: notchSize, ink: activityInk) {
                    posted.activity.leading
                    posted.activity.trailing
                }
                .modifier(ActivityStyle())
                .onGeometryChange(for: CGFloat.self) { ($0.size.width - notchSize.width) / 2 } action: { activityWing = $0 }
                // Each post (Battery's next percentage, say) is drawn once offscreen to find its ink.
                .onChange(of: posted.order, initial: true) {
                    activityInk = [posted.activity.leading, posted.activity.trailing].map { ActivityInk.measure($0, scale: displayScale, notchHeight: notchSize.height) }
                }
                // Centred on the camera while the shape springs to the measured wings around it.
                .frame(maxWidth: .infinity)
                .id("activity \(posted.pluginID) \(posted.activity.id)")
                .transition(Self.contentTransition)
            }
        case .hud:
            if let shown = host.hud {
                // One view for every HUD shown in a row, so the bar springs from one value to the next.
                HUDContent(hud: shown.hud, notch: notchSize, ink: hudInk)
                    .onGeometryChange(for: CGFloat.self) { ($0.size.width - notchSize.width) / 2 } action: { hudWing = $0 }
                    .onChange(of: shown.hud.symbol, initial: true) {
                        hudInk = [ActivityInk.measure(AnyView(HUDSymbol(name: shown.hud.symbol)), scale: displayScale, notchHeight: notchSize.height)]
                    }
                    .frame(maxWidth: .infinity)
                    .transition(Self.contentTransition)
            }
        case .expanded:
            if let plugin = shownPlugin {
                measured(plugin.tab?.content ?? AnyView(DefaultScreen(plugin: plugin, openSettings: openSettings)), minWidth: screenWidth)
                    .id(plugin.pluginID)
                    .transition(Self.contentTransition)
            } else {
                measured(HomeView(host: host))
                    .transition(Self.contentTransition)
            }
        case .attention:
            if let pending = host.attention {
                let showsTitle = !AttentionBand.titleFits(notch: notchSize, request: pending.request)
                measured(AttentionContent(host: host, pending: pending, showsTitle: showsTitle), minWidth: screenWidth)
                .id(pending.id)
                .transition(Self.contentTransition)
            }
        case .takeover:
            if let shown = host.takeover {
                measured(shown.takeover.content)
                    .transition(Self.contentTransition)
            }
        }
    }

    /// The plugin whose screen the expanded notch shows; nil on the home.
    private var shownPlugin: HomePlugin? {
        guard case .detail(let pluginID) = host.screen else { return nil }
        return host.home.plugin(pluginID)
    }

    /// `content` at its own size, or `minWidth` wide when it fills that, which becomes the size the
    /// shape grows to.
    private func measured<Content: View>(_ content: Content, minWidth: CGFloat = 0) -> some View {
        IntrinsicSizeLayout(maxSize: NotchSizing.maxContentSize, minWidth: minWidth) { content }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { contentSize = $0 }
    }

    /// Content fades in once the shape has mostly opened and leaves quickly when it closes.
    private static let contentTransition = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top)).animation(.easeOut(duration: 0.22).delay(0.1)),
        removal: .opacity.animation(.easeIn(duration: 0.1))
    )
}

/// The black shape at `metrics`, the measured content at its place in it and the band's controls
/// over the notch, all clipped to the shape. The host's padding comes from `metrics.content`; the
/// content adds none of its own.
struct NotchSurface<Content: View, Band: View>: View {
    let metrics: NotchLayout.Metrics
    @ViewBuilder let content: Content
    @ViewBuilder let band: Band

    var body: some View {
        ZStack(alignment: .top) {
            metrics.shape
                .fill(Color.black)
            ZStack(alignment: .topLeading) {
                content
                    .offset(x: metrics.content.minX, y: metrics.content.minY)
                band
            }
            .frame(width: metrics.size.width, height: metrics.size.height, alignment: .topLeading)
            .clipShape(metrics.shape)
        }
        .frame(width: metrics.size.width, height: metrics.size.height)
    }
}

/// Reports the shape's metrics as drawn: animated with the shape, so every frame of a spring is
/// reported, and the window takes clicks where the shape is now, not only where it is heading.
private struct DrawnShapeReporter: ViewModifier, Animatable {
    var metrics: NotchLayout.Metrics
    let report: @MainActor (NotchLayout.Metrics) -> Void

    nonisolated var animatableData: AnimatablePair<CGSize.AnimatableData, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(metrics.size.animatableData, AnimatablePair(metrics.shoulderRadius, metrics.bottomRadius)) }
        set {
            metrics.size.animatableData = newValue.first
            metrics.shoulderRadius = newValue.second.first
            metrics.bottomRadius = newValue.second.second
        }
    }

    func body(content: Content) -> some View {
        content.onChange(of: metrics, initial: true) { _, drawn in report(drawn) }
    }
}
