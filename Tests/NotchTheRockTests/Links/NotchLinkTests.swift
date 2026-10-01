import AppKit
import NotchKit
import SwiftUI
import Testing
@testable import NotchTheRock

/// Records what the links ask the notch to show.
@MainActor
private final class RecordingTarget: LinkTarget {
    var calls: [String] = []
    func showHome() { calls.append("home") }
    func open(pluginID: String) { calls.append("open \(pluginID)") }
}

private func link(_ string: String) -> NotchLink? {
    URL(string: string).flatMap(NotchLink.init(url:))
}

private func url(_ string: String) -> URL {
    URL(string: string)!
}

/// `notchtherock://` links: the routes they name, the queue until the plugins are loaded, and
/// the delegate that receives them from Launch Services.
@MainActor
struct NotchLinkTests {
    @Test func R18__home_links_in_every_form() {
        for string in [
            "notchtherock://", "notchtherock://open", "notchtherock://home",
            "notchtherock://open/", "notchtherock://home/", "NotchTheRock://OPEN", "notchtherock://Home",
        ] {
            #expect(link(string) == .home, "\(string)")
        }
    }

    @Test func R18__plugin_links_keep_the_id() {
        let clipboard = NotchLink.plugin(id: "com.notchtherock.clipboard")
        #expect(link("notchtherock://open/com.notchtherock.clipboard") == clipboard)
        #expect(link("notchtherock://open/com.notchtherock.clipboard/") == clipboard)
        #expect(link("notchtherock://open/com%2Enotchtherock%2Eclipboard") == clipboard)
        #expect(link("NOTCHTHEROCK://Open/com.Example.My-Clock2") == .plugin(id: "com.Example.My-Clock2"))
        let longest = String(repeating: "a", count: 252) + ".bc"
        #expect(link("notchtherock://open/\(longest)") == .plugin(id: longest))
    }

    @Test func R18__other_urls_are_ignored() {
        let tooLong = String(repeating: "a", count: 253) + ".bc"
        for string in [
            "https://open/com.notchtherock.clipboard",
            "notchtherock-beta://open",
            "notchtherock:open",
            "notchtherock://settings",
            "notchtherock://open/com.notchtherock.clipboard/extra",
            "notchtherock://open//com.notchtherock.clipboard",
            "notchtherock://home/com.notchtherock.clipboard",
            "notchtherock://open/clipboard",
            "notchtherock://open/com..clipboard",
            "notchtherock://open/.com.notchtherock",
            "notchtherock://open/com.notchtherock.clip_board",
            "notchtherock://open/com%2Fnotchtherock.clipboard",
            "notchtherock://open/com.notchtherock.%ED%81%B4%EB%A6%BD",
            "notchtherock://open/com.notchtherock.clipboard?tab=1",
            "notchtherock://open/com.notchtherock.clipboard#top",
            "notchtherock://open/\(tooLong)",
        ] {
            #expect(link(string) == nil, "\(string)")
        }
    }

    @Test func R18__links_before_the_plugins_load_are_queued_then_delivered_once() {
        let target = RecordingTarget()
        let router = LinkRouter(target: target)
        router.receive(url("notchtherock://open/com.notchtherock.clipboard"))
        router.receive(url("notchtherock://settings"))
        router.receive(url("notchtherock://"))
        #expect(target.calls.isEmpty)

        router.pluginsDidLoad()
        #expect(target.calls == ["open com.notchtherock.clipboard", "home"])
        router.pluginsDidLoad()
        #expect(target.calls.count == 2, "a reload delivers nothing again")

        router.receive(url("notchtherock://open/com.notchtherock.battery"))
        #expect(target.calls == ["open com.notchtherock.clipboard", "home", "open com.notchtherock.battery"])
    }

    @Test func R18__a_link_never_opens_settings() {
        let target = RecordingTarget()
        let router = LinkRouter(target: target)
        router.pluginsDidLoad()
        var settingsShown = 0
        let delegate = AppDelegate(showSettings: { settingsShown += 1 }, links: router)
        delegate.application(NSApplication.shared, open: [
            url("notchtherock://settings"),
            url("notchtherock://open/com.notchtherock.clipboard"),
            url("notchtherock://"),
            url("notchtherock://open/bad id"),
        ])
        #expect(settingsShown == 0)
        #expect(target.calls == ["open com.notchtherock.clipboard", "home"])
    }

    @Test func R18__a_link_during_the_greeting_opens_its_screen_when_the_greeting_ends() {
        let fixture = HomeDefaults()
        defer { fixture.cleanUp() }
        let clock = ManualClock()
        let host = NotchHostModel(now: { clock.now }, homeStore: fixture.store)
        host.plugins = [homePlugin("com.example.clock")]
        host.present(Takeover(duration: .seconds(3)) { Text("안녕하세요") }, from: "com.notchtherock.hello")
        let router = LinkRouter(target: host)
        router.receive(url("notchtherock://open/com.example.clock"))
        router.pluginsDidLoad()
        #expect(host.state == .takeover)

        clock.advance(by: .seconds(3))
        host.expireDue()
        #expect(host.state == .expanded)
        #expect(host.screen == .detail(pluginID: "com.example.clock"))
    }
}
