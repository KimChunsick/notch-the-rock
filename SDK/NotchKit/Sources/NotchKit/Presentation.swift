import SwiftUI

/// The presentation layers the host arbitrates between, lowest first.
///
/// The notch always shows the highest active layer: a takeover hides everything, an attention
/// request hides HUDs and live activities, a HUD hides live activities for its duration. Among
/// live activities the highest `priority` wins; on a tie the most recently posted one wins.
public enum NotchLayer: Int, Comparable, CaseIterable, Sendable {
    case liveActivity
    case hud
    case attention
    case takeover

    public static func < (lhs: NotchLayer, rhs: NotchLayer) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Short information shown on both sides of the collapsed notch.
///
/// Posting again with the same `id` replaces the earlier activity of the same plugin.
public struct LiveActivity {
    public let id: String
    /// Higher wins the collapsed notch. Built-in plugins use 0 for ambient information and 100
    /// for something the user is actively doing (for example music playing).
    public let priority: Int
    /// Removed automatically after this long; nil keeps it until `clear(activityID:)`.
    public let expiresAfter: Duration?
    /// View left of the notch.
    public let leading: AnyView
    /// View right of the notch.
    public let trailing: AnyView

    public init<Leading: View, Trailing: View>(
        id: String,
        priority: Int = 0,
        expiresAfter: Duration? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.id = id
        self.priority = priority
        self.expiresAfter = expiresAfter
        self.leading = AnyView(leading())
        self.trailing = AnyView(trailing())
    }
}

/// A short notice that slides out of the notch (volume, brightness, battery).
public struct HUD {
    /// SF Symbol name.
    public let symbol: String
    public let title: String
    /// Level from 0 to 1 drawn as a bar, or nil for no bar. Values outside 0...1 are clamped.
    public let value: Double?
    /// Secondary text, e.g. `79%`.
    public let detail: String?

    public init(symbol: String, title: String, value: Double? = nil, detail: String? = nil) {
        self.symbol = symbol
        self.title = title
        self.value = value.map { min(max($0, 0), 1) }
        self.detail = detail
    }
}

/// Content that takes over the whole expanded notch for `duration` (for example a greeting).
public struct Takeover {
    public let duration: Duration
    public let content: AnyView

    public init<Content: View>(duration: Duration, @ViewBuilder content: () -> Content) {
        self.duration = duration
        self.content = AnyView(content())
    }
}
