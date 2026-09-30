import AudioToolbox
import CoreAudio

/// The default output device's level and mute switch.
struct VolumeState: Equatable, Sendable {
    /// From 0 to 1.
    var level: Double
    var isMuted: Bool
    /// Whether the device has a mute switch the app can set.
    var canMute: Bool
}

/// The volume of the default output device. The plugin uses `SystemVolume`; tests use a fake so
/// they never touch the user's volume.
@MainActor
protocol VolumeControl: AnyObject {
    /// The current state, or nil when there is no default output device or its volume cannot be set.
    func read() -> VolumeState?
    /// Best effort: a device that refuses keeps its value, and the next `read()` shows it.
    func setLevel(_ level: Double)
    func setMuted(_ muted: Bool)
}

/// The default output device through CoreAudio: AudioToolbox's `VirtualMainVolume` for the level,
/// read and set with the `AudioObject` calls that replaced the deprecated `AudioHardwareService`
/// ones, and `kAudioDevicePropertyMute` for the mute switch. The device is looked up on every call,
/// so a new default output (headphones plugged in) applies from the next key press.
final class SystemVolume: VolumeControl {
    private static let volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    func read() -> VolumeState? {
        guard let device = Self.defaultOutputDevice() else { return nil }
        var volumeAddress = Self.volumeAddress
        var volumeSettable: DarwinBoolean = false
        var level: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(device, &volumeAddress),
              AudioObjectIsPropertySettable(device, &volumeAddress, &volumeSettable) == noErr,
              volumeSettable.boolValue,
              AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &level) == noErr
        else { return nil }

        var muteAddress = Self.muteAddress
        var muteSettable: DarwinBoolean = false
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        let hasMute = AudioObjectHasProperty(device, &muteAddress)
            && AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &muted) == noErr
        let canMute = hasMute
            && AudioObjectIsPropertySettable(device, &muteAddress, &muteSettable) == noErr
            && muteSettable.boolValue
        return VolumeState(level: Double(min(max(level, 0), 1)), isMuted: hasMute && muted != 0, canMute: canMute)
    }

    func setLevel(_ level: Double) {
        guard let device = Self.defaultOutputDevice() else { return }
        var address = Self.volumeAddress
        var value = Float32(min(max(level, 0), 1))
        _ = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    func setMuted(_ muted: Bool) {
        guard let device = Self.defaultOutputDevice() else { return }
        var address = Self.muteAddress
        var value: UInt32 = muted ? 1 : 0
        _ = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }
}
