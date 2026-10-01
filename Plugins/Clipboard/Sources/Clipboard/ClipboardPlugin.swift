import AppKit
import NotchKit
import SwiftUI

/// Keeps a history of copied text, images and links, encrypted on disk with a key kept in the
/// Keychain, and shows it in the expanded notch with search and pins and the latest entries in a
/// home tile. Content marked by password managers is never recorded.
@MainActor
public final class ClipboardPlugin: NotchPlugin {
    public static let manifest = PluginManifest(
        id: "com.notchtherock.clipboard",
        name: "클립보드",
        version: "1.0.0",
        symbol: "doc.on.clipboard",
        sdkVersion: NotchKitSDK.version
    )

    private let context: NotchContext
    private let history: ClipboardHistory
    private var monitor: PasteboardMonitor?

    public init(context: NotchContext) {
        self.context = context
        let log = context.log
        history = ClipboardHistory { log.error($0) }
    }

    /// Reloads the history from disk and starts watching the general pasteboard.
    public func activate() {
        guard monitor == nil else { return }
        history.open(openStore())
        let monitor = PasteboardMonitor(pasteboard: .general) { [history] pasteboard in
            history.record(from: pasteboard)
        }
        self.monitor = monitor
        monitor.start()
    }

    /// Stops watching and waits for the pending history write, so quitting loses no change.
    public func deactivate() {
        monitor?.stop()
        monitor = nil
        history.flush()
    }

    public var expandedTab: PluginTab? {
        PluginTab(title: Self.manifest.name, symbol: Self.manifest.symbol) { [history] in
            ClipboardView(history: history)
        }
    }

    /// Wide: the latest entries. Small: the newest one.
    public var tile: PluginTile? {
        PluginTile(supportedSizes: [.wide, .small]) { [history] size in
            ClipboardTile(history: history, size: size)
        }
    }

    public var settingsView: AnyView? {
        AnyView(ClipboardSettingsView(history: history))
    }

    /// The encrypted store, or nil when the Keychain cannot give a key. Then the history, image
    /// originals included, stays in memory for this session and nothing is written to disk.
    private func openStore() -> ClipboardStore? {
        do {
            let key = try HistoryKey.loadOrCreate(in: context.storage)
            return ClipboardStore(directory: context.storage.directory, key: key)
        } catch {
            context.log.error("no clipboard history key, keeping the history in memory only: \(error)")
            return nil
        }
    }
}

/// The C entry symbol the app resolves after loading the bundle. Keep one per plugin.
@_cdecl("notchkit_plugin_entry")
public func notchkitPluginEntry() -> UnsafeMutableRawPointer {
    NotchPluginEntry.export(ClipboardPlugin.self)
}
