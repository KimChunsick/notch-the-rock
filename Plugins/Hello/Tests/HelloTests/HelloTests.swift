import Foundation
import NotchKit
import SwiftUI
import Testing
@testable import Hello

/// Records the takeovers the plugin presents; every other host call is ignored.
@MainActor
final class RecordingHost: NotchHost {
    var takeovers: [(duration: Duration, pluginID: String)] = []

    func post(_ activity: LiveActivity, from pluginID: String) {}
    func clearActivity(id: String, from pluginID: String) {}
    func showHUD(_ hud: HUD, duration: Duration, from pluginID: String) {}
    func present(_ takeover: Takeover, from pluginID: String) {
        takeovers.append((takeover.duration, pluginID))
    }
    func requestAttention(_ request: AttentionRequest, from pluginID: String) async -> AttentionResponse { .dismissed }
    func expand(toTabOf pluginID: String) {}
    func collapse(from pluginID: String) {}
    var isAccessibilityTrusted: Bool { false }
    func requestAccessibility(from pluginID: String) {}
    func log(_ level: LogLevel, _ message: String, from pluginID: String) {}
}

/// A context with a fresh defaults suite, so a stored toggle never leaks into another test.
@MainActor
func withContext(_ body: (NotchContext, RecordingHost) throws -> Void) throws {
    let id = HelloPlugin.manifest.id
    let suite = "HelloTests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    defer {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    let storage = try PluginStorage(
        directory: directory.appendingPathComponent(id),
        defaultsSuiteName: suite,
        keychainService: suite
    )
    let host = RecordingHost()
    let context = NotchContext(pluginID: id, bundleURL: directory.appendingPathComponent("Hello.notchplugin"), host: host, storage: storage)
    try body(context, host)
}

@MainActor
@Suite struct HelloTests {
    @Test func R04__lettering_is_one_continuous_stroke_inside_its_canvas() {
        var moves = 0
        var curves = 0
        var closes = 0
        var first: String?
        HelloLettering.stroke.forEach { element in
            switch element {
            case .move: moves += 1; first = first ?? "move"
            case .curve, .quadCurve, .line: curves += 1; first = first ?? "draw"
            case .closeSubpath: closes += 1
            @unknown default: break
            }
        }
        #expect(first == "move")
        #expect(moves == 1)
        #expect(closes == 0)
        #expect(curves >= 10)

        let bounds = HelloLettering.stroke.boundingRect
        let inked = bounds.insetBy(dx: -HelloLettering.strokeWidth, dy: -HelloLettering.strokeWidth)
        #expect(bounds.width > 0 && bounds.height > 0)
        #expect(HelloLettering.canvas.contains(inked))

        // Walking the stroke never jumps: consecutive points along it stay close together.
        let steps = 200
        var previous = HelloLettering.stroke.trimmedPath(from: 0, to: 0.001).currentPoint
        var largestStep: CGFloat = 0
        for step in 1...steps {
            let point = HelloLettering.stroke.trimmedPath(from: 0, to: Double(step) / Double(steps)).currentPoint
            if let previous, let point {
                largestStep = max(largestStep, hypot(point.x - previous.x, point.y - previous.y))
            }
            previous = point
        }
        #expect(previous != nil)
        #expect(largestStep < HelloLettering.canvas.width / 20)
    }

    @Test(arguments: [
        CGRect(x: 0, y: 0, width: 300, height: 70),
        CGRect(x: 0, y: 0, width: 190, height: 32),
        CGRect(x: 40, y: 12, width: 120, height: 120),
    ])
    func R04__lettering_fits_takeover_bounds(_ rect: CGRect) {
        let path = HelloLettering().path(in: rect)
        let halfStroke = HelloLettering.strokeWidth * HelloLettering.scale(toFit: rect) / 2
        let inked = path.boundingRect.insetBy(dx: -halfStroke, dy: -halfStroke)
        #expect(!path.isEmpty)
        #expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(inked))
        #expect(abs(path.boundingRect.midX - rect.midX) < rect.width / 10)
        #expect(abs(path.boundingRect.midY - rect.midY) < rect.height / 10)
    }

    @Test func R04__timeline_draws_holds_and_ends_near_three_seconds() {
        let hello = HelloTimeline.hello
        #expect(hello.total >= 2.5 && hello.total <= 3.5)
        #expect(hello.duration == .milliseconds(Int((hello.total * 1000).rounded())))
        // The finished word stays on screen for a moment before the notch collapses.
        #expect(hello.total - hello.drawEnd >= 0.5)

        #expect(hello.frame(at: 0).writing == 0)
        #expect(hello.frame(at: hello.drawEnd).writing == 1)
        #expect(hello.frame(at: hello.drawEnd).opacity == 1)
        #expect(hello.frame(at: hello.total).opacity == 0)
        #expect(hello.frame(at: hello.total + 1).opacity == 0)

        let middle = HelloLetteringView.drawn(at: hello.frame(at: hello.drawEnd / 2).writing)
        #expect(middle > 0.2 && middle < 0.8)
        var last = -1.0
        for step in 0...60 {
            let drawn = HelloLetteringView.drawn(at: hello.frame(at: hello.total * Double(step) / 60).writing)
            #expect(drawn >= last)
            last = drawn
        }
    }

    @Test func R04__activate_presents_greeting_for_timeline_duration() throws {
        try withContext { context, host in
            let plugin = HelloPlugin(context: context)
            plugin.activate()
            #expect(host.takeovers.count == 1)
            #expect(host.takeovers.first?.pluginID == "com.notchtherock.hello")
            // The takeover lasts as long as the greeting it writes, a few seconds at most.
            let duration = try #require(host.takeovers.first?.duration)
            #expect(duration >= HelloTimeline.hello.duration && duration <= .seconds(7))
        }
    }

    @Test func R04__greeting_toggle_off_suppresses_takeover() throws {
        try withContext { context, host in
            let plugin = HelloPlugin(context: context)
            let preferences = HelloPreferences(defaults: context.storage.defaults)
            #expect(preferences.showsGreeting == true)
            #expect(plugin.settingsView != nil)

            preferences.showsGreeting = false
            #expect(context.storage.defaults.object(forKey: HelloPreferences.showsGreetingKey) as? Bool == false)
            plugin.activate()
            #expect(host.takeovers.isEmpty)

            preferences.showsGreeting = true
            plugin.activate()
            #expect(host.takeovers.count == 1)
        }
    }
}
