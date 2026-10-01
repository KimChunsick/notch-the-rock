import Foundation
import Testing
@testable import NowPlaying

/// A full line gives every field and the image; a partial one leaves out what the app did not say;
/// `none` and `unavailable` are their own cases; `artwork: null` removes the image.
@Test func R08__helper_lines_parse_full_partial_nothing_and_unavailable() throws {
    let png = samplePNG()
    let full = try #require(HelperLine(infoLine(artwork: artworkObject(png))))
    #expect(full == .info(
        TrackInfo(
            title: "Blue in Green", artist: "Miles Davis", album: "Kind of Blue", duration: 337.5, elapsed: 12,
            sampledAt: Date(timeIntervalSince1970: 1_790_000_000), rate: 1, isPlaying: true, bundleID: "com.apple.Music"
        ),
        artwork: .image(png, mime: "image/png")
    ))

    let partial = try #require(HelperLine(#"{"type":"info","title":"Live stream","timestamp":1790000100.25,"playing":false}"#))
    #expect(partial == .info(
        TrackInfo(title: "Live stream", sampledAt: Date(timeIntervalSince1970: 1_790_000_100.25), isPlaying: false),
        artwork: .unchanged
    ))

    #expect(HelperLine(infoLine(artwork: NSNull())).map(artworkOf) == .removed)
    #expect(HelperLine(#"{"type":"none"}"#) == .nothing)
    #expect(HelperLine(#"{"type":"unavailable","reason":"cannot load MediaRemote"}"#) == .unavailable(reason: "cannot load MediaRemote"))
    // The perl driver's own line for a library it cannot load.
    #expect(HelperLine(#"{"type":"unavailable","reason":"cannot load /x/lib.dylib: dlopen(\"/x\") failed"}"#)
        == .unavailable(reason: #"cannot load /x/lib.dylib: dlopen("/x") failed"#))
}

private func artworkOf(_ line: HelperLine) -> ArtworkUpdate? {
    if case .info(_, let artwork) = line { artwork } else { nil }
}

/// Anything that is not a line of the format is ignored: not JSON, no or an unknown type, an info
/// line without its title, time or playing flag, fields of the wrong type, artwork that is not
/// base64.
@Test(arguments: [
    "",
    "Now Playing",
    "{\"type\":\"info\"",
    "[1,2,3]",
    #"{"title":"No type","timestamp":1,"playing":true}"#,
    #"{"type":"paused"}"#,
    #"{"type":"info","timestamp":1,"playing":true}"#,
    #"{"type":"info","title":"No time","playing":true}"#,
    #"{"type":"info","title":"No flag","timestamp":1}"#,
    #"{"type":"info","title":7,"timestamp":1,"playing":true}"#,
    #"{"type":"info","title":"Bad art","timestamp":1,"playing":true,"artwork":{"data":"not base64!"}}"#,
    #"{"type":"info","title":"Bad art","timestamp":1,"playing":true,"artwork":"abc"}"#,
])
func R08__malformed_lines_are_ignored(line: String) {
    #expect(HelperLine(line) == nil)
}

/// While playing, the elapsed time moves on from the helper's sample at the playback rate; paused it
/// stays. It never leaves the item, and without an elapsed time there is no progress.
@Test func R08__elapsed_time_advances_from_the_sample_while_playing() {
    let sampled = Date(timeIntervalSince1970: 1_790_000_000)
    let playing = TrackInfo(title: "t", duration: 200, elapsed: 30, sampledAt: sampled, rate: 1, isPlaying: true)
    #expect(playing.elapsed(at: sampled) == 30)
    #expect(playing.elapsed(at: sampled + 12.5) == 42.5)
    #expect(playing.progress(at: sampled + 70) == 0.5)
    #expect(playing.elapsed(at: sampled + 1000) == 200)
    #expect(playing.progress(at: sampled + 1000) == 1)

    var fast = playing
    fast.rate = 2
    #expect(fast.elapsed(at: sampled + 10) == 50)

    var unknownRate = playing
    unknownRate.rate = nil
    #expect(unknownRate.elapsed(at: sampled + 10) == 40)

    var paused = playing
    paused.isPlaying = false
    paused.rate = 0
    #expect(paused.elapsed(at: sampled + 60) == 30)

    // A sample taken a little in the future of this Mac's clock does not go below zero.
    let early = TrackInfo(title: "t", duration: 200, elapsed: 0.5, sampledAt: sampled, rate: 1, isPlaying: true)
    #expect(early.elapsed(at: sampled - 2) == 0)

    let live = TrackInfo(title: "t", elapsed: 30, sampledAt: sampled, rate: 1, isPlaying: true)
    #expect(live.elapsed(at: sampled + 5) == 35)
    #expect(live.progress(at: sampled + 5) == nil)
    #expect(TrackInfo(title: "t", duration: 200, sampledAt: sampled, isPlaying: true).elapsed(at: sampled) == nil)

    #expect(timeText(0) == "0:00")
    #expect(timeText(7.9) == "0:07")
    #expect(timeText(187) == "3:07")
    #expect(timeText(3723) == "1:02:03")
}

/// Play/pause asks for the state the button shows, and every command reaches the helper as
/// `/usr/bin/perl -e <driver> -- <library> send <command>`. (That the driver calls the matching entry
/// point is checked with real perl runs in NowPlayingPluginTests.)
@Test func R08__commands_map_to_helper_runs() {
    let sampled = Date(timeIntervalSince1970: 0)
    #expect(TrackInfo(title: "t", sampledAt: sampled, isPlaying: true).playPauseCommand == .pause)
    #expect(TrackInfo(title: "t", sampledAt: sampled, isPlaying: false).playPauseCommand == .play)

    let library = URL(fileURLWithPath: "/Applications/NotchTheRock.app/Contents/PlugIns/NowPlaying.notchplugin/Contents/Helpers/libNowPlayingBridge.dylib")
    for command in NowPlayingCommand.allCases {
        let run = HelperCommand.send(command, library: library)
        #expect(run.executable.path == "/usr/bin/perl")
        #expect(run.arguments == ["-e", HelperCommand.driver, "--", library.path, "send", command.rawValue])
    }
    #expect(NowPlayingCommand.allCases.map(\.rawValue) == ["play", "pause", "toggle", "next", "previous"])
    #expect(HelperCommand.stream(library: library).arguments == ["-e", HelperCommand.driver, "--", library.path, "stream"])
    #expect(URL(fileURLWithPath: "/b/NowPlaying.notchplugin").appendingPathComponent(HelperCommand.libraryPath).path
        == "/b/NowPlaying.notchplugin/Contents/Helpers/libNowPlayingBridge.dylib")
}
