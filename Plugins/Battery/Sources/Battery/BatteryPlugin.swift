import NotchKit
import SwiftUI

/// Slides the percentage and charging state out of the notch when external power connects or
/// disconnects, shows a compact charging indicator beside the notch while charging, shows the
/// percentage in a home tile, and shows the percentage, state and remaining time in its screen with
/// the apps using the most energy and the connected peripherals' batteries below them.
@MainActor
public final class BatteryPlugin: NotchPlugin {
    public static let manifest = PluginManifest(
        id: "com.notchtherock.battery",
        name: "배터리",
        version: "1.0.0",
        symbol: "battery.100percent",
        sdkVersion: NotchKitSDK.version
    )

    static let chargingActivityID = "charging"
    static let powerChangeActivityID = "power-change"
    /// How long the power-change activity stays beside the notch.
    static let powerChangeDuration: Duration = .milliseconds(2500)
    /// Above the always-on charging activity and level with something playing, so a later post wins.
    static let powerChangePriority = 100

    private let context: NotchContext
    private let model: BatteryModel
    private var monitor: PowerSourceMonitor?
    /// Percentage shown by the posted charging activity, nil while none is posted.
    private var postedChargingPercentage: Int?
    /// The reading the posted power-change activity shows and when the host removes it, nil once
    /// it is gone.
    private var powerChange: (status: PowerStatus, expiry: ContinuousClock.Instant)?
    /// The plugin's clock, on which the power-change activity's expiry is timed.
    private let now: @MainActor () -> ContinuousClock.Instant

    public convenience init(context: NotchContext) {
        self.init(context: context, sampler: BatteryDetail.sample)
    }

    /// `sampler` reads the screen's app and peripheral lists while it is shown; nil reads none.
    init(context: NotchContext, sampler: BatteryModel.Sampler?, now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) {
        self.context = context
        self.model = BatteryModel(sampler: sampler)
        self.now = now
    }

    public func activate() {
        guard monitor == nil else { return }
        let monitor = PowerSourceMonitor { [weak self] status in
            self?.update(status)
        }
        self.monitor = monitor
        update(PowerSourceMonitor.read())
        monitor.start()
    }

    public func deactivate() {
        monitor?.stop()
        monitor = nil
        // The first reading after the next activate() seeds the state again instead of sliding out.
        model.status = nil
        clearChargingActivity()
        context.clear(activityID: Self.powerChangeActivityID)
        powerChange = nil
    }

    public var expandedTab: PluginTab? {
        PluginTab(title: Self.manifest.name, symbol: Self.manifest.symbol) { [model] in
            BatteryView(model: model)
        }
    }

    public var tile: PluginTile? {
        PluginTile(supportedSizes: [.small, .wide]) { [model] size in
            BatteryTile(model: model, size: size)
        }
    }

    /// Applies a new reading. Only a change of external power slides the state and percentage out
    /// for `powerChangeDuration`; a reading while they are out shows its state and percentage until
    /// the same expiry. A reading without an earlier one (right after `activate()`) only sets the state.
    func update(_ status: PowerStatus?) {
        let previous = model.status
        model.status = status
        guard let status else {
            clearChargingActivity()
            return
        }
        let current = now()
        if let previous, previous.isExternalPowerConnected != status.isExternalPowerConnected {
            postPowerChange(status, until: current + Self.powerChangeDuration, now: current)
        } else if let shown = powerChange {
            if shown.expiry <= current {
                powerChange = nil
            } else if shown.status.state != status.state || shown.status.percentage != status.percentage {
                // e.g. charging starts a moment after the power connects, or the percentage ticks.
                postPowerChange(status, until: shown.expiry, now: current)
            }
        }
        if status.state == .charging {
            // IOKit reports every change of the time estimate too; re-post only when the text changes.
            if postedChargingPercentage != status.percentage {
                postChargingActivity(status)
            }
        } else {
            clearChargingActivity()
        }
    }

    /// A live activity, not a HUD: the host draws a HUD's symbol and bar only. The host restarts an
    /// activity's expiry on every post with the same id, so a refresh asks only for the time left.
    private func postPowerChange(_ status: PowerStatus, until expiry: ContinuousClock.Instant, now current: ContinuousClock.Instant) {
        context.post(Self.activity(
            id: Self.powerChangeActivityID, priority: Self.powerChangePriority,
            expiresAfter: expiry - current, status: status
        ))
        powerChange = (status, expiry)
    }

    private func postChargingActivity(_ status: PowerStatus) {
        context.post(Self.activity(id: Self.chargingActivityID, status: status))
        postedChargingPercentage = status.percentage
    }

    /// The state glyph left of the notch (a green bolt while charging) and the percentage right of
    /// it. VoiceOver reads both once, from the glyph, as "충전 중, 46%".
    private static func activity(id: String, priority: Int = 0, expiresAfter: Duration? = nil, status: PowerStatus) -> LiveActivity {
        LiveActivity(id: id, priority: priority, expiresAfter: expiresAfter) {
            glyph(status)
                .accessibilityLabel("\(status.stateTitle), \(status.percentageText)")
        } trailing: {
            Text(status.percentageText)
                .monospacedDigit()
                .accessibilityHidden(true)
        }
    }

    /// Other states keep the host's colour.
    @ViewBuilder
    private static func glyph(_ status: PowerStatus) -> some View {
        let image = Image(systemName: status.glyph).symbolRenderingMode(.hierarchical)
        if status.state == .charging {
            image.foregroundStyle(.green)
        } else {
            image
        }
    }

    private func clearChargingActivity() {
        guard postedChargingPercentage != nil else { return }
        context.clear(activityID: Self.chargingActivityID)
        postedChargingPercentage = nil
    }

    public var pluginDescription: PluginDescription? {
        PluginDescription(
            summary: "배터리 잔량과 충전 상태를 노치에 보여 주고, 펼친 화면에서 남은 시간, 연결한 기기의 배터리, 에너지를 많이 쓰는 앱을 보여줘요.",
            permissions: [
                PluginPermission(.helperProcesses, reason: "펼친 화면을 보는 동안 앱별 에너지 사용은 /usr/bin/top으로, 블루투스 기기 배터리는 system_profiler로 읽어요."),
            ]
        )
    }
}

/// The C entry symbol the app resolves after loading the bundle. Keep one per plugin.
@_cdecl("notchkit_plugin_entry")
public func notchkitPluginEntry() -> UnsafeMutableRawPointer {
    NotchPluginEntry.export(BatteryPlugin.self)
}
