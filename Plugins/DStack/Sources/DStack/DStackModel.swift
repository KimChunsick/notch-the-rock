import Foundation
import Observation

/// The projects the plugin shows and how it keeps them current: once on activation, and every
/// `interval` while the screen or a tile is shown. The files are looked at off the main actor by a
/// `DStackScanner`; the snapshot it returns is published here.
@MainActor
@Observable
final class DStackModel {
    struct Project: Identifiable, Equatable, Sendable {
        let url: URL
        let reading: StoreReading
        let isDiscovered: Bool
        /// Whether the folder has a run pointer, so settings can tell a store without an open run
        /// from a folder without a store.
        let hasStore: Bool
        var id: String { url.path }
        var name: String { url.lastPathComponent }

        var latest: Date? {
            if case .open(let run) = reading { return run.latest?.date }
            return nil
        }
    }

    /// Every project, for settings: discovered and added ones, without removed ones.
    private(set) var projects: [Project] = []
    /// When the files were last checked; the relative times count from it.
    private(set) var checkedAt: Date

    @ObservationIgnored private let scanner: DStackScanner
    @ObservationIgnored private let folders: ProjectFolders
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let interval: Duration
    /// The latest refresh started and the latest one published, so a slower earlier scan never
    /// overwrites a later one (a removed folder would come back).
    @ObservationIgnored private var requested = 0
    @ObservationIgnored private var published = 0
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var shownCount = 0
    @ObservationIgnored private var polling: Task<Void, Never>?

    init(discovery: ProjectDiscovery, folders: ProjectFolders, now: @escaping () -> Date, interval: Duration = .seconds(5)) {
        scanner = DStackScanner(discovery: discovery)
        self.folders = folders
        self.now = now
        self.interval = interval
        checkedAt = now()
    }

    /// Projects with an open run or a store this plugin cannot read, the most recently active first.
    var screenProjects: [Project] {
        projects
            .filter { $0.reading != .noOpenRun }
            .sorted { ($0.latest ?? .distantPast, $1.name) > ($1.latest ?? .distantPast, $0.name) }
    }

    /// The project the tiles show: the most recently active open run, else a store this plugin
    /// cannot read, so a tile never says there is no run when there is one it cannot read.
    var tileProject: Project? {
        let shown = screenProjects
        return shown.first { if case .open = $0.reading { true } else { false } } ?? shown.first
    }

    /// Scans off the main actor and publishes the result, unless a later refresh already did.
    /// `retryDiscovery` tries every Claude Code project that has not decoded to a store again;
    /// otherwise that happens at most once a minute.
    func refresh(retryDiscovery: Bool = false) async {
        requested += 1
        let generation = requested
        let date = now()
        let next = await scanner.scan(added: folders.added, removed: folders.removed, retryMisses: retryDiscovery, now: date)
        guard generation > published else { return }
        published = generation
        checkedAt = date
        if next != projects { projects = next }
    }

    func add(_ url: URL) async {
        folders.add(url)
        await refresh()
    }

    func remove(_ url: URL) async {
        folders.remove(url)
        await refresh()
    }

    func activate() {
        isActive = true
        Task { await refresh(retryDiscovery: true) }
        updatePolling()
    }

    func deactivate() {
        isActive = false
        updatePolling()
    }

    /// The screen or a tile appeared.
    func appeared() {
        shownCount += 1
        if shownCount == 1, isActive { Task { await refresh() } }
        updatePolling()
    }

    func disappeared() {
        shownCount = max(0, shownCount - 1)
        updatePolling()
    }

    private func updatePolling() {
        guard isActive, shownCount > 0 else {
            polling?.cancel()
            polling = nil
            return
        }
        guard polling == nil else { return }
        polling = Task { [weak self, interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
            }
        }
    }
}

/// Does the plugin's file system work off the main actor: decodes Claude Code's project folders,
/// stats the stores and rereads only those whose files changed modification time.
actor DStackScanner {
    /// How long a Claude Code project that did not decode to a store waits before the next try,
    /// unless an activation asks sooner.
    static let retryInterval: TimeInterval = 60

    private let discovery: ProjectDiscovery
    /// Claude Code projects that decoded to a folder with a store. Misses are not kept, so a folder
    /// that appears or becomes readable later is found on a retry.
    private var found: [String: URL] = [:]
    private var retriedAt: Date?
    private var readings: [String: (signature: String, reading: StoreReading)] = [:]

    init(discovery: ProjectDiscovery) {
        self.discovery = discovery
    }

    func scan(added: [String], removed: [String], retryMisses: Bool, now: Date) -> [DStackModel.Project] {
        let entries = discovery.entries()
        let listed = Set(entries)
        // A found folder that vanished or lost its store is dropped and becomes a miss again.
        found = found.filter { listed.contains($0.key) && DStackStore.hasStore($0.value) }
        if retryMisses || retriedAt.map({ now.timeIntervalSince($0) >= Self.retryInterval }) ?? true {
            retriedAt = now
            for entry in entries where found[entry] == nil {
                found[entry] = discovery.candidates(for: entry).first(where: DStackStore.hasStore)
            }
        }
        let discovered = entries.compactMap { found[$0] }
        let discoveredKeys = Set(discovered.map(ProjectFolders.key))
        var fresh: [String: (signature: String, reading: StoreReading)] = [:]
        let projects = ProjectFolders.resolve(discovered: discovered, added: added, removed: removed).map { url in
            let store = DStackStore(project: url)
            let signature = store.signature()
            let reading = readings[url.path].flatMap { $0.signature == signature ? $0.reading : nil } ?? store.read()
            fresh[url.path] = (signature, reading)
            return DStackModel.Project(url: url, reading: reading, isDiscovered: discoveredKeys.contains(url.path), hasStore: DStackStore.hasStore(url))
        }
        readings = fresh
        return projects
    }
}
