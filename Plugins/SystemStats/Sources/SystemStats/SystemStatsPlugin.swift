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
    private let makeSamplers: @MainActor () -> Samplers
    /// Starts the refresh loop of one activation. It is made in `init`, which knows the clock's type.
    private let startRefreshing: @MainActor (SystemStatsModel, StatsCollector) -> Task<Void, Never>
    private var refreshTask: Task<Void, Never>?

    public convenience init(context: NotchContext) {
        self.init(context: context, interval: Self.refreshInterval, makeSamplers: Samplers.live)
    }

    /// `makeSamplers` runs on every `activate()`; the samplers and their system handles (the SMC
    /// connection, the disk driver) are released when `deactivate()` stops the refresh loop.
    init<C: Clock<Duration>>(
        context: NotchContext,
        interval: Duration,
        clock: C = ContinuousClock(),
        makeSamplers: @escaping @MainActor () -> Samplers
    ) {
        self.makeSamplers = makeSamplers
        startRefreshing = { model, collector in Self.refresh(model, from: collector, every: interval, on: clock) }
    }

    public func activate() {
        guard refreshTask == nil else { return }
        refreshTask = startRefreshing(model, StatsCollector(samplers: makeSamplers()))
    }

    /// Records a reading at once, so the tab never opens empty, then one every `interval` until the
    /// returned task is cancelled.
    private static func refresh(
        _ model: SystemStatsModel,
        from collector: StatsCollector,
        every interval: Duration,
        on clock: some Clock<Duration>
    ) -> Task<Void, Never> {
        let start = clock.now
        model.record(collector.sample())
        return Task {
            var deadline = start
            while true {
                // Readings start `interval` apart, counted from the start of the previous one, so the
                // time a reading takes is not added to the wait. A reading that overran the interval
                // (or a Mac that slept) starts the next one at once and the cadence continues from
                // there, without a burst of readings to catch up.
                deadline = max(deadline.advanced(by: interval), clock.now)
                do { try await clock.sleep(until: deadline, tolerance: nil) } catch { return }
                // A sleep that ended just before deactivate() must not record after the reset.
                guard !Task.isCancelled else { return }
                model.record(collector.sample())
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
