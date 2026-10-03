import NotchKit
import SwiftUI

/// Message, choices, text field and buttons of the first waiting request, under its band
/// (`AttentionBand`), which holds the icon, the title, the countdown and the close button.
/// A title the band cuts short also opens the details here, whole, so nothing of it is lost.
/// At least `minWidth` wide, so text fields and buttons have room; long text wraps at the widest
/// the notch gets. What the user fills in lives in the host model (`AttentionForm`); a request with
/// several choice groups shows one per step, with its place among them, 이전 and 다음, and its
/// buttons and its own text field on the last step.
struct AttentionContent: View {
    static let minWidth: CGFloat = 280

    let host: NotchHostModel
    let pending: NotchHostModel.PendingAttention
    /// Whether the title is shown above the message: when it does not fit the band.
    let showsTitle: Bool

    private var request: AttentionRequest { pending.request }
    private var form: AttentionForm { pending.form }

    /// Whether anything shows above the buttons: the title, a message, choices or a text field.
    private var hasDetails: Bool {
        showsTitle || !request.message.isEmpty || !request.choices.isEmpty || request.textField != nil
    }

    /// Spacing steps: 6 inside a choice group, 10 between the details, 14 above the buttons.
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if hasDetails {
                // A plain stack in the usual case; long requests scroll instead of being cut off,
                // with a cue that more is below.
                ViewThatFits(in: .vertical) {
                    details
                    ScrollView { details.padding(.bottom, MoreBelow.height) }
                        .scrollIndicators(.visible)
                        .overlay(alignment: .bottom) { MoreBelow() }
                }
            }

            HStack(spacing: 8) {
                if let releaseTitle = request.releaseTitle {
                    Button(releaseTitle) { host.respond(.released, to: pending.id) }
                        .buttonStyle(AttentionButtonStyle(fill: .white.opacity(0.12)))
                }
                Spacer(minLength: 0)
                if let progress = form.progress {
                    Text(progress)
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                        .accessibilityLabel("질문 \(form.groups.count)개 중 \(progress.prefix { $0 != "/" })번째")
                    Button("이전") { host.editAttention(pending.id) { $0.back() } }
                        .buttonStyle(AttentionButtonStyle(fill: .white.opacity(0.12)))
                        .disabled(form.isFirstStep)
                }
                if form.isLastStep {
                    ForEach(request.buttons, id: \.id) { button in
                        Button(button.title) { host.sendAttention(buttonID: button.id, of: pending.id) }
                            .buttonStyle(AttentionButtonStyle(fill: fill(for: button.role)))
                            .disabled(!form.canSend)
                    }
                    if request.buttons.isEmpty && !form.picksAnswerDirectly {
                        Button("보내기") { host.sendAttention(buttonID: nil, of: pending.id) }
                            .buttonStyle(AttentionButtonStyle(fill: request.accent))
                            .disabled(!form.canSend)
                    }
                } else {
                    Button("다음") { host.editAttention(pending.id) { $0.advance() } }
                        .buttonStyle(AttentionButtonStyle(fill: request.accent))
                        .disabled(!form.canAdvance)
                }
            }
        }
        .foregroundStyle(.white)
        .frame(minWidth: Self.minWidth, alignment: .topLeading)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsTitle {
                Text(request.title)
                    .font(AttentionBand.titleFont)
            }
            if !request.message.isEmpty {
                Text(request.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.75))
            }
            ForEach(form.shownGroups, id: \.id) { group in
                ChoiceGroup(group: group, accent: request.accent, selected: form.selections[group.id] ?? []) { option in
                    host.pickAttention(option, in: group, of: pending.id)
                }
                if let field = group.textField {
                    TextField(field.placeholder, text: text(of: group))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { submitText(of: group) }
                }
            }
            if form.isLastStep, let field = request.textField {
                TextField(field.placeholder, text: requestText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { host.sendAttention(buttonID: nil, of: pending.id) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func text(of group: AttentionChoices) -> Binding<String> {
        let id = pending.id
        return Binding { form.texts[group.id] ?? "" } set: { text in host.editAttention(id) { $0.texts[group.id] = text } }
    }

    private var requestText: Binding<String> {
        let id = pending.id
        return Binding { form.text } set: { text in host.editAttention(id) { $0.text = text } }
    }

    /// Return in a group's own field moves to the next question, or on the last one sends what the
    /// host's 보내기 would.
    private func submitText(of group: AttentionChoices) {
        if !form.isLastStep {
            host.editAttention(pending.id) { $0.advance() }
        } else if request.buttons.isEmpty {
            host.sendAttention(buttonID: nil, of: pending.id)
        }
    }

    private func fill(for role: AttentionButton.Role) -> Color {
        switch role {
        case .primary: request.accent
        case .destructive: .red
        case .normal, .cancel: .white.opacity(0.12)
        @unknown default: .white.opacity(0.12)
        }
    }
}

/// Pinned to the bottom of a card that scrolls: the details fade out above a note that more is
/// below. The details leave room for it at their end, so their last row scrolls clear of it.
private struct MoreBelow: View {
    static let height: CGFloat = 30

    var body: some View {
        Label("아래에 더 있어요", systemImage: "chevron.down")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.7))
            .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .bottom)
            .background(LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .center))
            .allowsHitTesting(false)
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
        StyledLabel(configuration: configuration, fill: fill)
    }

    /// Dimmed while the button is disabled (이전 on the first question, 다음 or a button before the
    /// question is answered).
    private struct StyledLabel: View {
        let configuration: Configuration
        let fill: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(Capsule().fill(fill.opacity(configuration.isPressed ? 0.7 : 1)))
                .foregroundStyle(.white)
                .opacity(isEnabled ? 1 : 0.4)
        }
    }
}

/// An attention's controls in the top band, split around the camera like a plugin screen's
/// (`PluginBand`): the source icon and the title in the left wing, the countdown and the close
/// button in the right. The shape grows until the left wing holds the whole title, up to its
/// widest; a longer title is cut short here, never under the camera's clearance, and shown whole
/// above the message (`titleFits`). The right wing keeps room for the most seconds the request can
/// show, so the shape does not move as they count down.
struct AttentionBand: View {
    static let iconSize: CGFloat = 20
    static let titleFont = Font.system(size: 14, weight: .semibold)

    let pending: NotchHostModel.PendingAttention
    let notchSize: CGSize
    let width: CGFloat
    let dismiss: () -> Void

    /// The narrowest attention shape that shows the whole title and the countdown beside the camera.
    static func minimumWidth(notch: CGSize, request: AttentionRequest) -> CGFloat {
        BandLayout.minimumWidth(notch: notch, leading: leadingWidth(request), trailing: trailingWidth(request))
    }

    /// Whether the left wing of the widest shape holds the icon and the whole title; when it does
    /// not, the band cuts the title short and the content shows it whole.
    static func titleFits(notch: CGSize, request: AttentionRequest) -> Bool {
        leadingWidth(request) <= BandLayout.wingRoom(notch: notch, width: NotchSizing.maxWidth)
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
                    .font(AttentionBand.titleFont)
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
