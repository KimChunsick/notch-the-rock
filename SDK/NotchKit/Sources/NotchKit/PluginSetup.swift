import SwiftUI

/// What a setup item shows in the first-launch onboarding. Added in SDK 1.3.
public enum PluginSetupState: Hashable, Sendable {
    /// The item cannot be set up on this Mac, for example because the tool it connects is not
    /// installed. The host shows the reason instead of the button.
    case unavailable(reason: String)
    /// Not set up yet: the host offers the button that calls `PluginSetupItem.perform()`.
    case notConnected
    /// Setting up is under way: the host shows progress and no button, and `message`, when given,
    /// in place of the item's detail line, for example while the plugin tries again by itself.
    case working(message: String?)
    /// Set up: the host shows a check.
    case connected
    /// The last attempt failed: the host shows the message and offers the button again.
    case failed(message: String)
}

/// One thing a plugin offers to set up in the first-launch onboarding, such as connecting a tool.
///
/// The host reads `state` while it draws the item's card, so back it with `@Observable` state and the
/// card follows every change. The host calls `perform()` only when the user presses the card's
/// button, never by itself; start long work in a `Task` and report `.working(message:)` meanwhile. Added in
/// SDK 1.3.
public struct PluginSetupItem: Identifiable {
    public let id: String
    public let title: String
    /// One short line under the title.
    public let detail: String
    /// Shown at the front of the card; nil shows the plugin's symbol.
    public let icon: Image?
    private let readState: @MainActor () -> PluginSetupState
    private let action: @MainActor () -> Void

    public init(
        id: String,
        title: String,
        detail: String,
        icon: Image? = nil,
        state: @escaping @MainActor () -> PluginSetupState,
        perform: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.icon = icon
        readState = state
        action = perform
    }

    @MainActor
    public var state: PluginSetupState { readState() }

    /// What the card's button does. The host calls it once per press.
    @MainActor
    public func perform() { action() }
}

/// A plugin's step in the first-launch onboarding: a title, one short line under it and the items,
/// each drawn as a card. Added in SDK 1.3.
public struct PluginSetup {
    public let title: String
    public let message: String
    /// Never empty.
    public let items: [PluginSetupItem]

    /// Returns nil when `items` is empty: the plugin then has no step.
    public init?(title: String, message: String, items: [PluginSetupItem]) {
        guard !items.isEmpty else { return nil }
        self.title = title
        self.message = message
        self.items = items
    }
}
