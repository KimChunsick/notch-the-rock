import AppKit
import NotchKit
import SwiftUI

/// Everything drawn in the notch window. The black shape hangs from the top edge of the canvas,
/// which is the top edge of the screen; the rest of the canvas stays transparent.
///
/// Every presentation but the collapsed notch is measured at its own size and the shape grows to it
/// with the same padding on every side (`NotchSizing`); a change of size springs like opening does,
/// also between the home and a plugin's screen.
struct NotchRootView: View {
    let host: NotchHostModel
    let notchSize: CGSize
    let openSettings: @MainActor () -> Void
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
    @Environment(\.displayScale) private var displayScale

    /// Opening is a little lively; closing settles without overshoot.
    private static let openSpring = Animation.spring(response: 0.42, dampingFraction: 0.74)
    private static let closeSpring = Animation.spring(response: 0.34, dampingFraction: 0.92)

    var body: some View {
        let state = host.state
        let showsHomeBand = state == .expanded && host.screen == .home
        let metrics = NotchLayout.metrics(
            for: state,
            notch: notchSize,
            activityWing: host.liveActivity == nil ? 0 : activityWing,
            content: contentSize,
            minWidth: showsHomeBand ? BandLayout.minimumWidth(notch: notchSize, leading: HomeChrome.editWidth, trailing: HomeChrome.gearWidth) : 0
        )
        let glow = state == .attention ? host.attention?.request.accent : nil
        NotchSurface(metrics: metrics, glow: glow) {
            content(for: state)
        } band: {
            if showsHomeBand {
                HomeBand(home: host.home, notchSize: notchSize, width: metrics.size.width, openSettings: openSettings)
                    .transition(Self.contentTransition)
            }
        }
        .contentShape(metrics.shape)
        .contextMenu {
            Button("설정…") { openSettings() }
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

    @ViewBuilder
    private func content(for state: NotchState) -> some View {
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
                measured(HUDContent(hud: shown.hud, notchSize: notchSize))
                    .transition(Self.contentTransition)
            }
        case .expanded:
            if case .detail(let pluginID) = host.screen, let plugin = host.home.plugin(pluginID), let tab = plugin.tab {
                measured(PluginScreenView(host: host, plugin: plugin, tab: tab))
                    .id(pluginID)
                    .transition(Self.contentTransition)
            } else {
                measured(HomeView(host: host))
                    .transition(Self.contentTransition)
            }
        case .attention:
            if let pending = host.attention {
                measured(AttentionContent(pending: pending) { response in
                    host.respond(response, to: pending.id)
                })
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

    /// `content` at its own size, which becomes the size the shape grows to.
    private func measured<Content: View>(_ content: Content) -> some View {
        IntrinsicSizeLayout(maxSize: NotchSizing.maxContentSize) { content }
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
        return CGSize(width: notch.width + 2 * min(wing, NotchLayout.maxActivityWing), height: notch.height)
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
        else { return fit(Self.placedSize(ideal: ideal, margins: EdgeInsets(), notchHeight: notch.height), margins: EdgeInsets(), at: index) }
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
    /// around its ink: no taller than the notch and no wider than the widest wing leaves room for.
    /// The blank sides may hang past the wing's edges, so the box can be wider than the wing.
    static func placedSize(ideal: CGSize, margins: EdgeInsets, notchHeight: CGFloat) -> CGSize {
        let height = min(ideal.height, notchHeight)
        let inset = NotchLayout.activityInset(contentHeight: height, notchHeight: notchHeight) + margins.bottom
        let room = NotchLayout.maxActivityWing - 2 * inset + margins.leading + margins.trailing
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

/// The HUD beside the camera: symbol and title in the left wing, level bar and detail in the right.
/// Both wings are as wide as the wider one's content, so the shape stays centered on the notch.
private struct HUDContent: View {
    let hud: HUD
    let notchSize: CGSize

    var body: some View {
        WingPair(gap: notchSize.width + 2 * BandLayout.cameraClearance) {
            HStack(spacing: 6) {
                Image(systemName: hud.symbol)
                Text(hud.title).lineLimit(1)
            }
            HStack(spacing: 6) {
                if let value = hud.value {
                    Capsule()
                        .fill(.white.opacity(0.25))
                        .overlay(alignment: .leading) {
                            GeometryReader { proxy in
                                Capsule().fill(.white).frame(width: proxy.size.width * value)
                            }
                        }
                        .frame(width: 52, height: 5)
                }
                if let detail = hud.detail {
                    Text(detail).monospacedDigit().lineLimit(1)
                }
            }
        }
        .foregroundStyle(.white)
        .font(.system(size: 12, weight: .medium))
        .accessibilityElement(children: .combine)
    }
}

/// Two subviews either side of a gap, each in a wing as wide as the wider one: the first at the
/// left edge, the second at the right edge. Offered less width, the wings shrink to fit.
private struct WingPair: Layout {
    var gap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let wing = wingWidth(proposal: proposal, subviews: subviews)
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: wing, height: nil)).height }.max() ?? 0
        return CGSize(width: 2 * wing + gap, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let wing = wingWidth(proposal: ProposedViewSize(bounds.size), subviews: subviews)
        let offer = ProposedViewSize(width: wing, height: bounds.height)
        subviews.first?.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: offer)
        subviews.dropFirst().first?.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: offer)
    }

    private func wingWidth(proposal: ProposedViewSize, subviews: Subviews) -> CGFloat {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        guard let width = proposal.width else { return ideal }
        return max(0, min(ideal, (width - gap) / 2))
    }
}

/// Title, message, choices, text field and buttons of the first waiting request.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                request.sourceIcon?
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                if let deadline = pending.deadline {
                    Countdown(deadline: deadline, accent: request.accent)
                }
                Spacer(minLength: 16)
                Button {
                    respond(.dismissed)
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("닫기")
            }

            // A plain stack in the usual case; long requests scroll instead of being cut off.
            ViewThatFits(in: .vertical) {
                details
                ScrollView { details }
                    .scrollIndicators(.never)
            }
            Spacer(minLength: 0)

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
            Text(request.title)
                .font(.system(size: 14, weight: .semibold))
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

/// Seconds left before the request times out.
private struct Countdown: View {
    let deadline: ContinuousClock.Instant
    let accent: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let left = max(0, Int(((deadline - .now) / .seconds(1)).rounded(.up)))
            Label("\(left)초", systemImage: "timer")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(accent)
        }
    }
}
