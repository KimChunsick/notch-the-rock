import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 단축키: the global hotkey that opens the notch from any app. Clicking the shortcut records the
/// next key press, which needs ⌘, ⌥ or ⌃; Esc stops recording. The new shortcut works at once and
/// the old one stops; one that macOS or another app already has is refused with a message, and the
/// old one keeps working.
struct HotkeySettingsRow: View {
    let hotkey: GlobalHotkey
    @State private var recorder = ShortcutRecorder()

    var body: some View {
        LabeledContent("단축키") {
            HStack(spacing: 8) {
                Button(recorder.isRecording ? "새 단축키를 눌러 주세요…" : hotkey.shortcut.display) {
                    if recorder.isRecording { recorder.stop(hotkey) } else { recorder.start(hotkey) }
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

/// Records one key press for `HotkeySettingsRow` while the hotkey is suspended.
@MainActor
@Observable
final class ShortcutRecorder {
    private(set) var isRecording = false
    /// Why the last key press could not be a shortcut.
    private(set) var hint: String?
    @ObservationIgnored private var monitor: Any?

    func start(_ hotkey: GlobalHotkey) {
        guard !isRecording else { return }
        hint = nil
        isRecording = true
        hotkey.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            MainActor.assumeIsolated { self?.record(keyCode: keyCode, flags: flags, into: hotkey) }
            return nil
        }
    }

    func stop(_ hotkey: GlobalHotkey) {
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        hotkey.resume()
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
