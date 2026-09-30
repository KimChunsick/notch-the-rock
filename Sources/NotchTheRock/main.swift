import AppKit
import NotchKit
import OSLog

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
//
// First-launch onboarding (Onboarding/): shown once, after the greeting, until it is finished or its
// window is closed (defaults key `OnboardingCompleted` in com.notchtherock.NotchTheRock). Launch
// arguments for automation, e.g. `open /Applications/NotchTheRock.app --args --skip-onboarding`:
//   --skip-onboarding    no onboarding this launch; it is not marked completed
//   --reset-onboarding   clears the completed mark first, so this launch shows it again
// Both together leave a clean first-launch state without showing the window.
//
// Opening the app again while it runs (Finder, Spotlight, `open -a NotchTheRock`) brings the
// onboarding back to the front while this launch still shows it, and Settings otherwise: an
// accessory app has no Dock or menu bar icon to click instead.

/// The app's own lines in the unified log, where NSLog text is private:
/// `log show --predicate 'subsystem == "com.notchtherock.NotchTheRock"'`. Declared before the code
/// that uses it: main.swift initializes its globals in order.
let appLogger = Logger(subsystem: "com.notchtherock.NotchTheRock", category: "app")

MainActor.assumeIsolated {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.contains("--print-permissions") {
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
    let delegate = AppDelegate(settings: settings)
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
    for record in catalog.records {
        NSLog("NotchTheRock: plugin %@ (%@): %@", record.identifier ?? record.name, record.source.label, record.stateText)
    }
    NSLog("NotchTheRock: tabs %@", host.tabs.map(\.pluginID).joined(separator: ", "))

    let onboardingRecord = OnboardingRecord(defaults: .standard)
    if arguments.contains("--reset-onboarding") { appLogger.notice("onboarding reset by --reset-onboarding") }
    var onboarding: OnboardingWindowController?
    if onboardingRecord.showsAtLaunch(arguments: arguments) {
        // Plugins activate inside loadAll(), so the greeting takeover is already up here.
        onboarding = OnboardingWindowController(model: OnboardingModel(record: onboardingRecord))
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
    private let settings: SettingsWindowController
    /// This launch's onboarding, when it shows one.
    var onboarding: OnboardingWindowController?

    init(settings: SettingsWindowController) {
        self.settings = settings
    }

    /// Opening the running app again sends a reopen event, also to an accessory app. It is the way
    /// back to a window the user lost behind other apps.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        switch ReopenTarget(onboarding: onboarding?.model) {
        case .onboarding:
            appLogger.notice("reopened, bringing the onboarding to the front")
            onboarding?.bringForward()
        case .settings:
            appLogger.notice("reopened, bringing Settings to the front")
            settings.show()
        }
        return false
    }
}

/// What opening the running app again brings to the front.
enum ReopenTarget: Equatable {
    case onboarding
    case settings

    /// The onboarding while this launch still shows it, else Settings. A launch with
    /// `--skip-onboarding`, or one after the onboarding was completed, has none.
    @MainActor init(onboarding: OnboardingModel?) {
        self = onboarding?.isFinished == false ? .onboarding : .settings
    }
}
