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
        let glow = state == .attention ? host.attention?.request.accent : nil
        NotchSurface(metrics: metrics, glow: glow) {
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
                measured(AttentionContent(pending: pending) { response in
                    host.respond(response, to: pending.id)
                }, minWidth: screenWidth)
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
    var glow: Color?
    @ViewBuilder let content: Content
    @ViewBuilder let band: Band

    var body: some View {
        ZStack(alignment: .top) {
            metrics.shape
                .fill(Color.black)
                .background(AttentionGlow(color: glow, shape: metrics.shape))
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

/// Pulsing accent glow behind the shape while an attention request is shown.
private struct AttentionGlow: View {
    let color: Color?
    let shape: NotchShape
    @State private var bright = false

    var body: some View {
        if let color {
            shape
                .fill(color)
                .shadow(color: color.opacity(bright ? 0.95 : 0.5), radius: bright ? 16 : 9)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { bright = true }
                }
        }
    }
}

/// The live activity's two views beside the camera. What each draws sits as far from the shape's
/// side edge as from its bottom, and at least as far from the camera; both wings are as wide as the
/// wider one needs, so the shape stays centred on the camera. Each view's layout box is centred
/// vertically, as before; its ink (`ActivityInk`) moves the inset by the blank space the box keeps
/// beside and below what it draws: a text's side bearings and the room under its baseline. A view
/// squeezed below its own size keeps the size its ink was measured at, so the blank space counted
/// is what it keeps there. Its size is always its own, the camera and both wings without the
/// shoulders, whatever it is offered: the root measures it for the shape's width.
private struct ActivityWings: Layout {
    let notch: CGSize
    /// The leading and trailing views' ink, as measured at the size each is placed at; nil or
    /// missing counts the whole box as drawn.
    var ink: [ActivityInk?] = []
    /// The widest a wing gets, its view and insets included.
    var maxWing: CGFloat = NotchLayout.maxActivityWing

    /// Where a view goes in its wing: its size, the visible inset beside and below it, and the
    /// blank space its box keeps on the outer side and toward the camera.
    struct Fit {
        var size: CGSize
        var inset: CGFloat
        var outer: CGFloat
        var inner: CGFloat

        /// The wing this view needs: its ink with the inset on either side.
        var wing: CGFloat { size.width - outer - inner + 2 * inset }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let wing = subviews.prefix(2).indices.map { fit(subviews[$0], at: $0).wing }.max() ?? 0
        return CGSize(width: notch.width + 2 * min(wing, maxWing), height: notch.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for index in subviews.prefix(2).indices {
            let fit = fit(subviews[index], at: index)
            let x = index == 0 ? bounds.minX + fit.inset - fit.outer : bounds.maxX - fit.inset + fit.outer - fit.size.width
            let y = bounds.minY + NotchLayout.activityInset(contentHeight: fit.size.height, notchHeight: notch.height)
            subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(fit.size))
        }
    }

    /// A view's place and inset: at the size its ink was measured at, when that ink was measured
    /// from the view's own size as it is now; otherwise its box counts as drawn.
    private func fit(_ subview: LayoutSubview, at index: Int) -> Fit {
        let ideal = subview.sizeThatFits(.unspecified)
        guard index < ink.count, let measured = ink[index],
              abs(measured.ideal.width - ideal.width) <= 0.5, abs(measured.ideal.height - ideal.height) <= 0.5
        else { return fit(Self.placedSize(ideal: ideal, margins: EdgeInsets(), notchHeight: notch.height, maxWing: maxWing), margins: EdgeInsets(), at: index) }
        return fit(measured.size, margins: measured.margins, at: index)
    }

    /// A view placed at `size` whose box keeps `margins` blank around its ink.
    private func fit(_ size: CGSize, margins: EdgeInsets, at index: Int) -> Fit {
        Fit(
            size: size,
            inset: NotchLayout.activityInset(contentHeight: size.height, notchHeight: notch.height) + margins.bottom,
            outer: index == 0 ? margins.leading : margins.trailing,
            inner: index == 0 ? margins.trailing : margins.leading
        )
    }

    /// The size a view whose own size is `ideal` is placed at when its box keeps `margins` blank
    /// around its ink: no taller than the notch and no wider than the widest wing (`maxWing`) leaves
    /// room for. The blank sides may hang past the wing's edges, so the box can be wider than the wing.
    static func placedSize(ideal: CGSize, margins: EdgeInsets, notchHeight: CGFloat, maxWing: CGFloat = NotchLayout.maxActivityWing) -> CGSize {
        let height = min(ideal.height, notchHeight)
        let inset = NotchLayout.activityInset(contentHeight: height, notchHeight: notchHeight) + margins.bottom
        let room = maxWing - 2 * inset + margins.leading + margins.trailing
        return CGSize(width: min(ideal.width, room), height: height)
    }
}

/// The look the host gives a live activity's views, for drawing them and for measuring their ink.
private struct ActivityStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(.white)
            .font(.system(size: 12, weight: .medium))
            .environment(\.colorScheme, .dark)
    }
}

/// The blank space a live activity view's layout box keeps around what it draws, beside and
/// below: text and SF Symbols carry side bearings and the room under the baseline inside their
/// boxes, and a view's alignment guides do not tell them (a symbol's text baseline also reaches
/// the art it sits in). The view is drawn offscreen at the size its wing places it at, never at its
/// own when that is larger, and the margins are read off its pixels; any pixel at least 5 % opaque
/// counts, so a faint fill does too.
struct ActivityInk: Equatable {
    /// The view's own size, laid out without drawing it, that its placed size comes from.
    var ideal: CGSize
    /// The size it is placed at and was drawn at.
    var size: CGSize
    /// Leading, trailing and bottom blank space at `size`; the top is not used, so it stays 0.
    var margins: EdgeInsets

    /// The most pixels a view is drawn with, 256 KB of RGBA. A placed box is at most twice a wing's
    /// 78 pt by a notch's height, which stays below it even at 3x; it bounds a display scale out of
    /// the ordinary.
    static let pixelBudget: CGFloat = 65_536
    /// The sizes the last measuring drew its view at, so tests can tell none was its own size.
    @MainActor static private(set) var drawn: [CGSize] = []

    /// The view's ink at the size its wing places it at. Its blank space decides that size, so it is
    /// drawn first at the size its box alone leaves room for and, when the blank space found there
    /// moves the size, once more at the new size; that second measuring is the one kept, as the
    /// size it gives moves far less. Nil when the view draws nothing (an AppKit-backed view the
    /// renderer cannot see, say) or its box is beyond the pixel budget: the box counts as drawn.
    @MainActor static func measure(_ view: AnyView, scale: CGFloat, notchHeight: CGFloat) -> ActivityInk? {
        let styled = view.modifier(ActivityStyle())
        drawn = []
        // Lays the view out without drawing it, at the display's scale as the wing does (a symbol's
        // size snaps to its pixels): the closure is handed the size and never draws.
        let layout = ImageRenderer(content: styled)
        layout.scale = scale
        var ideal = CGSize.zero
        layout.render { laidOut, _ in ideal = laidOut }
        var size = ActivityWings.placedSize(ideal: ideal, margins: EdgeInsets(), notchHeight: notchHeight)
        guard var margins = blankSpace(of: styled, at: size, scale: scale) else { return nil }
        let placed = ActivityWings.placedSize(ideal: ideal, margins: margins, notchHeight: notchHeight)
        if abs(placed.width - size.width) > 0.5, let again = blankSpace(of: styled, at: placed, scale: scale) {
            (size, margins) = (placed, again)
        }
        return ActivityInk(ideal: ideal, size: size, margins: margins)
    }

    /// The blank space around what `view` draws when its wing places it at `size`: offered that
    /// size and put at its top-leading corner, so anything it draws past the box is cut off.
    @MainActor private static func blankSpace(of view: some View, at size: CGSize, scale: CGFloat) -> EdgeInsets? {
        guard size.width * size.height * scale * scale <= pixelBudget else { return nil }
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height, alignment: .topLeading))
        renderer.scale = scale
        drawn.append(size)
        guard let image = renderer.cgImage else { return nil }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] >= 13 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                maxY = y
            }
        }
        guard maxX >= 0 else { return nil }
        return EdgeInsets(
            top: 0,
            leading: CGFloat(minX) / scale,
            bottom: CGFloat(height - 1 - maxY) / scale,
            trailing: CGFloat(width - 1 - maxX) / scale
        )
    }
}

/// The HUD in the collapsed notch's wings, placed as a live activity's views are: the symbol in the
/// left wing, as far from the side edge as from the bottom, and for a HUD with a value a thin bar in
/// the right wing. Both wings are as wide as the bar's, so the shape keeps its width while the
/// symbol changes (a speaker's waves by level). The title and detail are not drawn; VoiceOver reads
/// them.
private struct HUDContent: View {
    let hud: HUD
    let notch: CGSize
    /// The symbol's ink, as measured at the size it is placed at.
    let ink: [ActivityInk?]

    var body: some View {
        ActivityWings(notch: notch, ink: ink, maxWing: NotchLayout.maxHUDWing) {
            HUDSymbol(name: hud.symbol)
            if let value = hud.value {
                HUDBar(value: value, colors: HUDBar.colors(for: hud.symbol))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hud.title)
        .accessibilityValue(hud.detail ?? "")
    }
}

/// The HUD's symbol, white. Its own font, so measuring its ink and placing it lay it out alike.
private struct HUDSymbol: View {
    let name: String

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
    }
}

/// A thin rounded bar on a dark translucent track, filled from the left in proportion to `value`
/// with a soft gradient from end to end of the fill. A new value springs from the last one, also
/// when a held key repeats.
private struct HUDBar: View {
    static let length: CGFloat = 80
    static let thickness: CGFloat = 6
    /// Brightness: warm beige to gold. The brightness screen's slider fills with the same gradient
    /// (`BrightnessSlider.colors` in Plugins/Brightness/Sources/Brightness/BrightnessView.swift).
    static let warm = [Color(red: 0.95, green: 0.87, blue: 0.72), Color(red: 0.97, green: 0.73, blue: 0.28)]
    /// Volume: pale ice blue to a calm blue. The volume screen's slider fills with the same gradient
    /// (`VolumeSlider.colors` in Plugins/Volume/Sources/Volume/VolumeView.swift).
    static let volume = [Color(red: 0.74, green: 0.87, blue: 1), Color(red: 0.36, green: 0.64, blue: 1)]
    /// Any other plugin's HUD: cool white to light grey.
    static let neutral = [Color(red: 0.98, green: 0.99, blue: 1), Color(red: 0.8, green: 0.82, blue: 0.86)]

    /// The fill of a HUD by its symbol's family, so a refused change's badged sun or speaker keeps
    /// the colour of its plugin.
    static func colors(for symbol: String) -> [Color] {
        if symbol.hasPrefix("sun.") { return warm }
        if symbol.hasPrefix("speaker.") { return volume }
        return neutral
    }

    let value: Double
    let colors: [Color]

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.18))
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: Self.length * value)
            }
            .frame(width: Self.length, height: Self.thickness)
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: value)
    }
}

/// Message, choices, text field and buttons of the first waiting request, under its band
/// (`AttentionBand`), which holds the icon, the title, the countdown and the close button.
/// At least `minWidth` wide, so text fields and buttons have room; long text wraps at the widest
/// the notch gets.
private struct AttentionContent: View {
    static let minWidth: CGFloat = 280

    let pending: NotchHostModel.PendingAttention
    let respond: (AttentionResponse) -> Void
    @State private var selections: [String: [String]] = [:]
    @State private var text: String

    init(pending: NotchHostModel.PendingAttention, respond: @escaping (AttentionResponse) -> Void) {
        self.pending = pending
        self.respond = respond
        _text = State(initialValue: pending.request.textField?.initialText ?? "")
    }

    private var request: AttentionRequest { pending.request }

    /// A lone single choice with nothing else to fill in is answered by picking an option.
    private var picksAnswerDirectly: Bool {
        request.buttons.isEmpty && request.textField == nil && request.choices.count == 1 && !request.choices[0].allowsMultiple
    }

    /// Whether anything shows above the buttons: a message, choices or a text field.
    private var hasDetails: Bool {
        !request.message.isEmpty || !request.choices.isEmpty || request.textField != nil
    }

    /// Spacing steps: 6 inside a choice group, 10 between the details, 14 above the buttons.
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if hasDetails {
                // A plain stack in the usual case; long requests scroll instead of being cut off.
                ViewThatFits(in: .vertical) {
                    details
                    ScrollView { details }
                        .scrollIndicators(.never)
                }
            }

            HStack(spacing: 8) {
                if let releaseTitle = request.releaseTitle {
                    Button(releaseTitle) { respond(.released) }
                        .buttonStyle(AttentionButtonStyle(fill: .white.opacity(0.12)))
                }
                Spacer(minLength: 0)
                ForEach(request.buttons, id: \.id) { button in
                    Button(button.title) { submit(buttonID: button.id) }
                        .buttonStyle(AttentionButtonStyle(fill: fill(for: button.role)))
                }
                if request.buttons.isEmpty && !picksAnswerDirectly {
                    Button("보내기") { submit(buttonID: nil) }
                        .buttonStyle(AttentionButtonStyle(fill: request.accent))
                }
            }
        }
        .foregroundStyle(.white)
        .frame(minWidth: Self.minWidth, alignment: .topLeading)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !request.message.isEmpty {
                Text(request.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.75))
            }
            ForEach(request.choices, id: \.id) { group in
                ChoiceGroup(group: group, accent: request.accent, selected: selections[group.id] ?? []) { option in
                    pick(option, in: group)
                }
            }
            if let field = request.textField {
                TextField(field.placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit(buttonID: nil) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fill(for role: AttentionButton.Role) -> Color {
        switch role {
        case .primary: request.accent
        case .destructive: .red
        case .normal, .cancel: .white.opacity(0.12)
        @unknown default: .white.opacity(0.12)
        }
    }

    private func pick(_ option: String, in group: AttentionChoices) {
        var chosen = selections[group.id] ?? []
        if group.allowsMultiple {
            if let index = chosen.firstIndex(of: option) { chosen.remove(at: index) } else { chosen.append(option) }
            chosen.sort { group.options.firstIndex(of: $0) ?? 0 < group.options.firstIndex(of: $1) ?? 0 }
        } else {
            chosen = [option]
        }
        selections[group.id] = chosen
        if picksAnswerDirectly { submit(buttonID: nil) }
    }

    private func submit(buttonID: String?) {
        let answer = AttentionAnswer(
            buttonID: buttonID,
            choices: selections.filter { !$0.value.isEmpty },
            text: request.textField == nil ? nil : text
        )
        respond(.answered(answer))
    }
}

private struct ChoiceGroup: View {
    let group: AttentionChoices
    let accent: Color
    let selected: [String]
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !group.prompt.isEmpty {
                Text(group.prompt).font(.system(size: 12, weight: .medium))
            }
            ForEach(group.options, id: \.self) { option in
                let isSelected = selected.contains(option)
                Button {
                    pick(option)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: symbol(selected: isSelected))
                            .foregroundStyle(isSelected ? accent : .white.opacity(0.6))
                        Text(option).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 12))
                    .padding(.vertical, 5)
                    .padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(isSelected ? 0.14 : 0.06)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func symbol(selected: Bool) -> String {
        if group.allowsMultiple { return selected ? "checkmark.square.fill" : "square" }
        return selected ? "largecircle.fill.circle" : "circle"
    }
}

private struct AttentionButtonStyle: ButtonStyle {
    let fill: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(Capsule().fill(fill.opacity(configuration.isPressed ? 0.7 : 1)))
            .foregroundStyle(.white)
    }
}

/// An attention's controls in the top band, split around the camera like a plugin screen's
/// (`PluginBand`): the source icon and the title in the left wing, the countdown and the close
/// button in the right. The shape grows until the left wing holds the whole title, up to its
/// widest; a longer title is cut short, never under the camera's clearance. The right wing keeps
/// room for the most seconds the request can show, so the shape does not move as they count down.
struct AttentionBand: View {
    static let iconSize: CGFloat = 20

    let pending: NotchHostModel.PendingAttention
    let notchSize: CGSize
    let width: CGFloat
    let dismiss: () -> Void

    /// The narrowest attention shape that shows the whole title and the countdown beside the camera.
    static func minimumWidth(notch: CGSize, request: AttentionRequest) -> CGFloat {
        BandLayout.minimumWidth(notch: notch, leading: leadingWidth(request), trailing: trailingWidth(request))
    }

    /// The icon and the whole title on one line.
    private static func leadingWidth(_ request: AttentionRequest) -> CGFloat {
        NSHostingView(rootView: Lead(icon: request.sourceIcon, title: request.title)).fittingSize.width.rounded(.up)
    }

    /// The countdown at the most seconds the request can show, and the close button.
    private static func trailingWidth(_ request: AttentionRequest) -> CGFloat {
        guard let timeout = request.timeout else { return closeSize }
        let label = CountdownLabel(seconds: Int((timeout / .seconds(1)).rounded(.up)), accent: request.accent)
        return NSHostingView(rootView: label).fittingSize.width.rounded(.up) + trailingSpacing + closeSize
    }

    private static let closeSize: CGFloat = 22
    private static let trailingSpacing: CGFloat = 10

    var body: some View {
        let request = pending.request
        let leading = min(Self.leadingWidth(request), BandLayout.wingRoom(notch: notchSize, width: width))
        let layout = BandLayout(notch: notchSize, width: width, leading: leading, trailing: Self.trailingWidth(request))
        ZStack(alignment: .topLeading) {
            Lead(icon: request.sourceIcon, title: request.title)
                .frame(width: layout.leadingFrame.width, height: layout.leadingFrame.height, alignment: .leading)
                .position(x: layout.leadingFrame.midX, y: layout.leadingFrame.midY)
            HStack(spacing: Self.trailingSpacing) {
                if let deadline = pending.deadline {
                    Countdown(deadline: deadline, accent: request.accent)
                }
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: Self.closeSize, height: Self.closeSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("닫기")
            }
            .frame(width: layout.trailingFrame.width, height: layout.trailingFrame.height, alignment: .trailing)
            .position(x: layout.trailingFrame.midX, y: layout.trailingFrame.midY)
        }
        .foregroundStyle(.white)
        .frame(width: width, height: notchSize.height, alignment: .topLeading)
    }

    /// The source icon, at its own aspect ratio and rendering, and the title on one line that is
    /// cut short at the end when it has to be.
    private struct Lead: View {
        let icon: Image?
        let title: String

        var body: some View {
            HStack(spacing: 6) {
                icon?
                    .resizable()
                    .scaledToFit()
                    .frame(width: AttentionBand.iconSize, height: AttentionBand.iconSize)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

/// Seconds left before the request times out.
private struct Countdown: View {
    let deadline: ContinuousClock.Instant
    let accent: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            CountdownLabel(seconds: max(0, Int(((deadline - .now) / .seconds(1)).rounded(.up))), accent: accent)
        }
    }
}

private struct CountdownLabel: View {
    let seconds: Int
    let accent: Color

    var body: some View {
        Label("\(seconds)초", systemImage: "timer")
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(accent)
    }
}
