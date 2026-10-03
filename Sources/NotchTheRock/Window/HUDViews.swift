import NotchKit
import SwiftUI

/// The HUD in the collapsed notch's wings, placed as a live activity's views are: the symbol in the
/// left wing, as far from the side edge as from the bottom, and for a HUD with a value a thin bar in
/// the right wing. Both wings are as wide as the bar's, so the shape keeps its width while the
/// symbol changes (a speaker's waves by level). The title and detail are not drawn; VoiceOver reads
/// them.
struct HUDContent: View {
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
struct HUDSymbol: View {
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
