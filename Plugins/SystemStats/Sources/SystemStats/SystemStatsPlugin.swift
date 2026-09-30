import Foundation
import NotchKit
import SwiftUI

/// CPU, GPU, memory, disk, network and sensor readings in the expanded notch, refreshed every two
/// seconds while the plugin is active, each with a one-minute sparkline.
@MainActor
public final class SystemStatsPlugin: NotchPlugin {
    public static let manifest = PluginManifest(
        id: "com.notchtherock.systemstats",
        name: "시스템 상태",
        version: "1.0.0",
        symbol: "cpu",
        sdkVersion: NotchKitSDK.version
    )

    static let refreshInterval: Duration = .seconds(2)

    private let model = SystemStatsModel()
    private let interval: Duration
    private let makeSamplers: @MainActor () -> Samplers
    private var refreshTask: Task<Void, Never>?

    public convenience init(context: NotchContext) {
        self.init(context: context, interval: Self.refreshInterval, makeSamplers: Samplers.live)
    }

    /// `makeSamplers` runs on every `activate()`; the samplers and their system handles (the SMC
    /// connection, the disk driver) are released when `deactivate()` stops the refresh loop.
    init(context: NotchContext, interval: Duration, makeSamplers: @escaping @MainActor () -> Samplers) {
        self.interval = interval
        self.makeSamplers = makeSamplers
    }

    public func activate() {
        guard refreshTask == nil else { return }
        let collector = StatsCollector(samplers: makeSamplers())
        let model = model
        let interval = interval
        model.record(collector.sample(at: ProcessInfo.processInfo.systemUptime))
        refreshTask = Task {
            while true {
                do { try await Task.sleep(for: interval) } catch { return }
                // A sleep that ended just before deactivate() must not record after the reset.
                guard !Task.isCancelled else { return }
                model.record(collector.sample(at: ProcessInfo.processInfo.systemUptime))
            }
        }
    }

    public func deactivate() {
        refreshTask?.cancel()
        refreshTask = nil
        // The next activation starts with fresh counters and an empty history.
        model.reset()
    }

    public var expandedTab: PluginTab? {
        PluginTab(title: Self.manifest.name, symbol: Self.manifest.symbol) { [model] in
            SystemStatsView(model: model)
        }
    }

    /// The latest snapshot, for tests.
    var snapshot: SystemSnapshot? { model.snapshot }
}

/// The C entry symbol the app resolves after loading the bundle. Keep one per plugin.
@_cdecl("notchkit_plugin_entry")
public func notchkitPluginEntry() -> UnsafeMutableRawPointer {
    NotchPluginEntry.export(SystemStatsPlugin.self)
}
