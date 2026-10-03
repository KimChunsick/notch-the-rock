import AppKit
import NotchKit
import SwiftUI

/// Keeps a history of copied text, images and links, encrypted on disk with a key kept in a file
/// only this user can read, and shows it in the expanded notch with search and pins and the latest
/// entries in a home tile. Content marked by password managers is never recorded.
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
    private let pasteboard: NSPasteboard
    private let openStore: @Sendable (URL) throws -> ClipboardStore.Opened
    let history: ClipboardHistory
    /// Opens the history; set while the plugin is active.
    private(set) var opening: Task<Void, Never>?
    private var monitor: PasteboardMonitor?
    private var isActive = false

    public convenience init(context: NotchContext) {
        self.init(context: context, pasteboard: .general)
    }

    /// Tests pass a private pasteboard, and an opening that can wait or fail before it opens the
    /// store in the given folder.
    init(
        context: NotchContext,
        pasteboard: NSPasteboard,
        openStore: @escaping @Sendable (URL) throws -> ClipboardStore.Opened = { try ClipboardStore.open(in: $0) }
    ) {
        self.context = context
        self.pasteboard = pasteboard
        self.openStore = openStore
        let log = context.log
        history = ClipboardHistory { log.error($0) }
    }

    /// Starts watching the pasteboard and records what it holds now, like a new copy; every copy
    /// shows in the list at once. Loads the key in the background, then reopens the history from
    /// disk, keeping the copies made meanwhile and saving them there.
    public func activate() {
        guard !isActive else { return }
        isActive = true
        history.beginOpening()
        let monitor = PasteboardMonitor(pasteboard: pasteboard) { [history] pasteboard in
            history.record(from: pasteboard)
        }
        self.monitor = monitor
        // The monitor takes the change count before the content is read, so a copy made in between
        // is reported again instead of missed; a repeat only moves its entry to the top.
        monitor.start()
        history.record(from: pasteboard)
        let openStore = openStore
        let directory = context.storage.directory
        // Off the main thread, one opening or reset at a time: an opening started after a quick off
        // and on sees the key file the earlier one created.
        opening = Task { [weak self] in
            let opened = await ClipboardStore.onKeyQueue { try openStore(directory) }
            guard let self, !Task.isCancelled else { return }
            self.finishOpening(opened)
        }
    }

    /// Stops watching and waits for the pending history write, so quitting loses no change that can
    /// be written. An opening still loading the key is dropped; the history keeps the copies made
    /// meanwhile, and the next opening that finishes saves them.
    public func deactivate() {
        guard isActive else { return }
        opening?.cancel()
        opening = nil
        monitor?.stop()
        monitor = nil
        history.flush()
        isActive = false
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

    /// Clearing and resetting the history are actions, not declared items, so they stay the plugin's own.
    public var settingsView: AnyView? {
        AnyView(ClipboardSettingsView(history: history))
    }

    public var pluginDescription: PluginDescription? {
        PluginDescription(
            summary: "복사한 텍스트와 이미지, 링크를 기록해 두고 노치에서 찾아 다시 복사할 수 있어요. 비밀번호 관리자가 표시한 내용은 기록하지 않아요.",
            permissions: [
                PluginPermission(.pasteboard, reason: "복사할 때마다 클립보드 내용을 읽어 기록에 더하고, 고른 기록을 클립보드에 다시 넣어요."),
                PluginPermission(.files(path: "플러그인 전용 폴더"), reason: "암호화한 기록과 그 키를 본인만 읽을 수 있는 파일로 저장해요."),
            ]
        )
    }

    /// Opens the history with the encrypted store, or without one when the key file cannot be read
    /// or created, an old history cannot be deleted yet or another opening keeps the opening lock
    /// too long: then the history, image originals included, stays in memory and nothing is written
    /// to disk until an opening succeeds.
    private func finishOpening(_ opened: Result<ClipboardStore.Opened, any Error>) {
        switch opened {
        case .success(let opened):
            if opened.origin == .replacedUntrustedFile {
                context.log.error("the clipboard history key file was not a private file of this user, so a new key file replaced it")
            }
            if opened.removedOldHistory {
                context.log.info("the clipboard history on disk was sealed with a key that is not in the key file, so a new clipboard history started")
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
