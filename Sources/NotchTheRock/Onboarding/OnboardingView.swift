import AppKit
import NotchKit
import SwiftUI

/// The onboarding panel: a glowing mark, a large title with one short line, the step's content, and
/// a footer with the step dots and the key-hinted buttons. Enter and Esc both call `advance()`; the
/// pages slide sideways between steps.
struct OnboardingView: View {
    let model: OnboardingModel

    private static let stepChange = Animation.spring(response: 0.5, dampingFraction: 0.86)

    var body: some View {
        VStack(spacing: 0) {
            OnboardingMark()
                .frame(height: 112)
                .padding(.top, 12)
            ZStack(alignment: .top) {
                OnboardingPage(model: model, step: model.step)
                    .id(model.step)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 16)
            footer
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 22)
        .frame(width: OnboardingWindowController.size.width, height: OnboardingWindowController.size.height)
        .background {
            ZStack {
                // Keeps the translucent background dark over a light desktop as well.
                Color.black.opacity(0.4)
                RadialGradient(
                    colors: [OnboardingPalette.colors[1].opacity(0.2), .clear],
                    center: .top,
                    startRadius: 0,
                    endRadius: 340
                )
                WindowDragArea()
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: OnboardingWindowController.cornerRadius)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .animation(Self.stepChange, value: model.step)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            StepDots(current: model.steps.firstIndex(of: model.step) ?? 0, count: model.steps.count)
            Spacer()
            if showsLater {
                Button { model.advance() } label: { KeyHintLabel(title: "나중에", key: "esc", onLight: false) }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
            } else {
                // Esc does what 나중에 does on every step; only the steps with cards show the button.
                Button("나중에") { model.advance() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            Button { model.advance() } label: {
                KeyHintLabel(title: model.isLastStep ? "시작하기" : "계속", key: "↵", onLight: true)
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .frame(height: 36)
    }

    private var showsLater: Bool {
        switch model.step {
        case .permissions, .setup: true
        case .welcome, .usage, .done: false
        }
    }
}

/// The Hello greeting's ink (Plugins/Hello), copied: blue, lavender, rose, peach.
private enum OnboardingPalette {
    static let colors: [Color] = [
        Color(red: 0.47, green: 0.82, blue: 1.00),
        Color(red: 0.64, green: 0.62, blue: 1.00),
        Color(red: 0.98, green: 0.56, blue: 0.82),
        Color(red: 1.00, green: 0.77, blue: 0.52),
    ]
    static let ink = LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    static let on = Color(red: 0.36, green: 0.84, blue: 0.54)
    static let attention = Color(red: 1.00, green: 0.72, blue: 0.36)
    static let failure = Color(red: 1.00, green: 0.56, blue: 0.52)
}

/// Title, one line and the step's content. The step is fixed per page, so the page sliding out
/// keeps showing its own step.
private struct OnboardingPage: View {
    let model: OnboardingModel
    let step: OnboardingModel.Step

    var body: some View {
        VStack(spacing: 0) {
            if step == .welcome {
                Text("NotchTheRock")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(OnboardingPalette.ink)
                    .padding(.bottom, 8)
            }
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, 8)
            switch step {
            case .permissions:
                PermissionCards(model: model).padding(.top, 22)
            case .setup(let pluginID):
                if let setup = model.setup(for: pluginID) {
                    SetupCards(model: model, step: setup).padding(.top, 22)
                }
            case .usage:
                UsageTiles().padding(.top, 22)
            case .welcome, .done:
                EmptyView()
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var title: String {
        switch step {
        case .welcome: "노치에 일을 맡겨요"
        case .permissions: "두 가지만 켜 주세요"
        case .setup(let pluginID): model.setup(for: pluginID)?.setup.title ?? ""
        case .usage: "이렇게 써요"
        case .done: "준비가 끝났어요"
        }
    }

    private var subtitle: String {
        switch step {
        case .welcome: "배터리 같은 소식을 노치에서 바로 확인해요."
        case .permissions: "나중에 설정에서 켜도 괜찮아요."
        case .setup(let pluginID): model.setup(for: pluginID)?.setup.message ?? ""
        case .usage: "노치 하나로 다 할 수 있어요."
        case .done: "건너뛴 항목은 설정에서 다시 켤 수 있어요."
        }
    }
}

/// The app mark: a dark tile with the notch hanging from its top edge, the greeting's colours
/// glowing around the notch and, slowly turning, around the tile.
private struct OnboardingMark: View {
    @State private var glowing = false
    @State private var turning = false

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: 24, style: .continuous)
        ZStack {
            Circle()
                .fill(AngularGradient(colors: OnboardingPalette.colors + [OnboardingPalette.colors[0]], center: .center))
                .frame(width: 112, height: 112)
                .rotationEffect(.degrees(turning ? 360 : 0))
                .blur(radius: 26)
                .opacity(glowing ? 0.85 : 0.5)
                .scaleEffect(glowing ? 1.08 : 0.94)
            tile
                .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.05)], startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .top) {
                    ZStack(alignment: .top) {
                        NotchShape(shoulderRadius: 6, bottomRadius: 14)
                            .fill(OnboardingPalette.ink)
                            .frame(width: 68, height: 28)
                            .blur(radius: 7)
                            .opacity(glowing ? 1 : 0.6)
                        NotchShape(shoulderRadius: 5, bottomRadius: 11)
                            .fill(Color.black)
                            .frame(width: 56, height: 21)
                    }
                }
                .clipShape(tile)
                .overlay {
                    tile.strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
                }
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { glowing = true }
            withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) { turning = true }
        }
        .accessibilityHidden(true)
    }
}

/// 손쉬운 사용 and 로그인 시 자동 실행, each with its live state and the action that turns it on.
private struct PermissionCards: View {
    let model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            OnboardingCardRow(icon: SymbolIcon(name: "accessibility"), title: "손쉬운 사용", detail: "볼륨·밝기 키를 노치에 보여줘요",
                              card: model.accessibilityState.card(action: "권한 열기")) {
                model.requestAccessibility()
            }
            CardDivider()
            OnboardingCardRow(icon: SymbolIcon(name: "power"), title: "로그인 시 자동 실행", detail: "Mac에 로그인하면 바로 켜져요",
                              card: model.loginItemState.card(action: "켜기")) {
                if model.loginItemState == .needsApproval {
                    model.openLoginItemsSettings()
                } else {
                    model.enableLaunchAtLogin()
                }
            }
        }
        .onboardingCardGroup()
    }
}

/// A plugin's setup items, drawn as the permission cards are. Each card reads its item's state while
/// it draws, so it follows the plugin; only its button sets the item up.
private struct SetupCards: View {
    let model: OnboardingModel
    let step: OnboardingModel.PluginSetupStep

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(step.setup.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { CardDivider() }
                OnboardingCardRow(icon: icon(item), title: item.title, detail: item.detail, card: OnboardingCard(setup: item.state)) {
                    model.performSetup(item)
                }
            }
        }
        .onboardingCardGroup()
    }

    @ViewBuilder private func icon(_ item: PluginSetupItem) -> some View {
        if let image = item.icon {
            image.resizable().scaledToFit().foregroundStyle(.white).frame(width: 17, height: 17)
        } else {
            SymbolIcon(name: step.symbol)
        }
    }
}

private struct SymbolIcon: View {
    let name: String

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
    }
}

private struct CardDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
            .padding(.leading, 58)
    }
}

extension View {
    /// The rounded panel the permission and setup cards sit in.
    fileprivate func onboardingCardGroup() -> some View {
        let card = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return background(card.fill(Color.white.opacity(0.06)))
            .overlay(card.strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
    }
}

/// One card: icon, title, the detail line (or the failure) and what `card` puts at the end.
private struct OnboardingCardRow<Icon: View>: View {
    let icon: Icon
    let title: String
    let detail: String
    let card: OnboardingCard
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.1)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                if let failure = card.failure {
                    Text(failure)
                        .font(.system(size: 12))
                        .foregroundStyle(OnboardingPalette.failure)
                        .lineLimit(2)
                } else {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var trailing: some View {
        switch card.status {
        case .done(let label):
            HStack(spacing: 6) {
                AnimatedCheck()
                Text(label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(OnboardingPalette.on)
            }
        case .attention(let label, let title):
            HStack(spacing: 10) {
                Text(label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(OnboardingPalette.attention)
                CardAction(title: title, action: action)
            }
        case .action(let title):
            CardAction(title: title, action: action)
        case .progress(let label):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        case .note(let text):
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .frame(maxWidth: 180, alignment: .trailing)
        }
    }
}

private struct CardAction: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(PillButtonStyle())
    }
}

/// The check on a card that is on: the badge pops in and the tick draws itself.
private struct AnimatedCheck: View {
    @State private var shown = false
    @State private var drawn = false

    var body: some View {
        ZStack {
            Circle().fill(OnboardingPalette.on)
            CheckMark()
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .padding(5)
        }
        .frame(width: 18, height: 18)
        .scaleEffect(shown ? 1 : 0.3)
        .opacity(shown ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.55)) { shown = true }
            withAnimation(.easeOut(duration: 0.3).delay(0.15)) { drawn = true }
        }
    }
}

private struct CheckMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.85))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.92, y: rect.minY + rect.height * 0.18))
        return path
    }
}

/// Four small tiles on how the notch is used.
private struct UsageTiles: View {
    private static let tips: [(symbol: String, title: String, detail: String)] = [
        ("cursorarrow.motionlines", "펼치기", "포인터를 노치에 올려요"),
        ("rectangle.split.3x1", "탭", "눌러서 기능을 바꿔요"),
        ("contextualmenu.and.cursorarrow", "설정…", "노치를 오른쪽 클릭해요"),
        ("gearshape", "톱니바퀴", "펼친 노치에서 설정을 열어요"),
    ]

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                tile(Self.tips[0])
                tile(Self.tips[1])
            }
            GridRow {
                tile(Self.tips[2])
                tile(Self.tips[3])
            }
        }
    }

    private func tile(_ tip: (symbol: String, title: String, detail: String)) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return HStack(spacing: 10) {
            Image(systemName: tip.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OnboardingPalette.ink)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 2) {
                Text(tip.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(tip.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.leading)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Color.white.opacity(0.06)))
        .overlay(shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
    }
}

/// Four dots; the current one is a longer bar in the greeting's colours.
private struct StepDots: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? AnyShapeStyle(OnboardingPalette.ink) : AnyShapeStyle(Color.white.opacity(index < current ? 0.4 : 0.16)))
                    .frame(width: index == current ? 20 : 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count)단계 중 \(current + 1)단계")
    }
}

/// A button title with the key that presses it, drawn as a small key cap.
private struct KeyHintLabel: View {
    let title: String
    let key: String
    let onLight: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Text(key)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(onLight ? Color.black.opacity(0.5) : Color.white.opacity(0.55))
                .padding(.horizontal, 5)
                .frame(minWidth: 20, minHeight: 18)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(onLight ? Color.black.opacity(0.08) : Color.white.opacity(0.1))
                )
        }
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.leading, 14)
            .padding(.trailing, 7)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(configuration.isPressed ? 0.75 : 0.95)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

private struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.95 : 0.7))
            .padding(.leading, 10)
            .padding(.trailing, 7)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0)))
            .contentShape(Rectangle())
    }
}

private struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.24 : 0.14)))
    }
}

/// Empty parts of the panel move the window: it has no title bar to drag.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
