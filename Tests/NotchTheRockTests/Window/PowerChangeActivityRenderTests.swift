import AppKit
import Foundation
import NotchKit
import SwiftUI
import Testing
@testable import NotchTheRock

/// Battery's power-change activity on the collapsed notch, through the app's own host model and
/// root view. The root package cannot import the plugins, so Battery's posts are the views it
/// builds and NowPlaying's are the stand-ins `NotchActivityRenderTests` draws, under their plugin ids.
@MainActor
struct PowerChangeActivityRenderTests {
    static let battery = "com.notchtherock.battery"
    static let nowPlaying = "com.notchtherock.nowplaying"

    let clock = ManualClock()
    let host: NotchHostModel

    init() {
        let clock = clock
        // An hour past the real clock: the host's own expiry task sleeps on the real clock, so it
        // never ends an activity during a capture; only `expire()` below does.
        clock.advance(by: .seconds(3600))
        host = NotchHostModel(now: { clock.now })
    }

    /// Battery's post while charging: a green bolt and the percentage.
    func battery(_ id: String, priority: Int = 0, expiresAfter: Duration? = nil, percentage: String) -> LiveActivity {
        LiveActivity(id: id, priority: priority, expiresAfter: expiresAfter) {
            Image(systemName: "battery.100percent.bolt").symbolRenderingMode(.hierarchical).foregroundStyle(.green)
        } trailing: {
            Text(percentage).monospacedDigit()
        }
    }

    /// Plugging in: Battery posts the power change, then the always-on charging activity.
    func plugIn(percentage: String) {
        host.post(battery("power-change", priority: 100, expiresAfter: .milliseconds(2500), percentage: percentage), from: Self.battery)
        host.post(battery("charging", percentage: percentage), from: Self.battery)
    }

    /// NowPlaying's wings while something plays: the 22 pt album art and the 18 x 14 pt bars.
    func play() {
        host.post(LiveActivity(id: "now-playing", priority: 100) {
            Color.white.frame(width: 22, height: 22)
        } trailing: {
            Color.white.frame(width: 18, height: 14)
        }, from: Self.nowPlaying)
    }

    func expire() {
        clock.advance(by: .milliseconds(2500))
        host.expireDue()
    }

    var shown: String? { host.liveActivity.map { "\($0.pluginID) \($0.activity.id)" } }

    /// Green and white pixels in each half of the collapsed notch as the root view draws it. Writes
    /// `R10-render-<name>.png` (the top of the canvas) when NOTCH_RENDER_DIR is set.
    func capture(_ name: String) async throws -> (left: (green: Int, white: Int), right: (green: Int, white: Int)) {
        let notch = CGSize(width: NotchActivityRenderTests.notchWidth, height: 32)
        let image = try await NotchActivityRenderTests().settledCapture(host: host, notchSize: notch)
        let scale = CGFloat(image.width) / NotchLayout.canvasSize.width
        let top = try #require(image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: Int((notch.height + 12) * scale))))
        if let directory = ProcessInfo.processInfo.environment["NOTCH_RENDER_DIR"] {
            let data = try #require(NSBitmapImageRep(cgImage: top).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("R10-render-\(name).png"))
        }
        let width = top.width, height = top.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(top, in: CGRect(x: 0, y: 0, width: width, height: height))
        var counts = [(green: 0, white: 0), (green: 0, white: 0)]
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let (r, g, b) = (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
                let side = x < width / 2 ? 0 : 1
                if g >= 120 && g > r + 50 && g > b + 50 { counts[side].green += 1 }
                if r >= 200 && g >= 200 && b >= 200 { counts[side].white += 1 }
            }
        }
        print("R10 \(name): left \(counts[0]), right \(counts[1])")
        return (counts[0], counts[1])
    }

    /// Plugging in while music plays: Battery's later post at the same priority wins the collapsed
    /// notch, a green bolt left of the camera and the white percentage right of it, and NowPlaying's
    /// wings come back once it expires.
    @Test func R10__power_change_shows_over_now_playing_and_now_playing_returns_after_it() async throws {
        play()
        plugIn(percentage: "46%")
        #expect(host.state == .collapsed)
        #expect(shown == "\(Self.battery) power-change")
        let during = try await capture("T184")
        #expect(during.left.green > 0 && during.left.white == 0, "Battery's bolt, not the album art: \(during)")
        #expect(during.right.white > 0 && during.right.green == 0, "the percentage: \(during)")

        expire()
        #expect(shown == "\(Self.nowPlaying) now-playing")
        let after = try await capture("now-playing-after-T184")
        #expect(after.left.white > 0 && after.left.green == 0, "the album art again: \(after)")
    }

    /// Plugging in with nothing playing: once the power change expires, the always-on charging
    /// activity under it shows.
    @Test func R10__charging_activity_returns_after_the_power_change_without_now_playing() {
        plugIn(percentage: "46%")
        #expect(shown == "\(Self.battery) power-change")
        expire()
        #expect(shown == "\(Self.battery) charging")
    }
}
