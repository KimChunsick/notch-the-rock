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
    static let hudDuration: Duration = .milliseconds(2500)

    private let context: NotchContext
    private let model: BatteryModel
    private var monitor: PowerSourceMonitor?
    /// Percentage shown by the posted charging activity, nil while none is posted.
    private var postedChargingPercentage: Int?

    public convenience init(context: NotchContext) {
        self.init(context: context, sampler: BatteryDetail.sample)
    }

    /// `sampler` reads the screen's app and peripheral lists while it is shown; nil reads none.
    init(context: NotchContext, sampler: BatteryModel.Sampler?) {
        self.context = context
        self.model = BatteryModel(sampler: sampler)
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
        // The first reading after the next activate() seeds the state again instead of showing a HUD.
        model.status = nil
        clearChargingActivity()
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

    /// Applies a new reading. Only a change of external power shows the HUD; a reading without an
    /// earlier one (right after `activate()`) only sets the state.
    func update(_ status: PowerStatus?) {
        let previous = model.status
        model.status = status
        guard let status else {
            clearChargingActivity()
            return
        }
        if let previous, previous.isExternalPowerConnected != status.isExternalPowerConnected {
            context.showHUD(
                HUD(symbol: status.glyph, title: status.stateTitle, value: Double(status.percentage) / 100, detail: status.percentageText),
                duration: Self.hudDuration
            )
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

    private func postChargingActivity(_ status: PowerStatus) {
        context.post(LiveActivity(id: Self.chargingActivityID) {
            Image(systemName: "battery.100percent.bolt")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.green)
        } trailing: {
            Text(status.percentageText)
                .monospacedDigit()
        })
        postedChargingPercentage = status.percentage
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
