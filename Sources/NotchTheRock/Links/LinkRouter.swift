import Foundation
import OSLog

/// What a link can do to the notch: open the home or a plugin's screen, nothing else.
@MainActor
protocol LinkTarget: AnyObject {
    func showHome()
    func open(pluginID: String)
}

extension NotchHostModel: LinkTarget {}

/// Hands `notchtherock://` links to the notch. Links that arrive before the plugins are loaded (the
/// one that launched the app) wait and are shown, in order and once, when `pluginsDidLoad()` is
/// called. A URL that is not a link is dropped with a log line.
@MainActor
final class LinkRouter {
    private let target: any LinkTarget
    private var waiting: [NotchLink] = []
    private var pluginsLoaded = false
    private let logger = Logger(subsystem: "com.notchtherock.NotchTheRock", category: "links")

    init(target: any LinkTarget) {
        self.target = target
    }

    func receive(_ url: URL) {
        guard let link = NotchLink(url: url) else {
            logger.notice("ignored \(url.absoluteString, privacy: .public): not a notchtherock link")
            return
        }
        if pluginsLoaded {
            show(link)
        } else {
            logger.notice("\(url.absoluteString, privacy: .public) waits until the plugins are loaded")
            waiting.append(link)
        }
    }

    /// Shows the waiting links. Later calls (a reload in Settings) find none.
    func pluginsDidLoad() {
        pluginsLoaded = true
        let links = waiting
        waiting = []
        links.forEach(show)
    }

    private func show(_ link: NotchLink) {
        switch link {
        case .home:
            target.showHome()
        case .plugin(let id):
            target.open(pluginID: id)
        }
    }
}
