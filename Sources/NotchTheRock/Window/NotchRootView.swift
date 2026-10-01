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
    /// Told the shape's metrics whenever they change, so pointer tracking follows the drawn shape.
    var metricsChanged: @MainActor (NotchLayout.Metrics) -> Void = { _ in }

    /// The measured size of what the current state shows.
    @State private var contentSize: CGSize = .zero

    /// Opening is a little lively; closing settles without overshoot.
    private static let openSpring = Animation.spring(response: 0.42, dampingFraction: 0.74)
    private static let closeSpring = Animation.spring(response: 0.34, dampingFraction: 0.92)

    var body: some View {
        let state = host.state
        let showsHomeBand = state == .expanded && host.screen == .home
        let metrics = NotchLayout.metrics(
            for: state,
            notch: notchSize,
            hasActivity: host.liveActivity != nil,
            content: contentSize,
            minWidth: showsHomeBand ? BandLayout.minimumWidth(notch: notchSize, leading: HomeChrome.editWidth, trailing: HomeChrome.gearWidth) : 0
        )
        let glow = state == .attention ? host.attention?.request.accent : nil
        ZStack(alignment: .top) {
            metrics.shape
                .fill(Color.black)
                .background(AttentionGlow(color: glow, shape: metrics.shape))
            ZStack(alignment: .topLeading) {
                content(for: state)
                    .offset(x: metrics.content.minX, y: metrics.content.minY)
                if showsHomeBand {
                    HomeBand(home: host.home, notchSize: notchSize, width: metrics.size.width, openSettings: openSettings)
                        .transition(Self.contentTransition)
                }
            }
            .frame(width: metrics.size.width, height: metrics.size.height, alignment: .topLeading)
            .clipShape(metrics.shape)
        }
        .frame(width: metrics.size.width, height: metrics.size.height)
        .contentShape(metrics.shape)
        .contextMenu {
            Button("설정…") { openSettings() }
            Button("종료") { NSApplication.shared.terminate(nil) }
        }
        .frame(width: NotchLayout.canvasSize.width, height: NotchLayout.canvasSize.height, alignment: .top)
        .ignoresSafeArea()
        .animation(state == .collapsed ? Self.closeSpring : Self.openSpring, value: metrics)
        .animation(Self.openSpring, value: state)
        .environment(\.colorScheme, .dark)
        .onChange(of: metrics, initial: true) { _, metrics in metricsChanged(metrics) }
    }

    @ViewBuilder
    private func content(for state: NotchState) -> some View {
        switch state {
        case .collapsed:
            if let posted = host.liveActivity {
                Wings(notchSize: notchSize, wingWidth: NotchLayout.activityWingWidth) {
                    posted.activity.leading
                } trailing: {
                    posted.activity.trailing
                }
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

/// Views on both sides of the collapsed notch, keeping the camera area in the middle free.
private struct Wings<Leading: View, Trailing: View>: View {
    let notchSize: CGSize
    let wingWidth: CGFloat
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 0) {
            leading
                .frame(width: wingWidth, height: notchSize.height)
            Spacer(minLength: notchSize.width)
            trailing
                .frame(width: wingWidth, height: notchSize.height)
        }
        .padding(.horizontal, NotchLayout.collapsedShoulder)
        .foregroundStyle(.white)
        .font(.system(size: 12, weight: .medium))
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
