import Foundation
import NotchKit
import Observation
import OSLog
import SwiftUI

/// Where plugins are found and where their data lives.
struct PluginLocations {
    /// `NotchTheRock.app/Contents/PlugIns`: built-in plugins, trusted as part of the signed app.
    let builtIn: URL?
    /// `~/Library/Application Support/NotchTheRock/Plugins`: the user's plugins, run only with consent.
    let user: URL
    /// The app's copies of consented user bundles, the ones that load: see `PluginSnapshots`.
    let cache: URL
    /// Each plugin's data directory is `<data>/<key>/`, with the plugin's `PluginKey`.
    let data: URL
    /// Each plugin's defaults suite and keychain service is `<storagePrefix>.<key>`.
    let storagePrefix: String

    static var standard: PluginLocations {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchTheRock")
        return PluginLocations(
            builtIn: Bundle.main.builtInPlugInsURL,
            user: support.appendingPathComponent("Plugins"),
            cache: support.appendingPathComponent("PluginCache"),
            data: support.appendingPathComponent("PluginData"),
            storagePrefix: "com.notchtherock.NotchTheRock.plugin"
        )
    }
}

/// A plugin's identity wherever the host keys by it: who owns the identifier, the consent, the
/// disabled list, the app's copy, and the data directory, defaults suite and keychain service.
/// Identifiers that differ only in case are one plugin, because the default file system ignores
/// case and directories named after them would be one directory. Identifiers are ASCII
/// (`PluginManifest.isValidIdentifier`), so lowercasing is exact. The running plugin, its tab and
/// what it shows keep the identifier as written.
struct PluginKey: Hashable {
    let rawValue: String

    init(_ identifier: String) {
        rawValue = identifier.lowercased()
    }
}

/// A discovered `.notchplugin` bundle as Settings lists it.
struct PluginRecord: Identifiable {
    enum Source {
        case builtIn
        case user
    }

    enum State: Equatable {
        case on
        case off
        /// A user bundle the user has not allowed (or that changed since); the reason says which.
        case needsConsent(String)
        case failed(String)
    }

    /// Where the bundle was found. A user bundle loads from the app's copy of it, never from here.
    let bundleURL: URL
    let source: Source
    /// `CFBundleIdentifier`, nil when the Info.plist could not be read.
    let identifier: String?
    let name: String
    let version: String
    /// What the user allows when they consent; nil for built-in bundles.
    let fingerprint: String?
    var state: State
    /// The bundle changed or disappeared after its code was loaded. Loaded code cannot be unloaded,
    /// so the change applies at the next launch.
    var needsRestart = false

    var id: String { bundleURL.path }
    var key: PluginKey? { identifier.map(PluginKey.init) }
}

/// Opens a checked bundle's code and returns its manifest and principal class.
typealias PluginOpener = @MainActor (PluginBundleInfo) throws -> (manifest: PluginManifest, type: any NotchPlugin.Type)

/// Finds, checks, loads and runs plugins, and owns whether each one is on. Built-in and user bundles
/// go through the same `evaluate` path: the SDK version is checked from Info.plist, user bundles
/// also need a consent pinned to their fingerprint and load from the app's copy with that
/// fingerprint, then `PluginLoader` opens the code. Built-in bundles are part of the signed app and
/// load in place. Disabled bundles are not opened at all.
@MainActor
@Observable
final class PluginCatalog {
    static let disabledKey = "DisabledPlugins"
    static let unknownReason = "처음 보는 사용자 플러그인이에요. 허락하면 불러와요."
    static let changedReason = "허락한 뒤로 번들 내용이 바뀌었어요. 다시 허락해야 불러와요."

    private(set) var records: [PluginRecord] = []

    /// A loaded plugin with what the home shows of it: the manifest's name and symbol, and the tab
    /// and tile read once when it loaded.
    private struct Running {
        let pluginID: String
        let manifest: PluginManifest
        let plugin: any NotchPlugin
        let tab: PluginTab?
        let tile: PluginTile?
        var isEnabled: Bool
    }

    @ObservationIgnored private let host: NotchHostModel
    @ObservationIgnored let locations: PluginLocations
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let consents: PluginConsentStore
    @ObservationIgnored private let snapshots: PluginSnapshots
    @ObservationIgnored private let open: PluginOpener
    /// Loaded plugins by record id, and the order they were loaded in (the home's order).
    @ObservationIgnored private var running: [String: Running] = [:]
    @ObservationIgnored private var loadOrder: [String] = []
    /// Fingerprints of user bundles whose code is in the process, loaded or failed after opening.
    @ObservationIgnored private var openedFingerprints: [String: String] = [:]
    @ObservationIgnored private let logger = Logger(subsystem: "com.notchtherock.NotchTheRock", category: "host")

    init(
        host: NotchHostModel,
        locations: PluginLocations,
        defaults: UserDefaults = .standard,
        open: @escaping PluginOpener = { info in
            let loaded = try PluginLoader.load(info)
            return (loaded.manifest, loaded.pluginType)
        }
    ) {
        self.host = host
        self.locations = locations
        self.defaults = defaults
        consents = PluginConsentStore(defaults: defaults)
        snapshots = PluginSnapshots(cache: locations.cache)
        self.open = open
    }

    // MARK: Actions

    /// Lists built-in then user bundles and starts every allowed, enabled one. Called once at launch,
    /// before any copy is loaded, so the copies of bundles no longer in the user folder go here.
    func loadAll() {
        let user = Self.bundles(in: locations.user)
        snapshots.prune(keeping: Set(user.compactMap { try? PluginKey(PluginBundleInfo(contentsOf: $0).identifier) }))
        for url in Self.bundles(in: locations.builtIn) {
            records.append(evaluate(url, source: .builtIn))
        }
        for url in user {
            records.append(evaluate(url, source: .user))
        }
    }

    /// Reads the user folder again. New or not yet loaded bundles are checked from scratch; a
    /// loaded bundle that changed or disappeared is marked `needsRestart` and keeps running.
    func reload() {
        let present = Self.bundles(in: locations.user)
        let presentPaths = Set(present.map(\.path))
        var kept = records.filter { $0.source == .builtIn }
        for var record in records where record.source == .user {
            guard let opened = openedFingerprints[record.id] else { continue }
            record.needsRestart = !presentPaths.contains(record.id)
                || (try? PluginFingerprint.of(record.bundleURL)) != opened
            kept.append(record)
        }
        records = kept
        for url in present where !records.contains(where: { $0.id == url.path }) {
            records.append(evaluate(url, source: .user))
        }
        logger.notice("reloaded \(self.locations.user.path, privacy: .public)")
    }

    /// Allows the user bundle `id` as it was listed and loads it when it is enabled. The bundle is
    /// copied into the app first, and the copy is what the consent pins and what loads. Refused when
    /// the bundle changed after it was listed; the record is then checked again.
    func consent(to id: PluginRecord.ID) throws {
        guard let index = records.firstIndex(where: { $0.id == id }),
              let key = records[index].key,
              let fingerprint = records[index].fingerprint,
              records[index].source == .user,
              case .needsConsent = records[index].state
        else { return }
        let record = records[index]
        do {
            _ = try snapshots.prepare(record.bundleURL, key: key, fingerprint: fingerprint)
        } catch is SnapshotMismatch {
            records[index] = evaluate(record.bundleURL, source: .user)
            throw ConsentFailure("목록을 읽은 뒤로 번들 내용이 바뀌었어요. 바뀐 번들을 확인하고 다시 허락해 주세요.")
        } catch {
            throw ConsentFailure(Self.reason(error))
        }
        consents.pin(key, fingerprint: fingerprint)
        logger.notice("consented to \(key.rawValue, privacy: .public) at \(record.id, privacy: .public)")
        records[index] = evaluate(record.bundleURL, source: .user)
    }

    /// Turns a listed plugin on or off and remembers it across launches. Turning off calls
    /// `deactivate()` and takes it out of the home with everything it shows; turning on activates it
    /// again, loading it first when it was never loaded. A refused bundle does not own its
    /// identifier, so it cannot turn off the plugin that does.
    func setEnabled(_ enabled: Bool, for id: PluginRecord.ID) {
        guard let index = records.firstIndex(where: { $0.id == id }),
              let key = records[index].key
        else { return }
        if case .failed = records[index].state { return }
        var disabled = Set(defaults.stringArray(forKey: Self.disabledKey) ?? [])
        if enabled { disabled.remove(key.rawValue) } else { disabled.insert(key.rawValue) }
        defaults.set(disabled.sorted(), forKey: Self.disabledKey)

        switch (enabled, records[index].state) {
        case (true, .off):
            if running[id] != nil {
                activate(id)
                records[index].state = .on
            } else {
                let needsRestart = records[index].needsRestart
                records[index] = evaluate(records[index].bundleURL, source: records[index].source)
                records[index].needsRestart = needsRestart
            }
        case (false, .on):
            deactivate(id)
            records[index].state = .off
        default:
            break
        }
    }

    /// The record of the bundle running as `pluginID`, matched as the host keys plugins
    /// (`PluginKey`); nil when none is on. An earlier bundle refused with the same identifier is
    /// listed too but does not own it (`evaluate`).
    func runningRecord(for pluginID: String) -> PluginRecord.ID? {
        records.first { $0.key == PluginKey(pluginID) && $0.state == .on }?.id
    }

    /// The plugin's own Settings page while it is on.
    func settingsView(for id: PluginRecord.ID) -> AnyView? {
        guard let running = running[id], running.isEnabled else { return nil }
        return running.plugin.settingsView
    }

    /// Deactivates every running plugin; the app is quitting.
    func deactivateAll() {
        for id in loadOrder where running[id]?.isEnabled == true {
            running[id]?.plugin.deactivate()
        }
    }

    // MARK: Checking and loading

    private func evaluate(_ bundleURL: URL, source: PluginRecord.Source) -> PluginRecord {
        let plist = NSDictionary(contentsOf: bundleURL.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        var identifier: String?
        var fingerprint: String?
        func record(_ state: PluginRecord.State) -> PluginRecord {
            switch state {
            case .on: logger.notice("\(bundleURL.path, privacy: .public): on")
            case .off: logger.notice("\(bundleURL.path, privacy: .public): off")
            case .needsConsent(let reason): logger.notice("\(bundleURL.path, privacy: .public): needs consent: \(reason, privacy: .public)")
            case .failed(let reason): logger.error("\(bundleURL.path, privacy: .public): refused: \(reason, privacy: .public)")
            }
            return PluginRecord(
                bundleURL: bundleURL,
                source: source,
                identifier: identifier,
                name: plist?["CFBundleName"] as? String ?? bundleURL.deletingPathExtension().lastPathComponent,
                version: plist?["CFBundleShortVersionString"] as? String ?? "-",
                fingerprint: fingerprint,
                state: state
            )
        }

        let info: PluginBundleInfo
        do {
            info = try PluginBundleInfo(contentsOf: bundleURL)
        } catch {
            return record(.failed(Self.reason(error)))
        }
        identifier = info.identifier
        let key = PluginKey(info.identifier)
        // The host keys tabs, activities, storage and consent by identifier; the first bundle listed
        // that is not refused keeps it, with every spelling of it in other case (`PluginKey`).
        // Built-in bundles are listed first, so they keep theirs.
        if let other = records.first(where: { record in
            guard record.key == key, record.id != bundleURL.path else { return false }
            if case .failed = record.state { return false }
            return true
        }) {
            return record(.failed("같은 식별자(\(info.identifier))를 쓰는 플러그인이 이미 있어요: \(other.id)"))
        }
        // Checked from Info.plist before consent: allowing a bundle this app cannot run helps nobody.
        guard NotchKitSDK.version.supports(info.sdkVersion) else {
            return record(.failed(PluginLoadError.incompatibleSDK(required: info.sdkVersion, host: NotchKitSDK.version).description))
        }
        if source == .user {
            do {
                fingerprint = try PluginFingerprint.of(bundleURL)
            } catch {
                return record(.failed(Self.reason(error)))
            }
            switch consents.decision(for: key, fingerprint: fingerprint ?? "") {
            case .unknown: return record(.needsConsent(Self.unknownReason))
            case .changed: return record(.needsConsent(Self.changedReason))
            case .consented: break
            }
        }
        if defaults.stringArray(forKey: Self.disabledKey)?.contains(key.rawValue) == true {
            return record(.off)
        }

        // Only user bundles have a fingerprint; they load from the app's copy that has it.
        var loadable = info
        if let fingerprint {
            do {
                loadable = try snapshots.prepare(bundleURL, key: key, fingerprint: fingerprint)
            } catch is SnapshotMismatch {
                return record(.needsConsent(Self.changedReason))
            } catch {
                return record(.failed(Self.reason(error)))
            }
        }
        let storage: PluginStorage
        do {
            storage = try PluginStorage(
                directory: locations.data.appendingPathComponent(key.rawValue),
                defaultsSuiteName: "\(locations.storagePrefix).\(key.rawValue)",
                keychainService: "\(locations.storagePrefix).\(key.rawValue)"
            )
        } catch {
            return record(.failed("플러그인 데이터 폴더를 만들지 못했어요: \(Self.reason(error))"))
        }
        let opened: (manifest: PluginManifest, type: any NotchPlugin.Type)
        do {
            opened = try open(loadable)
        } catch {
            if let fingerprint, Self.codeWasOpened(before: error) {
                openedFingerprints[bundleURL.path] = fingerprint
            }
            return record(.failed(Self.reason(error)))
        }
        if let fingerprint { openedFingerprints[bundleURL.path] = fingerprint }
        let context = NotchContext(pluginID: info.identifier, bundleURL: loadable.bundleURL, host: host, storage: storage)
        let plugin = opened.type.init(context: context)
        running[bundleURL.path] = Running(
            pluginID: info.identifier,
            manifest: opened.manifest,
            plugin: plugin,
            tab: plugin.expandedTab,
            tile: plugin.tile,
            isEnabled: false
        )
        loadOrder.append(bundleURL.path)
        logger.notice("loaded \(info.identifier, privacy: .public) \(opened.manifest.version, privacy: .public) from \(loadable.bundleURL.path, privacy: .public)")
        activate(bundleURL.path)
        return record(.on)
    }

    /// The plugin joins the home before `activate()`, so it can expand to its own tab right away.
    private func activate(_ id: String) {
        guard var entry = running[id], !entry.isEnabled else { return }
        entry.isEnabled = true
        running[id] = entry
        updateHome()
        entry.plugin.activate()
        logger.notice("activated \(entry.pluginID, privacy: .public)")
    }

    private func deactivate(_ id: String) {
        guard var entry = running[id], entry.isEnabled else { return }
        entry.isEnabled = false
        running[id] = entry
        updateHome()
        entry.plugin.deactivate()
        host.withdraw(from: entry.pluginID)
        logger.notice("deactivated \(entry.pluginID, privacy: .public)")
    }

    /// Hands the host every running, enabled plugin in load order. The home leaves out the ones with
    /// neither a tab nor a tile (`HomePlugin.isInHome`).
    private func updateHome() {
        host.plugins = loadOrder.compactMap { id in
            guard let entry = running[id], entry.isEnabled else { return nil }
            return HomePlugin(
                pluginID: entry.pluginID,
                name: entry.manifest.name,
                symbol: entry.manifest.symbol,
                tab: entry.tab,
                tile: entry.tile,
                hasSettings: entry.plugin.settingsView != nil
            )
        }
    }

    // MARK: Helpers

    /// `.notchplugin` bundles directly in `folder`, by name; none when the folder is missing. The
    /// URLs keep `folder` as given (no symlink resolution), so a record's id stays the same path
    /// every time the folder is read.
    private static func bundles(in folder: URL?) -> [URL] {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names
            .filter { $0.hasSuffix(".notchplugin") }
            .sorted()
            .map { folder.appendingPathComponent($0) }
    }

    /// Whether `PluginLoader.load` had already opened the binary, so its code is in the process,
    /// when it threw `error`. The SDK version in Info.plist is checked before the loader runs.
    private static func codeWasOpened(before error: Error) -> Bool {
        switch error as? PluginLoadError {
        case .openFailed?, .executableOutsideBundle?: false
        default: true
        }
    }

    private static func reason(_ error: Error) -> String {
        switch error {
        case let error as PluginLoadError: error.description
        case let error as ConsentFailure: error.description
        default: error.localizedDescription
        }
    }
}
