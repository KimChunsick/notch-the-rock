import AppKit

/// The app a copy came from, as an entry keeps it: the app's name and its bundle id, nothing else.
struct SourceApp: Codable, Hashable, Sendable {
    let name: String
    let bundleID: String?
}

/// How the history finds the app a copy came from; tests pass fakes.
struct SourceAppLookup {
    /// The app in front when a copy is recorded; nil when it is this app or has no name.
    var frontmost: @MainActor () -> SourceApp?
    /// The name of the app with a bundle id, nil when no such app is found.
    var appName: @MainActor (String) -> String?

    /// The nspasteboard.org marker an app puts next to what it copies, holding its bundle id.
    static let markerType = NSPasteboard.PasteboardType("org.nspasteboard.source")

    static var system: SourceAppLookup {
        SourceAppLookup(
            frontmost: {
                guard let app = NSWorkspace.shared.frontmostApplication, app != NSRunningApplication.current,
                      let name = app.localizedName
                else { return nil }
                return SourceApp(name: name, bundleID: app.bundleIdentifier)
            },
            appName: { bundleID in
                if let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName {
                    return name
                }
                return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?
                    .deletingPathExtension().lastPathComponent
            }
        )
    }

    /// The app `pasteboard` names as the source of its content, else the app in front. A marker
    /// naming an app that cannot be found keeps its bundle id as the name.
    @MainActor
    func source(of pasteboard: NSPasteboard) -> SourceApp? {
        if let bundleID = pasteboard.string(forType: Self.markerType)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleID.isEmpty {
            return SourceApp(name: appName(bundleID) ?? bundleID, bundleID: bundleID)
        }
        return frontmost()
    }
}
