import NotchKit
import SwiftUI

/// Takes the volume, mute and brightness keys away from the system: each press changes the value
/// directly and slides a bar out of the notch instead of the system's own display. The expanded tab
/// and the home tile adjust the same values.
///
/// The key tap needs the Accessibility permission. Without it the keys stay with the system, the
/// notch shows the guidance once per activation, and the plugin checks every
/// `permissionPollInterval` until the permission is on, then installs the tap.
@MainActor
public final class MediaKeysPlugin: NotchPlugin {
    public static let manifest = PluginManifest(
        id: "com.notchtherock.mediakeys",
        name: "볼륨과 밝기",
        version: "1.0.0",
        symbol: "speaker.wave.2.fill",
        sdkVersion: NotchKitSDK.version
    )

    static let openAccessibilityButtonID = "open-accessibility"
    /// One key press moves the value by 1/16, or by 1/64 with ⌥⇧ held, as the system does.
    static let steps = 16
    static let fineSteps = 64
    static let hudDuration: Duration = .milliseconds(1500)

    let model: MediaKeysModel
    private let context: NotchContext
    private let tap: any KeyEventTap
    private let permissionPollInterval: Duration
    private var isActive = false
    private var guidanceTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    /// Keys whose last press the plugin handled: their release is dropped too. A release whose press
    /// went to the system goes to the system as well.
    private var handledKeys: Set<MediaKey> = []

    public convenience init(context: NotchContext) {
        self.init(
            context: context,
            volume: SystemVolume(),
            brightness: DisplayServicesBrightness(),
            tap: SystemDefinedEventTap(),
            permissionPollInterval: .seconds(2)
        )
    }

    init(
        context: NotchContext,
        volume: any VolumeControl,
        brightness: any BrightnessControl,
        tap: any KeyEventTap,
        permissionPollInterval: Duration
    ) {
        self.context = context
        self.model = MediaKeysModel(volume: volume, brightness: brightness)
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
        isActive = false
        guidanceTask?.cancel()
        guidanceTask = nil
        permissionTask?.cancel()
        permissionTask = nil
        tap.remove()
        handledKeys.removeAll()
    }

    public var expandedTab: PluginTab? {
        PluginTab(title: Self.manifest.name, symbol: Self.manifest.symbol) { [model] in
            MediaKeysView(model: model)
        }
    }

    public var tile: PluginTile? {
        PluginTile(supportedSizes: [.small, .wide]) { [model] size in
            MediaKeysTile(model: model, size: size)
        }
    }

    /// What happens to one `NX_SYSDEFINED` event: true when the plugin handled it and the system must
    /// not see it.
    func handle(_ event: SystemDefinedEvent) -> Bool {
        guard let press = MediaKeyPress(subtype: event.subtype, data1: event.data1) else { return false }
        switch press.state {
        case .up:
            return handledKeys.remove(press.key) != nil
        case .down:
            if press.isRepeat, press.key == .mute {
                // Holding the mute key does not flip it back and forth, as with the system.
                return handledKeys.contains(.mute)
            }
            let fine = event.flags.contains(.maskAlternate) && event.flags.contains(.maskShift)
            let handled = perform(press.key, steps: fine ? Self.fineSteps : Self.steps)
            if handled {
                handledKeys.insert(press.key)
            } else {
                handledKeys.remove(press.key)
            }
            return handled
        }
    }

    /// Applies a key press (or its auto-repeat) and shows the HUD. False leaves the key to the
    /// system: a volume or mute change the device cannot make or refuses gets a HUD saying so with
    /// what the device holds, a brightness change the display cannot make or refuses gets nothing.
    private func perform(_ key: MediaKey, steps: Int) -> Bool {
        switch key {
        case .soundUp, .soundDown:
            return show(model.stepVolume(by: key == .soundUp ? 1 : -1, steps: steps), title: "볼륨")
        case .mute:
            return show(model.toggleMute(), title: "음소거")
        case .brightnessUp, .brightnessDown:
            guard let value = model.stepBrightness(by: key == .brightnessUp ? 1 : -1, steps: steps) else {
                return false
            }
            showHUD(.brightness(value))
            return true
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

    private func showHUD(_ hud: HUD) {
        context.showHUD(hud, duration: Self.hudDuration)
    }

    private func installTap() {
        let installed = tap.install { [weak self] event in
            self?.handle(event) ?? false
        }
        if !installed {
            // Retrying would fail the same way until something changes; the next activation tries again.
            context.log.error("The system refused the key event tap; the volume and brightness keys stay with the system.")
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
            message: "볼륨·음소거·밝기 키를 노치에서 바로 처리하려면 시스템 설정에서 NotchTheRock의 손쉬운 사용 권한을 켜 주세요. 권한을 켜기 전까지는 키가 원래대로 동작해요.",
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
    static func volume(_ state: VolumeState) -> HUD {
        if state.isMuted {
            return HUD(symbol: state.symbol, title: "음소거", value: 0)
        }
        return HUD(symbol: state.symbol, title: "볼륨", value: state.level, detail: percentText(state.level))
    }

    static func brightness(_ value: Double) -> HUD {
        HUD(symbol: "sun.max.fill", title: "밝기", value: value, detail: percentText(value))
    }

    /// A volume or mute key the device did not take, with the state the device holds when known.
    static func unchangeable(_ title: String, _ state: VolumeState?) -> HUD {
        guard let state else {
            return HUD(symbol: "speaker.slash.fill", title: title, detail: "바꿀 수 없어요")
        }
        return HUD(symbol: state.symbol, title: title, value: state.isMuted ? 0 : state.level, detail: "바꿀 수 없어요")
    }
}

/// The C entry symbol the app resolves after loading the bundle. Keep one per plugin.
@_cdecl("notchkit_plugin_entry")
public func notchkitPluginEntry() -> UnsafeMutableRawPointer {
    NotchPluginEntry.export(MediaKeysPlugin.self)
}
