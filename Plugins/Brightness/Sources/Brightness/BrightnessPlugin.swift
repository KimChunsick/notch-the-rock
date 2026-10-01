import NotchKit
import SwiftUI

/// Takes the brightness keys away from the system: each press changes the built-in display's
/// brightness directly and shows a bar in the notch instead of the system's own display. The
/// expanded tab and the home tile adjust the same brightness. The volume and mute keys are not this
/// plugin's: it passes them on untouched, so they reach the volume plugin's tap, or the system when
/// that plugin is off.
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
public final class BrightnessPlugin: NotchPlugin {
    public static let manifest = PluginManifest(
        id: "com.notchtherock.brightness",
        name: "밝기",
        version: "1.0.0",
        symbol: "sun.max.fill",
        sdkVersion: NotchKitSDK.version
    )

    static let openAccessibilityButtonID = "open-accessibility"
    /// One key press moves the value by 1/16, or by 1/64 with ⌥⇧ held, as the system does.
    static let steps = 16
    static let fineSteps = 64
    static let hudDuration: Duration = .milliseconds(1500)

    let model: BrightnessModel
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
            brightness: DisplayServicesBrightness(),
            tap: SystemDefinedEventTap(),
            permissionPollInterval: .seconds(2)
        )
    }

    init(
        context: NotchContext,
        brightness: any BrightnessControl,
        tap: any KeyEventTap,
        permissionPollInterval: Duration
    ) {
        self.context = context
        self.model = BrightnessModel(brightness: brightness)
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
            BrightnessView(model: model)
        }
    }

    public var tile: PluginTile? {
        PluginTile(supportedSizes: [.small, .wide]) { [model] size in
            BrightnessTile(model: model, size: size)
        }
    }

    public var settingsView: AnyView? {
        AnyView(BrightnessSettingsView(isTrusted: context.permissions.isAccessibilityTrusted) { [context] in
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
                // A repeat the display refuses stays consumed: the system must not see a repeat
                // without its press.
                _ = perform(press.key, steps: steps, consumed: true)
                return true
            }
            // A key-down whose release never came starts a new press all the same.
            let handled = perform(press.key, steps: steps, consumed: false)
            if handled {
                handledKeys.insert(press.key)
            } else {
                handledKeys.remove(press.key)
            }
            return handled
        }
    }

    /// Applies a key-down or an auto-repeat and shows the HUD: true when the display took the change.
    /// A change the display cannot make or refuses gets a HUD only when the event is `consumed`
    /// whatever the outcome (a repeat of a handled press); otherwise the key goes to the system,
    /// which shows its own.
    private func perform(_ key: MediaKey, steps: Int, consumed: Bool) -> Bool {
        guard let value = model.stepBrightness(by: key == .brightnessUp ? 1 : -1, steps: steps) else {
            if consumed {
                showHUD(.unchangeableBrightness(model.brightness))
            }
            return false
        }
        showHUD(.brightness(value))
        return true
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
            context.log.error("The system refused the key event tap; the brightness keys stay with the system.")
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
            message: "밝기 키를 노치에서 바로 처리하려면 시스템 설정에서 NotchTheRock의 손쉬운 사용 권한을 켜 주세요. 권한을 켜기 전까지는 키가 원래대로 동작해요.",
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
    static func brightness(_ value: Double) -> HUD {
        HUD(symbol: "sun.max.fill", title: "밝기", value: value, detail: percentText(value))
    }

    /// A brightness key the display did not take, with the brightness it holds when known. The notch
    /// draws no text, so a sun with an exclamation badge (macOS 13+) tells it apart from a change
    /// that went through; it keeps the `sun.` prefix, by which the notch fills the bar warm.
    static func unchangeableBrightness(_ value: Double?) -> HUD {
        HUD(symbol: "sun.max.trianglebadge.exclamationmark.fill", title: "밝기", value: value, detail: "바꿀 수 없어요")
    }
}

/// The C entry symbol the app resolves after loading the bundle. Keep one per plugin.
@_cdecl("notchkit_plugin_entry")
public func notchkitPluginEntry() -> UnsafeMutableRawPointer {
    NotchPluginEntry.export(BrightnessPlugin.self)
}
