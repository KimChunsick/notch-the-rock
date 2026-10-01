import Testing
@testable import Volume

/// The one check against the real system, read-only: the default output device's volume. Nothing
/// is changed.
@MainActor
@Test func R12__live_default_output_reads() {
    let systemVolume = SystemVolume()
    let volume = systemVolume.defaultOutputDevice().flatMap { systemVolume.read($0) }
    print("default output: \(volume.map { "\(percentText($0.level)), muted \($0.isMuted), can mute \($0.canMute)" } ?? "volume cannot be set")")

    if let volume {
        #expect((0...1).contains(volume.level))
    }
}
