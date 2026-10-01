import AppKit
import CryptoKit
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

    /// Keychain calls can wait on the system, so the key is loaded here, never on the main thread,
    /// one load at a time: a load started after a quick off and on sees the key the earlier one
    /// stored.
    private static let keyQueue = DispatchQueue(label: "com.notchtherock.clipboard.history-key")

    private let context: NotchContext
    private let keychain: any HistoryKeychain
    private let pasteboard: NSPasteboard
    let history: ClipboardHistory
    /// Opens the history; set while the plugin is active.
    private(set) var opening: Task<Void, Never>?
    private var monitor: PasteboardMonitor?

    public convenience init(context: NotchContext) {
        self.init(context: context, keychain: context.storage, pasteboard: .general)
    }

    /// Tests pass a fake keychain and a private pasteboard.
    init(context: NotchContext, keychain: any HistoryKeychain, pasteboard: NSPasteboard) {
        self.context = context
        self.keychain = keychain
        self.pasteboard = pasteboard
        let log = context.log
        history = ClipboardHistory { log.error($0) }
    }

    /// Starts watching the pasteboard and records what it holds now, like a new copy. Loads the key
    /// in the background, then reloads the history from disk. Copies seen until then are held and
    /// recorded into the history once it opens; until then it shows what it showed before, nothing
    /// at launch.
    public func activate() {
        guard opening == nil else { return }
        history.holdCopiesUntilOpen()
        let monitor = PasteboardMonitor(pasteboard: pasteboard) { [history] pasteboard in
            history.record(from: pasteboard)
        }
        self.monitor = monitor
        // The monitor takes the change count before the content is read, so a copy made in between
        // is reported again instead of missed; a repeat only moves its entry to the top.
        monitor.start()
        history.record(from: pasteboard)
        let keychain = keychain
        let directory = context.storage.directory
        opening = Task { [weak self] in
            let opened = await withCheckedContinuation { continuation in
                Self.keyQueue.async {
                    continuation.resume(returning: Result { try ClipboardStore.open(in: directory, keychain: keychain) })
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.finishOpening(opened)
        }
    }

    /// Stops watching and waits for the pending history write, so quitting loses no change.
    public func deactivate() {
        opening?.cancel()
        opening = nil
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

    /// Opens the history with the encrypted store, or without one when the Keychain cannot give a
    /// key or an old history cannot be deleted yet: then the history, image originals included,
    /// stays in memory for this session and nothing is written to disk.
    private func finishOpening(_ opened: Result<(store: ClipboardStore, key: SymmetricKey, origin: HistoryKey.Origin), any Error>) {
        switch opened {
        case .success(let opened):
            if opened.origin == .replacedOldKeyThatNeedsAccess {
                context.log.info("the old clipboard history key cannot be read without asking, so a new clipboard history started under a new key")
            }
            history.open(opened.store)
        case .failure(let error):
            context.log.error("could not open the clipboard history store, keeping the history in memory only: \(error)")
            history.open(nil)
        }
    }
}

/// The C entry symbol the app resolves after loading the bundle. Keep one per plugin.
@_cdecl("notchkit_plugin_entry")
public func notchkitPluginEntry() -> UnsafeMutableRawPointer {
    NotchPluginEntry.export(ClipboardPlugin.self)
}
