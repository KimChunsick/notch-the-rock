import Testing
@testable import Brightness

/// `data1` of real key events: key code << 16 | state << 8 | repeat flag.
@Test func R12__data1_decodes_into_key_state_and_repeat() {
    let aux = MediaKeyPress.auxControlButtonsSubtype
    #expect(MediaKeyPress(subtype: aux, data1: 0x02_0A00) == MediaKeyPress(key: .brightnessUp, state: .down, isRepeat: false))
    #expect(MediaKeyPress(subtype: aux, data1: 0x03_0A00) == MediaKeyPress(key: .brightnessDown, state: .down, isRepeat: false))
    #expect(MediaKeyPress(subtype: aux, data1: 0x02_0B00) == MediaKeyPress(key: .brightnessUp, state: .up, isRepeat: false))
    #expect(MediaKeyPress(subtype: aux, data1: 0x02_0A01) == MediaKeyPress(key: .brightnessUp, state: .down, isRepeat: true))

    // The volume and mute keys (0, 1 and 7) belong to the volume plugin.
    for volume in [0, 1, 7] {
        #expect(MediaKeyPress(subtype: aux, data1: volume << 16 | 0x0A00) == nil)
    }
    #expect(MediaKeyPress(subtype: aux, data1: 0x03_0B00) == MediaKeyPress(key: .brightnessDown, state: .up, isRepeat: false))

    // Play/pause, next, previous, fast-forward and rewind (16–20) belong to another plugin.
    for transport in 16...20 {
        #expect(MediaKeyPress(subtype: aux, data1: transport << 16 | 0x0A00) == nil)
        #expect(MediaKeyPress(subtype: aux, data1: transport << 16 | 0x0B00) == nil)
    }
    #expect(MediaKeyPress(subtype: aux, data1: 0x0A_0A00) == nil)  // NX_KEYTYPE_EJECT
    #expect(MediaKeyPress(subtype: 7, data1: 0x02_0A00) == nil)    // another subtype
    #expect(MediaKeyPress(subtype: aux, data1: 0x02_0C00) == nil)  // neither down nor up
}

@Test func R12__steps_snap_to_the_grid_and_clamp_at_0_and_1() {
    #expect(BrightnessModel.stepped(0.5, by: 1, steps: 16) == 0.5625)
    #expect(BrightnessModel.stepped(0.5, by: -1, steps: 16) == 0.4375)
    #expect(BrightnessModel.stepped(0.52, by: 1, steps: 16) == 0.5625)   // off the grid: snaps first
    #expect(BrightnessModel.stepped(0.5, by: 1, steps: 64) == 0.515625)  // ⌥⇧ quarter step
    #expect(BrightnessModel.stepped(15.0 / 16, by: 1, steps: 16) == 1)
    #expect(BrightnessModel.stepped(1, by: 1, steps: 16) == 1)
    #expect(BrightnessModel.stepped(1.0 / 16, by: -1, steps: 16) == 0)
    #expect(BrightnessModel.stepped(0, by: -1, steps: 16) == 0)
}
