import NotchKit
import SwiftUI

/// Takes the volume and mute keys away from the system: each press changes the output directly and
/// shows a bar in the notch instead of the system's own display. The expanded tab and the home tile
/// adjust the same volume. The brightness keys are not this plugin's: it passes them on untouched,
/// so they reach the brightness plugin's tap, or the system when that plugin is off.
///
/// A key press is decided once, at its key-down: when the plugin handles it, its auto-repeats and
/// its release are the plugin's as well; when the key-down goes to the system, the rest of that
/// press goes there untouched, so while the tap sees every event the system never gets a release
/// without its press or the other way round. When the plugin loses sight of the keys (it is
/// deactivated, or the system turns the tap off for a while), the rest of every open press goes to
/// the system: the plugin can no longer tell which side a key-down made meanwhile went to.
///
/// The key tap needs the Accessibility permission. Without it the keys stay with the system, the
/// notch shows the guidance once per activation, and the plugin checks every
/// `permissionPollInterval` until the permission is on, then installs the tap.
@MainActor
public final class VolumePlugin: NotchPlugin {
    public static let manifest = PluginManifest(
        id: "com.notchtherock.volume",
        name: "볼륨",
        version: "1.0.0",
        symbol: "speaker.wave.2.fill",
        sdkVersion: NotchKitSDK.version
    )

    static let openAccessibilityButtonID = "open-accessibility"
    /// One key press moves the value by 1/16, or by 1/64 with ⌥⇧ held, as the system does.
    static let steps = 16
    static let fineSteps = 64
    static let hudDuration: Duration = .milliseconds(1500)

    let model: VolumeModel
    private let context: NotchContext
    private let tap: any KeyEventTap
    private let permissionPollInterval: Duration
    private var isActive = false
    private var guidanceTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    /// Keys held down in a press whose key-down the plugin handled: their repeats and release are
    /// consumed too. A repeat or release of any other press (its key-down went to the system, or came
    /// before the tap) goes to the system untouched. Emptied whenever the tap stops delivering
    /// events, so a new or resumed tap starts with no open press.
    private var handledKeys: Set<MediaKey> = []

    public convenience init(context: NotchContext) {
        self.init(
            context: context,
            volume: SystemVolume(),
            tap: SystemDefinedEventTap(),
            permissionPollInterval: .seconds(2)
        )
    }

    init(
        context: NotchContext,
        volume: any VolumeControl,
        tap: any KeyEventTap,
        permissionPollInterval: Duration
    ) {
        self.context = context
        self.model = VolumeModel(volume: volume)
        self.tap = tap
        self.permissionPollInterval = permissionPollInterval
    }

    public func activate() {
        guard !isActive else { return }
        isActive = true
        model.refresh()
        if context.permissions.isAccessibilityTrusted {
            installTap()
        } else {
            waitForAccessibility()
        }
    }

    public func deactivate() {
        guard isActive else { return }
        guidanceTask?.cancel()
        guidanceTask = nil
        permissionTask?.cancel()
        permissionTask = nil
        tap.remove()
        handledKeys.removeAll()
        isActive = false
    }

    public var expandedTab: PluginTab? {
        PluginTab(title: Self.manifest.name, symbol: Self.manifest.symbol) { [model] in
            VolumeView(model: model)
        }
    }

    public var tile: PluginTile? {
        PluginTile(supportedSizes: [.small, .wide]) { [model] size in
            VolumeTile(model: model, size: size)
        }
    }

    public var pluginDescription: PluginDescription? {
        PluginDescription(
            summary: "볼륨·음소거 키를 누르면 시스템 대신 노치에 볼륨을 보여 주고, 펼친 화면에서 볼륨을 조절할 수 있어요.",
            permissions: [
                PluginPermission(.accessibility, reason: "볼륨·음소거 키를 가로채서 시스템 대신 노치에서 처리하려고 써요. 이 플러그인을 끄면 키가 다시 시스템으로 가요."),
            ]
        )
    }

    public var settingsView: AnyView? {
        AnyView(VolumeSettingsView(isTrusted: context.permissions.isAccessibilityTrusted) { [context] in
            context.permissions.requestAccessibility()
        })
    }

    /// What happens to one `NX_SYSDEFINED` event: true when the plugin handled it and the system must
    /// not see it.
    func handle(_ event: SystemDefinedEvent) -> Bool {
        guard let press = MediaKeyPress(subtype: event.subtype, data1: event.data1) else { return false }
        switch press.state {
        case .up:
            return handledKeys.remove(press.key) != nil
        case .down:
            let fine = event.flags.contains(.maskAlternate) && event.flags.contains(.maskShift)
            let steps = fine ? Self.fineSteps : Self.steps
            if press.isRepeat {
                guard handledKeys.contains(press.key) else { return false }
                // Holding the mute key does not flip it back and forth, as with the system. A repeat
                // the device refuses stays consumed: the system must not see a repeat without its press.
                if press.key != .mute {
                    _ = perform(press.key, steps: steps)
                }
                return true
            }
            // A key-down whose release never came starts a new press all the same.
            let handled = perform(press.key, steps: steps)
            if handled {
                handledKeys.insert(press.key)
            } else {
                handledKeys.remove(press.key)
            }
            return handled
        }
    }

    /// Applies a key-down or an auto-repeat and shows the HUD: true when the device took the change.
    /// A change the device cannot make or refuses gets a HUD saying so with what the device holds.
    private func perform(_ key: MediaKey, steps: Int) -> Bool {
        switch key {
        case .soundUp, .soundDown:
            return show(model.stepVolume(by: key == .soundUp ? 1 : -1, steps: steps), title: "볼륨")
        case .mute:
            return show(model.toggleMute(), title: "음소거")
        }
    }

    /// Shows what became of a volume or mute key under `title`: true when the device took the change.
    private func show(_ adjustment: VolumeAdjustment, title: String) -> Bool {
        switch adjustment {
        case .changed(let state):
            showHUD(.volume(state))
            return true
        case .refused(let actual):
            showHUD(.unchangeable(title, actual))
            return false
        case .unavailable:
            showHUD(.unchangeable(title, nil))
            return false
        }
    }

    /// The tap missed events for a while: a held key may have been released and pressed again, and
    /// that key-down went to the system. No open press is surely the plugin's any more, so their
    /// repeats and releases go to the system; the next key-down starts a press as usual.
    private func deliveryInterrupted() {
        handledKeys.removeAll()
    }

    private func showHUD(_ hud: HUD) {
        context.showHUD(hud, duration: Self.hudDuration)
    }

    private func installTap() {
        let installed = tap.install(
            handler: { [weak self] event in self?.handle(event) ?? false },
            interrupted: { [weak self] in self?.deliveryInterrupted() }
        )
        if !installed {
            // Retrying would fail the same way until something changes; the next activation tries again.
            context.log.error("The system refused the key event tap; the volume and mute keys stay with the system.")
        }
    }

    private func waitForAccessibility() {
        guidanceTask = Task { [weak self] in
            await self?.showAccessibilityGuidance()
        }
        permissionTask = Task { [weak self, permissionPollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: permissionPollInterval)
                guard let self, !Task.isCancelled else { return }
                if self.context.permissions.isAccessibilityTrusted {
                    // Withdraws the guidance when it is still in the notch.
                    self.guidanceTask?.cancel()
                    self.guidanceTask = nil
                    self.permissionTask = nil
                    self.installTap()
                    return
                }
            }
        }
    }

    private func showAccessibilityGuidance() async {
        let response = await context.requestAttention(AttentionRequest(
            title: "손쉬운 사용 권한이 필요해요",
            message: "볼륨·음소거 키를 노치에서 바로 처리하려면 시스템 설정에서 NotchTheRock의 손쉬운 사용 권한을 켜 주세요. 권한을 켜기 전까지는 키가 원래대로 동작해요.",
            accent: .orange,
            buttons: [
                AttentionButton(id: Self.openAccessibilityButtonID, title: "권한 열기", role: .primary),
                AttentionButton(id: "later", title: "나중에", role: .cancel),
            ],
            timeout: .seconds(30)
        ))
        if case .answered(let answer) = response, answer.buttonID == Self.openAccessibilityButtonID {
            context.permissions.requestAccessibility()
        }
    }
}

extension HUD {
    /// The notch draws the symbol and the bar; VoiceOver reads the title and the detail.
    static func volume(_ state: VolumeState) -> HUD {
        if state.isMuted {
            return HUD(symbol: state.symbol, title: "음소거", value: 0)
        }
        return HUD(symbol: state.symbol, title: "볼륨", value: state.level, detail: percentText(state.level))
    }

    /// A volume or mute key the device did not take, with the state the device holds when known.
    /// The notch draws no text, so a speaker with an exclamation badge (macOS 12+) tells it apart
    /// from every speaker a change that went through shows.
    static func unchangeable(_ title: String, _ state: VolumeState?) -> HUD {
        HUD(
            symbol: "speaker.badge.exclamationmark.fill",
            title: title,
            value: state.map { $0.isMuted ? 0 : $0.level },
            detail: "바꿀 수 없어요"
        )
    }
}

/// The C entry symbol the app resolves after loading the bundle. Keep one per plugin.
@_cdecl("notchkit_plugin_entry")
public func notchkitPluginEntry() -> UnsafeMutableRawPointer {
    NotchPluginEntry.export(VolumePlugin.self)
}
