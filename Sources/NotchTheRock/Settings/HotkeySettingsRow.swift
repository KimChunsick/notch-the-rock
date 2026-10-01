import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 단축키: the global hotkey that opens the notch from any app. Clicking the shortcut records the
/// next key press in this window, which needs ⌘, ⌥ or ⌃; Esc stops recording, and so does the
/// window losing the focus or closing. The new shortcut works at once and
/// the old one stops; one that macOS or another app already has is refused with a message, and the
/// old one keeps working.
struct HotkeySettingsRow: View {
    let hotkey: GlobalHotkey
    @State private var recorder = ShortcutRecorder()

    var body: some View {
        LabeledContent("단축키") {
            HStack(spacing: 8) {
                Button(recorder.isRecording ? "새 단축키를 눌러 주세요…" : hotkey.shortcut.display) {
                    if recorder.isRecording {
                        recorder.stop(hotkey)
                    } else if let window = NSApp.keyWindow {
                        // The button's own window: a button acts in the key window.
                        recorder.start(hotkey, in: window)
                    }
                }
                .help(recorder.isRecording ? "Esc를 누르면 그만둬요" : "눌러서 단축키 바꾸기")
                Button("⌃⌥N으로 되돌리기") {
                    recorder.stop(hotkey)
                    hotkey.reset()
                }
                .disabled(hotkey.shortcut == .default && hotkey.refused == nil)
            }
        }
        .onDisappear { recorder.stop(hotkey) }
        Text("어느 앱에서나 이 단축키를 누르면 노치가 펼쳐지고, 다시 누르면 접혀요.")
            .font(.callout)
            .foregroundStyle(.secondary)
        if let message = recorder.hint ?? hotkey.refused.map(Self.conflict) {
            Text(message)
                .foregroundStyle(.red)
        }
    }

    static func conflict(_ shortcut: KeyShortcut) -> String {
        "\(shortcut.display) 단축키는 macOS나 다른 앱이 이미 쓰고 있어요. 다른 조합을 골라 주세요."
    }
}

/// Records one key press in one window for `HotkeySettingsRow` while the hotkey is suspended. Key
/// presses for other windows, such as the notch, go on to them; the recording stops when its window
/// resigns key or closes.
@MainActor
@Observable
final class ShortcutRecorder {
    private(set) var isRecording = false
    /// Why the last key press could not be a shortcut.
    private(set) var hint: String?
    @ObservationIgnored private var hotkey: GlobalHotkey?
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func start(_ hotkey: GlobalHotkey, in window: NSWindow) {
        guard !isRecording else { return }
        hint = nil
        isRecording = true
        self.hotkey = hotkey
        self.window = window
        hotkey.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let taken = MainActor.assumeIsolated { self?.takesKey(event) ?? false }
            return taken ? nil : event
        }
        // Delivered on the posting thread, so the recording has stopped when the window has lost
        // the focus; the main queue would stop it a turn later.
        observers = [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop(hotkey) }
            }
        }
    }

    func stop(_ hotkey: GlobalHotkey) {
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        self.hotkey = nil
        window = nil
        isRecording = false
        hotkey.resume()
    }

    /// Records `event` when it is a key press in the recording window, and says whether it took it.
    func takesKey(_ event: NSEvent) -> Bool {
        guard isRecording, let hotkey, let window, event.windowNumber == window.windowNumber else { return false }
        record(keyCode: event.keyCode, flags: event.modifierFlags, into: hotkey)
        return true
    }

    private func record(keyCode: UInt16, flags: NSEvent.ModifierFlags, into hotkey: GlobalHotkey) {
        guard keyCode != UInt16(kVK_Escape) else {
            hint = nil
            stop(hotkey)
            return
        }
        switch KeyShortcut.record(keyCode: keyCode, modifierFlags: flags) {
        case .shortcut(let shortcut):
            hint = nil
            hotkey.change(to: shortcut)
            stop(hotkey)
        case .needsModifier:
            hint = "⌘, ⌥, ⌃ 중 하나 이상과 함께 눌러 주세요."
        case .unsupportedKey:
            hint = "이 키는 단축키로 쓸 수 없어요. 글자, 숫자, 기능 키 중에서 골라 주세요."
        }
    }
}
