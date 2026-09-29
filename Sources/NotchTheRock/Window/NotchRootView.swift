import AppKit
import NotchKit
import SwiftUI

/// Everything drawn in the notch window. The black shape hangs from the top edge of the canvas,
/// which is the top edge of the screen; the rest of the canvas stays transparent.
struct NotchRootView: View {
    let host: NotchHostModel
    let notchSize: CGSize
    let openSettings: @MainActor () -> Void

    /// Opening is a little lively; closing settles without overshoot.
    private static let openSpring = Animation.spring(response: 0.42, dampingFraction: 0.74)
    private static let closeSpring = Animation.spring(response: 0.34, dampingFraction: 0.92)

    var body: some View {
        let state = host.state
        let metrics = NotchLayout.metrics(for: state, notch: notchSize, hasActivity: host.liveActivity != nil)
        let glow = state == .attention ? host.attention?.request.accent : nil
        ZStack(alignment: .top) {
            metrics.shape
                .fill(Color.black)
                .background(AttentionGlow(color: glow, shape: metrics.shape))
            content(for: state)
                .frame(width: metrics.size.width, height: metrics.size.height, alignment: .top)
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
                HUDWings(hud: shown.hud, notchSize: notchSize)
                    .transition(Self.contentTransition)
            }
        case .expanded:
            ExpandedContent(host: host, notchSize: notchSize, openSettings: openSettings)
                .transition(Self.contentTransition)
        case .attention:
            if let pending = host.attention {
                AttentionContent(pending: pending, notchSize: notchSize) { response in
                    host.respond(response, to: pending.id)
                }
                .id(pending.id)
                .transition(Self.contentTransition)
            }
        case .takeover:
            if let shown = host.takeover {
                shown.takeover.content
                    .padding(.top, notchSize.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(Self.contentTransition)
            }
        }
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

/// Views on both sides of the notch, keeping the camera area in the middle free.
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

private struct HUDWings: View {
    let hud: HUD
    let notchSize: CGSize

    var body: some View {
        Wings(notchSize: notchSize, wingWidth: NotchLayout.hudWingWidth) {
            HStack(spacing: 6) {
                Image(systemName: hud.symbol)
                Text(hud.title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 12)
        } trailing: {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
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
            .padding(.trailing, 12)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Tab icons left of the camera, the gear right of it, the selected plugin's view below.
private struct ExpandedContent: View {
    let host: NotchHostModel
    let notchSize: CGSize
    let openSettings: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(host.tabs) { tab in
                    Button {
                        host.selectTab(tab.pluginID)
                    } label: {
                        Image(systemName: tab.tab.symbol)
                            .frame(width: 26, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(.white.opacity(tab.id == host.selectedTabID ? 0.18 : 0))
                            )
                    }
                    .help(tab.tab.title)
                }
                Spacer(minLength: notchSize.width + 16)
                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                        .frame(width: 26, height: 22)
                }
                .help("설정")
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, NotchLayout.openShoulder + 14)
            .frame(height: notchSize.height)

            Group {
                if let selected = host.tabs.first(where: { $0.id == host.selectedTabID }) {
                    selected.tab.content
                } else {
                    Text("아직 켠 플러그인이 없어요")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, NotchLayout.openShoulder + 16)
            .padding(.bottom, 16)
        }
    }
}

/// Title, message, choices, text field and buttons of the first waiting request.
private struct AttentionContent: View {
    let pending: NotchHostModel.PendingAttention
    let notchSize: CGSize
    let respond: (AttentionResponse) -> Void
    @State private var selections: [String: [String]] = [:]
    @State private var text: String

    init(pending: NotchHostModel.PendingAttention, notchSize: CGSize, respond: @escaping (AttentionResponse) -> Void) {
        self.pending = pending
        self.notchSize = notchSize
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
                Spacer(minLength: notchSize.width + 16)
                Button {
                    respond(.dismissed)
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("닫기")
            }
            .frame(height: notchSize.height)

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
        .padding(.horizontal, NotchLayout.openShoulder + 16)
        .padding(.bottom, 16)
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
