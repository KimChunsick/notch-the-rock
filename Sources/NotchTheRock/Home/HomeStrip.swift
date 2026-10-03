import SwiftUI

/// The plugins without a grid place as one row of round icons, as wide as the grid. It scrolls
/// sideways when they are more than the grid holds, and to the icon with the keyboard's focus ring
/// (`NotchHostModel.listScrollTarget`). In edit mode the icons carry a + badge, with room above and
/// after them. The name of the icon under the pointer or the focus shows in a bubble over it, drawn
/// outside the scroll view so the strip does not clip it.
struct HomeStrip: View {
    let host: NotchHostModel
    let plugins: [HomePlugin]

    static let badgeRoom: CGFloat = 4

    var body: some View {
        let room = host.home.isEditing ? Self.badgeRoom : 0
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: HomeGrid.gap) {
                    ForEach(plugins, id: \.pluginID) { plugin in
                        StripIcon(host: host, plugin: plugin)
                            .id(plugin.pluginID)
                    }
                }
                .padding(.top, room)
                .padding(.trailing, room)
            }
            .scrollIndicators(.never)
            .frame(width: HomeGrid.size.width, height: HomeGrid.stripIcon + room, alignment: .leading)
            .overlayPreferenceValue(StripBubbleKey.self) { bubble in
                if let bubble {
                    GeometryReader { proxy in
                        BubblePlacement(icon: proxy[bubble.icon]) { StripBubble(name: bubble.name) }
                    }
                    .allowsHitTesting(false)
                }
            }
            // The focus also outlives a visit to a plugin's screen, where the strip is gone.
            .onAppear { if let target = host.listScrollTarget { proxy.scrollTo(target) } }
            .onChange(of: host.listScrollTarget) { _, target in
                if let target { proxy.scrollTo(target) }
            }
        }
    }
}

/// A plugin's symbol on a circle, with its name in a bubble while the pointer or the keyboard's
/// focus is on it, and as the VoiceOver label. It opens the plugin's screen; in edit mode it puts the
/// plugin on the grid (`NotchHostModel.tapHomePlugin(_:)`).
private struct StripIcon: View {
    let host: NotchHostModel
    let plugin: HomePlugin

    var body: some View {
        let editing = host.home.isEditing
        let hovered = host.home.hoveredIcon == plugin.pluginID
        let showsName = hovered || (!editing && host.keyboard.focus == plugin.pluginID)
        let size = HomeGrid.stripIcon
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { host.tapHomePlugin(plugin.pluginID) }
        } label: {
            Image(systemName: plugin.symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: size, height: size)
                .background(Circle().fill(.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // Inside the circle: the strip clips what lies outside it.
        .overlay {
            if !editing && host.keyboard.focus == plugin.pluginID {
                Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if editing {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .offset(x: HomeStrip.badgeRoom, y: -HomeStrip.badgeRoom)
                    .allowsHitTesting(false)
            }
        }
        .onHover { host.home.setHovering($0, icon: plugin.pluginID) }
        .onDisappear { host.home.setHovering(false, icon: plugin.pluginID) }
        .anchorPreference(key: StripBubbleKey.self, value: .bounds) { icon in
            showsName ? StripBubbleKey.Bubble(name: plugin.name, icon: icon, isHovered: hovered) : nil
        }
        .accessibilityLabel(plugin.name)
        .accessibilityHint(editing ? "위젯으로 올려요" : "")
    }
}

/// The strip icon whose name shows, the one under the pointer before the one with the focus.
private struct StripBubbleKey: PreferenceKey {
    struct Bubble {
        let name: String
        let icon: Anchor<CGRect>
        let isHovered: Bool
    }

    static var defaultValue: Bubble? { nil }

    static func reduce(value: inout Bubble?, nextValue: () -> Bubble?) {
        guard let next = nextValue(), value == nil || (next.isHovered && value?.isHovered == false) else { return }
        value = next
    }
}

/// A strip icon's name on a small light capsule, on one line: a name wider than the width it is
/// offered ends in an ellipsis (the icon's VoiceOver label keeps all of it).
private struct StripBubble: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(0.92)))
    }
}

/// Places its one subview, the bubble, just above `icon`: centred on it, but no wider than the
/// strip and kept within its width so it stays inside the notch.
private struct BubblePlacement: Layout {
    let icon: CGRect

    static let gap: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let bubble = subviews.first else { return }
        let size = bubble.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        let x = max(min(icon.midX - size.width / 2, bounds.width - size.width), 0)
        bubble.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + icon.minY - Self.gap - size.height), proposal: ProposedViewSize(size))
    }
}
