/// What a plugin's C entry function returns: the plugin's principal class, boxed so it can cross
/// the C boundary after `dlopen`.
///
/// Every plugin exports exactly one entry function. Copy these lines into the plugin and replace
/// `MyPlugin` with the principal class:
///
/// ```swift
/// @_cdecl("notchkit_plugin_entry")
/// public func notchkitPluginEntry() -> UnsafeMutableRawPointer {
///     NotchPluginEntry.export(MyPlugin.self)
/// }
/// ```
public final class NotchPluginEntry {
    /// The entry symbol a bundle uses when its Info.plist has no `NotchPluginEntry` key.
    public static let defaultSymbol = "notchkit_plugin_entry"

    public let pluginType: any NotchPlugin.Type

    public init(_ pluginType: any NotchPlugin.Type) {
        self.pluginType = pluginType
    }

    /// Returns a +1 retained box for `pluginType`; the host takes ownership of it.
    public static func export(_ pluginType: any NotchPlugin.Type) -> UnsafeMutableRawPointer {
        Unmanaged.passRetained(NotchPluginEntry(pluginType)).toOpaque()
    }
}

/// C signature of the entry function.
typealias NotchPluginEntryFunction = @convention(c) () -> UnsafeMutableRawPointer
