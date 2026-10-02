import AppKit
import NotchKit
import OSLog

// Accessory app: no Dock icon, no menu bar icon; the notch window is the whole interface.
//
// `--print-permissions` prints `accessibility=trusted|untrusted` and
// `login-item=enabled|requiresApproval|notRegistered|notFound` to stdout and exits 0 without any UI.
// Started from a terminal, the terminal is the responsible process and `accessibility=` reports the
// terminal's grant, so one line on stderr says how to read the app's own through Launch Services:
// `open -n --stdout <file> -a /Applications/NotchTheRock.app --args --print-permissions`.
//
// Debugging: NOTCH_DEBUG_STATE=expanded or NOTCH_DEBUG_STATE=collapsed in the environment pins the
// notch in that state (the pointer and plugins cannot change it), so it can be captured without a
// mouse. Any other value, or none, leaves the notch to the pointer.
// NOTCH_DEBUG_CONSENT=<bundle path>, in debug builds only, does at launch what the 허락 and
// 다시 불러오기 buttons in Settings do for that user plugin, without clicking. The path is the listed
// one: ~/Library/Application Support/NotchTheRock/Plugins/<Name>.notchplugin with ~ expanded. Release
// builds (scripts/build-app.sh) ignore it: consent is given in Settings only.
// NOTCH_DEBUG_ONBOARDING_AUTOPLAY=<seconds>, in debug builds only, does what Enter does in the
// onboarding window every that many seconds until its last step, so every step can be captured
// without a keyboard. It never turns a permission or the login item on.
//
// First-launch onboarding (Onboarding/): shown once, after the greeting, until it is finished or its
// window is closed (defaults key `OnboardingCompleted` in com.notchtherock.NotchTheRock). Launch
// arguments for automation, e.g. `open /Applications/NotchTheRock.app --args --skip-onboarding`:
//   --skip-onboarding    no onboarding this launch; it is not marked completed
//   --reset-onboarding   clears the completed mark first, so this launch shows it again
// Both together leave a clean first-launch state without showing the window.
//
// Opening the app again while it runs (Finder, Spotlight, `open -a NotchTheRock`) brings Settings to
// the front, and this launch's onboarding too while its window is open and unfinished: an accessory
// app has no Dock or menu bar icon to click instead.
//
// Links (Links/): `notchtherock://open` opens the home, `notchtherock://open/<plugin-id>` a plugin's
// screen; the Raycast extension in Integrations/Raycast opens them. A link never opens Settings. One
// that launches the app waits until the plugins are loaded; the greeting still plays first and the
// linked screen shows when it ends, and onboarding follows its own rule above.

/// The app's own lines in the unified log, where NSLog text is private:
/// `log show --predicate 'subsystem == "com.notchtherock.NotchTheRock"'`. Declared before the code
/// that uses it: main.swift initializes its globals in order.
let appLogger = Logger(subsystem: "com.notchtherock.NotchTheRock", category: "app")

MainActor.assumeIsolated {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.contains("--print-permissions") {
        print(SystemPermissions.report)
        let note = "note: started from a terminal, accessibility= is the terminal's grant; "
            + "`open -n --stdout <file> -a /Applications/NotchTheRock.app --args --print-permissions` reads the app's own\n"
        FileHandle.standardError.write(Data(note.utf8))
        exit(0)
    }

    NSLog("NotchTheRock starting with NotchKit SDK %@", NotchKitSDK.version.description)
    let environment = ProcessInfo.processInfo.environment
    let pinnedExpansion: Bool? = switch environment["NOTCH_DEBUG_STATE"] {
    case "expanded": true
    case "collapsed": false
    default: nil
    }
    // Before the home and the catalog read what the user saved about the old volume and brightness plugin.
    MediaKeysSplit.migrate(.standard)
    let host = NotchHostModel(pinnedExpansion: pinnedExpansion)
    let catalog = PluginCatalog(host: host, locations: .standard)
    let settings = SettingsWindowController(catalog: catalog)
    let window = NotchWindowController(host: host, openSettings: { settings.show(pluginID: $0) })
    let links = LinkRouter(target: host)
    let delegate = AppDelegate(showSettings: { settings.show() }, links: links)
    let application = NSApplication.shared
    application.delegate = delegate
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
    links.pluginsDidLoad()
    for record in catalog.records {
        NSLog("NotchTheRock: plugin %@ (%@): %@", record.identifier ?? record.name, record.source.label, record.stateText)
    }
    NSLog("NotchTheRock: tabs %@", host.tabs.map(\.pluginID).joined(separator: ", "))

    let onboardingRecord = OnboardingRecord(defaults: .standard)
    if arguments.contains("--reset-onboarding") { appLogger.notice("onboarding reset by --reset-onboarding") }
    var onboarding: OnboardingWindowController?
    if onboardingRecord.showsAtLaunch(arguments: arguments) {
        // Plugins activate inside loadAll(), so the greeting takeover is already up here.
        // The setup steps of the plugins enabled now; the onboarding keeps them until it ends.
        onboarding = OnboardingWindowController(model: OnboardingModel(record: onboardingRecord, setups: catalog.setupSteps()))
        onboarding?.show(after: { host.takeover != nil })
    } else {
        appLogger.notice("onboarding not shown (\(onboardingRecord.isCompleted ? "completed" : "--skip-onboarding", privacy: .public))")
    }
    delegate.onboarding = onboarding
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { catalog.deactivateAll() }
    }
    application.run()
    // Unreachable; keeps the delegate (NSApplication holds it weakly) and the onboarding alive.
    withExtendedLifetime((delegate, onboarding)) {}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let showSettings: () -> Void
    private let links: LinkRouter
    /// This launch's onboarding, when it shows one.
    var onboarding: OnboardingWindowController?

    init(showSettings: @escaping () -> Void, links: LinkRouter) {
        self.showSettings = showSettings
        self.links = links
    }

    /// AppKit hands every `notchtherock://` URL here, the one that launches the app included. That
    /// event is dispatched only once `run()` has started, after the delegate is set, so it is not
    /// lost; the router holds it until the plugins are loaded. Links go to the notch only, never to
    /// Settings.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(links.receive)
    }

    /// Opening the running app again sends a reopen event, also to an accessory app. It is the way
    /// back to a window the user lost behind other apps.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // The onboarding window's delegate is its controller from the moment it opens until it closes.
        let onboardingWindowIsOpen = onboarding.map { controller in NSApp.windows.contains { $0.delegate === controller } } ?? false
        let windows = ReopenWindows.of(onboarding: onboarding?.model, onboardingWindowIsOpen: onboardingWindowIsOpen)
        showSettings()
        if windows.contains(.onboarding) {
            // After Settings, so the floating onboarding ends up on top.
            onboarding?.bringForward()
            appLogger.notice("reopened, bringing Settings and the unfinished onboarding to the front")
        } else {
            appLogger.notice("reopened, bringing Settings to the front")
        }
        return false
    }
}

/// The windows opening the running app again brings to the front, in order.
enum ReopenWindows: Equatable {
    case settings
    case onboarding

    /// Always Settings, then this launch's onboarding while its window is open and unfinished. A
    /// launch with `--skip-onboarding`, or one after the onboarding was completed, has none; during
    /// the greeting its window is not open yet and opens by itself when the greeting ends.
    @MainActor static func of(onboarding: OnboardingModel?, onboardingWindowIsOpen: Bool) -> [ReopenWindows] {
        onboarding?.isFinished == false && onboardingWindowIsOpen ? [.settings, .onboarding] : [.settings]
    }
}
