import AppKit
import NotchKit

// Accessory app: no Dock icon, no menu bar icon; the notch window is the whole interface.
//
// Debugging: NOTCH_DEBUG_STATE=expanded or NOTCH_DEBUG_STATE=collapsed in the environment pins the
// notch in that state (the pointer and plugins cannot change it), so it can be captured without a
// mouse. Any other value, or none, leaves the notch to the pointer.
MainActor.assumeIsolated {
    NSLog("NotchTheRock starting with NotchKit SDK %@", NotchKitSDK.version.description)
    let pinnedExpansion: Bool? = switch ProcessInfo.processInfo.environment["NOTCH_DEBUG_STATE"] {
    case "expanded": true
    case "collapsed": false
    default: nil
    }
    let host = NotchHostModel(pinnedExpansion: pinnedExpansion)
    let window = NotchWindowController(host: host) {
        // The settings window arrives with the plugin loader.
        NSLog("NotchTheRock: settings are not available yet")
    }
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    window.show()
    application.run()
}
