import Testing
@testable import MediaKeys

/// The one check against the real system, read-only: the default output device's volume and the
/// DisplayServices functions resolved with `dlopen`. Nothing is changed.
@MainActor
@Test func R12__live_default_output_reads_and_display_services_resolve() {
    let systemVolume = SystemVolume()
    let volume = systemVolume.defaultOutputDevice().flatMap { systemVolume.read($0) }
    let displayServices = DisplayServicesBrightness()
    let brightness = displayServices.read()
    print("default output: \(volume.map { "\(percentText($0.level)), muted \($0.isMuted), can mute \($0.canMute)" } ?? "volume cannot be set")")
    print("built-in display: \(brightness.map(percentText) ?? "brightness cannot be changed")")

    if let volume {
        #expect((0...1).contains(volume.level))
    }
    #expect(displayServices.isResolved)
}
