import AppKit
import NotchKit

// Minimal accessory app (no Dock icon, no menu bar icon) so the bundle can be built, signed and
// launched. The notch window replaces this entry point.
MainActor.assumeIsolated {
    NSLog("NotchTheRock starting with NotchKit SDK %@", NotchKitSDK.version.description)
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    application.run()
}
