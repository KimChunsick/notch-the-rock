import NotchKit
import SwiftUI

/// 손쉬운 사용 and 로그인 시 자동 실행, each with its live state and the action that turns it on.
struct PermissionCards: View {
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
struct SetupCards: View {
    let model: OnboardingModel
    let step: OnboardingModel.PluginSetupStep

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(step.setup.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { CardDivider() }
                OnboardingCardRow(icon: icon(item), title: item.title, detail: item.detail, card: OnboardingCard(setup: item.state)) {
                    model.performSetup(item, of: step.pluginID)
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

/// One card: icon, title, the detail line (or what `card` shows in its place) and what `card` puts
/// at the end.
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
                switch card.detail {
                case .failure(let text):
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(OnboardingPalette.failure)
                        .lineLimit(2)
                case .progress(let text):
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                case nil:
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
