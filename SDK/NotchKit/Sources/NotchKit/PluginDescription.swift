import Foundation
import Observation

/// What a plugin's page in the Settings window says about it: a short summary, the permissions it
/// uses with the reason for each, and its settings. The host draws every plugin's page from this in
/// the same order and shape; `NotchPlugin.settingsView` follows it for what does not fit, such as a
/// connect button. Declarations are shown to the user, not enforced. Added in SDK 1.4.
public struct PluginDescription: Hashable, Sendable {
    /// One or two sentences.
    public let summary: String
    /// Everything the plugin uses that the user may want to know about; an empty list says it uses
    /// none, and the host shows that.
    public let permissions: [PluginPermission]
    /// Drawn with the host's controls in this order; values are kept in `PluginStorage.defaults`
    /// and read through `NotchContext.settings`.
    public let settings: [PluginSettingItem]

    public init(summary: String, permissions: [PluginPermission], settings: [PluginSettingItem] = []) {
        self.summary = summary
        self.permissions = permissions
        self.settings = settings
    }
}

/// A permission or sensitive resource a plugin uses, and why. (SDK 1.4)
public struct PluginPermission: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// macOS Accessibility, for example to read keys or control other apps' windows.
        case accessibility
        /// Apple Events sent to `app`, named as the user knows it.
        case automation(app: String)
        case screenRecording
        case bluetooth
        case notifications
        /// Files outside the plugin's own directory; `path` names them, a pattern such as
        /// `~/Library/Calendars` or `~/.claude/projects/*`.
        case files(path: String)
        /// Keychain items beyond the plugin's own `PluginStorage` items.
        case keychain
        case network
        /// Starting helper programs or command-line tools.
        case helperProcesses
        /// Changing `app`'s own settings, for example a tool's configuration file.
        case otherAppSettings(app: String)
    }

    public let kind: Kind
    /// One short sentence: what the plugin does with it.
    public let reason: String

    public init(_ kind: Kind, reason: String) {
        self.kind = kind
        self.reason = reason
    }
}

/// One choice of a `PluginSettingItem.choice`: the value stored and the title shown. (SDK 1.4)
public struct PluginSettingOption: Hashable, Sendable {
    public let value: String
    public let title: String

    public init(_ value: String, title: String) {
        self.value = value
        self.title = title
    }
}

/// A setting the host draws on the plugin's page, stored under `key` in the plugin's
/// `PluginStorage.defaults`. (SDK 1.4)
public struct PluginSettingItem: Hashable, Sendable, Identifiable {
    public enum Control: Hashable, Sendable {
        /// A switch, read with `PluginSettings.bool(_:)`.
        case toggle(detail: String?, default: Bool)
        /// One of `options`, read with `PluginSettings.string(_:)` as the option's `value`.
        case choice(options: [PluginSettingOption], default: String)
        /// A number inside `range` in steps of `step`, read with `PluginSettings.number(_:)`.
        /// `unit` follows the value, as in `5초`.
        case number(range: ClosedRange<Double>, step: Double, unit: String?, default: Double)
        /// Free text, read with `PluginSettings.string(_:)`.
        case text(placeholder: String, default: String)
    }

    public let key: String
    public let title: String
    public let control: Control

    public var id: String { key }

    public init(key: String, title: String, control: Control) {
        self.key = key
        self.title = title
        self.control = control
    }

    public static func toggle(key: String, title: String, detail: String? = nil, default value: Bool) -> PluginSettingItem {
        PluginSettingItem(key: key, title: title, control: .toggle(detail: detail, default: value))
    }

    public static func choice(key: String, title: String, options: [PluginSettingOption], default value: String) -> PluginSettingItem {
        PluginSettingItem(key: key, title: title, control: .choice(options: options, default: value))
    }

    public static func number(key: String, title: String, range: ClosedRange<Double>, step: Double = 1, unit: String? = nil, default value: Double) -> PluginSettingItem {
        PluginSettingItem(key: key, title: title, control: .number(range: range, step: step, unit: unit, default: value))
    }

    public static func text(key: String, title: String, placeholder: String = "", default value: String = "") -> PluginSettingItem {
        PluginSettingItem(key: key, title: title, control: .text(placeholder: placeholder, default: value))
    }
}

/// The values of a plugin's declared settings, kept in its `PluginStorage.defaults` under each
/// item's key. The host writes here when the user changes a control; the plugin reads here and
/// hears every change through `changes()`. SwiftUI views that read a value follow its changes.
///
/// A stored value the item does not allow (another type, outside the range, not an option) reads
/// as the item's default. `set` ignores a value of another kind than the item, keeps a number
/// inside the range and ignores a choice that is not an option. Write through `set` so observers
/// hear it; a write straight to `defaults` is read but not announced. (SDK 1.4)
@MainActor
@Observable
public final class PluginSettings {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observers: [UUID: AsyncStream<String>.Continuation] = [:]
    /// Moves on every write, so a view that read any value is drawn again.
    private var revision = 0

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// A toggle's value; false for an item of another kind.
    public func bool(_ item: PluginSettingItem) -> Bool {
        _ = revision
        guard case .toggle(_, let initial) = item.control else { return false }
        return defaults.object(forKey: item.key) as? Bool ?? initial
    }

    /// A number item's value; 0 for an item of another kind.
    public func number(_ item: PluginSettingItem) -> Double {
        _ = revision
        guard case .number(let range, _, _, let initial) = item.control else { return 0 }
        guard let stored = (defaults.object(forKey: item.key) as? NSNumber)?.doubleValue, range.contains(stored) else { return initial }
        return stored
    }

    /// A choice's option value or a text item's text; empty for an item of another kind.
    public func string(_ item: PluginSettingItem) -> String {
        _ = revision
        let stored = defaults.object(forKey: item.key) as? String
        switch item.control {
        case .choice(let options, let initial):
            return stored.flatMap { value in options.contains { $0.value == value } ? value : nil } ?? initial
        case .text(_, let initial):
            return stored ?? initial
        case .toggle, .number:
            return ""
        }
    }

    public func set(_ value: Bool, for item: PluginSettingItem) {
        guard case .toggle = item.control else { return }
        write(value, for: item)
    }

    public func set(_ value: Double, for item: PluginSettingItem) {
        guard case .number(let range, _, _, _) = item.control else { return }
        write(min(max(value, range.lowerBound), range.upperBound), for: item)
    }

    public func set(_ value: String, for item: PluginSettingItem) {
        switch item.control {
        case .choice(let options, _) where options.contains(where: { $0.value == value }):
            write(value, for: item)
        case .text:
            write(value, for: item)
        case .choice, .toggle, .number:
            return
        }
    }

    /// The key of every value written from now on, in order, until the stream's task is
    /// cancelled. Each call returns its own stream.
    public func changes() -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.observers[id] = nil }
        }
        return stream
    }

    private func write(_ value: Any, for item: PluginSettingItem) {
        defaults.set(value, forKey: item.key)
        revision += 1
        for observer in observers.values {
            observer.yield(item.key)
        }
    }
}
