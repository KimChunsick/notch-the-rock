import AppKit
import NotchKit

// Accessory app: no Dock icon, no menu bar icon; the notch window is the whole interface.
//
// `--print-permissions` prints `accessibility=trusted|untrusted` and
// `login-item=enabled|requiresApproval|notRegistered|notFound` to stdout and exits 0 without any UI.
//
// Debugging: NOTCH_DEBUG_STATE=expanded or NOTCH_DEBUG_STATE=collapsed in the environment pins the
// notch in that state (the pointer and plugins cannot change it), so it can be captured without a
// mouse. Any other value, or none, leaves the notch to the pointer.
// NOTCH_DEBUG_CONSENT=<bundle path>, in debug builds only, does at launch what the 허락 and
// 다시 불러오기 buttons in Settings do for that user plugin, without clicking. The path is the listed
// one: ~/Library/Application Support/NotchTheRock/Plugins/<Name>.notchplugin with ~ expanded. Release
// builds (scripts/build-app.sh) ignore it: consent is given in Settings only.
MainActor.assumeIsolated {
    if CommandLine.arguments.dropFirst().contains("--print-permissions") {
        print(SystemPermissions.report)
        exit(0)
    }

    NSLog("NotchTheRock starting with NotchKit SDK %@", NotchKitSDK.version.description)
    let environment = ProcessInfo.processInfo.environment
    let pinnedExpansion: Bool? = switch environment["NOTCH_DEBUG_STATE"] {
    case "expanded": true
    case "collapsed": false
    default: nil
    }
    let host = NotchHostModel(pinnedExpansion: pinnedExpansion)
    let catalog = PluginCatalog(host: host, locations: .standard)
    let settings = SettingsWindowController(catalog: catalog)
    let window = NotchWindowController(host: host, openSettings: { settings.show() })
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    window.show()

    catalog.loadAll()
    #if DEBUG
    if let path = environment["NOTCH_DEBUG_CONSENT"] {
        do {
            try catalog.consent(to: path)
        } catch {
            NSLog("NotchTheRock: NOTCH_DEBUG_CONSENT refused for %@: %@", path, "\(error)")
        }
        catalog.reload()
    }
    #endif
    for record in catalog.records {
        NSLog("NotchTheRock: plugin %@ (%@): %@", record.identifier ?? record.name, record.source.label, record.stateText)
    }
    NSLog("NotchTheRock: tabs %@", host.tabs.map(\.pluginID).joined(separator: ", "))
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { catalog.deactivateAll() }
    }
    application.run()
}
