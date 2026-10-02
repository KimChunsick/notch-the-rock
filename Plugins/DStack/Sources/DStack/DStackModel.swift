import Foundation
import Observation

/// The projects the plugin shows and how it keeps them current: once on activation, and every
/// `interval` while the screen or a tile is shown. A refresh rereads a store only after one of its
/// files changed modification time.
@MainActor
@Observable
final class DStackModel {
    struct Project: Identifiable, Equatable {
        let url: URL
        let reading: StoreReading
        let isDiscovered: Bool
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

    @ObservationIgnored private let discovery: ProjectDiscovery
    @ObservationIgnored private let folders: ProjectFolders
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private var candidates: [String: [URL]] = [:]
    @ObservationIgnored private var cache: [String: (signature: String, reading: StoreReading)] = [:]
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var shownCount = 0
    @ObservationIgnored private var polling: Task<Void, Never>?

    init(discovery: ProjectDiscovery, folders: ProjectFolders, now: @escaping () -> Date, interval: Duration = .seconds(5)) {
        self.discovery = discovery
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

    func refresh() {
        let entries = discovery.entries()
        for entry in entries where candidates[entry] == nil {
            candidates[entry] = discovery.candidates(for: entry)
        }
        let discovered = entries.compactMap { candidates[$0]?.first(where: DStackStore.hasStore) }
        let discoveredKeys = Set(discovered.map(ProjectFolders.key))
        let urls = folders.resolve(discovered: discovered)
        var fresh: [String: (signature: String, reading: StoreReading)] = [:]
        let next = urls.map { url in
            let store = DStackStore(project: url)
            let signature = store.signature()
            let reading = cache[url.path].flatMap { $0.signature == signature ? $0.reading : nil } ?? store.read()
            fresh[url.path] = (signature, reading)
            return Project(url: url, reading: reading, isDiscovered: discoveredKeys.contains(url.path))
        }
        cache = fresh
        checkedAt = now()
        if next != projects { projects = next }
    }

    func add(_ url: URL) {
        folders.add(url)
        refresh()
    }

    func remove(_ url: URL) {
        folders.remove(url)
        refresh()
    }

    func activate() {
        isActive = true
        refresh()
        updatePolling()
    }

    func deactivate() {
        isActive = false
        updatePolling()
    }

    /// The screen or a tile appeared.
    func appeared() {
        shownCount += 1
        if shownCount == 1, isActive { refresh() }
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
                self.refresh()
            }
        }
    }
}
