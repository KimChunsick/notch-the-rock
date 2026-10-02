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

    /// Projects with an open run that still has plans left or a store this plugin cannot read, the
    /// most recently active first. An open run whose plans are all done is left out like a closed
    /// one; settings still list it.
    var screenProjects: [Project] {
        projects
            .filter {
                switch $0.reading {
                case .open(let run): !run.isFinished
                case .unsupported: true
                case .noOpenRun: false
                }
            }
            .sorted { ($0.latest ?? .distantPast, $1.name) > ($1.latest ?? .distantPast, $0.name) }
    }

    /// The project the tiles show: the most recently active open run with plans left, else a store
    /// this plugin cannot read, so a tile never says there is no run when there is one it cannot read.
    var tileProject: Project? {
        let shown = screenProjects
        return shown.first { if case .open = $0.reading { true } else { false } } ?? shown.first
    }

    /// Whether some open run is left out because its plans are all done, so a tile without a project
    /// says finished runs are left out instead of suggesting another folder.
    var hasFinishedRun: Bool {
        projects.contains { if case .open(let run) = $0.reading { run.isFinished } else { false } }
    }

    /// Scans off the main actor and publishes the result, unless a later refresh already did.
    /// `retry` tries every Claude Code project that has not decoded to a store again and rereads
    /// every store that could not be read; otherwise that happens at most once a minute.
    func refresh(retry: Bool = false) async {
        requested += 1
        let generation = requested
        let date = now()
        let next = await scanner.scan(added: folders.added, removed: folders.removed, retry: retry, now: date)
        guard generation > published else { return }
        published = generation
        checkedAt = date
        if next != projects { projects = next }
    }

    /// Resolves the folder's symlinks off the main actor, then keeps the result in settings.
    func add(_ url: URL) async {
        let path = await scanner.key(url)
        folders.add(path)
        await refresh()
    }

    func remove(_ url: URL) async {
        let path = await scanner.key(url)
        folders.remove(path)
        await refresh()
    }

    func activate() {
        isActive = true
        Task { await refresh(retry: true) }
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

/// Does the plugin's file system work off the main actor: resolves the folders picked in settings,
/// decodes Claude Code's project folders, stats the stores and rereads those whose files changed
/// modification time.
actor DStackScanner {
    /// How long a Claude Code project that did not decode to a store, or a store that could not be
    /// read, waits before the next try, unless an activation asks sooner.
    static let retryInterval: TimeInterval = 60

    private let discovery: ProjectDiscovery
    /// Claude Code projects that decoded to a folder with a store. Misses are not kept, so a folder
    /// that appears or becomes readable later is found on a retry.
    private var found: [String: URL] = [:]
    private var retriedAt: Date?
    /// The last reading of each folder and the signature of the files it came from. A reading is
    /// reused while the signature stays the same, except that a store that could not be read is
    /// read again on every retry: access can come back without a modification time changing.
    private var readings: [String: (signature: String, reading: StoreReading)] = [:]

    init(discovery: ProjectDiscovery) {
        self.discovery = discovery
    }

    /// The path settings keep for a folder; resolving its symlinks touches the file system.
    func key(_ url: URL) -> String {
        ProjectFolders.key(url)
    }

    func scan(added: [String], removed: [String], retry requested: Bool, now: Date) -> [DStackModel.Project] {
        let entries = discovery.entries()
        let listed = Set(entries)
        // A found folder that vanished or lost its store is dropped and becomes a miss again.
        found = found.filter { listed.contains($0.key) && DStackStore.hasStore($0.value) }
        let retry = requested || retriedAt.map { now.timeIntervalSince($0) >= Self.retryInterval } ?? true
        if retry {
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
            var cached = readings[url.path].flatMap { $0.signature == signature ? $0.reading : nil }
            if retry, case .unsupported = cached { cached = nil }
            let reading = cached ?? store.read()
            fresh[url.path] = (signature, reading)
            return DStackModel.Project(url: url, reading: reading, isDiscovered: discoveredKeys.contains(url.path), hasStore: DStackStore.hasStore(url))
        }
        readings = fresh
        return projects
    }
}
