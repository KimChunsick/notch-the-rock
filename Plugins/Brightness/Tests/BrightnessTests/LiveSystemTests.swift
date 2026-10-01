import Testing
@testable import Brightness

/// The one check against the real system, read-only: the DisplayServices functions resolved with
/// `dlopen` and the built-in display's brightness. Nothing is changed.
@MainActor
@Test func R12__live_display_services_resolve() {
    let displayServices = DisplayServicesBrightness()
    let brightness = displayServices.read()
    print("built-in display: \(brightness.map(percentText) ?? "brightness cannot be changed")")

    #expect(displayServices.isResolved)
}
