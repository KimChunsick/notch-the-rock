import AppKit
import SwiftUI

/// The marks the session rows show. The plugin bundles no brand files: the marks come from the
/// agents' own apps when they are installed.
@MainActor
protocol AgentLogoProviding: AnyObject {
    /// The agent's mark, or nil when it is not available. A template image is tinted to the row's
    /// foreground.
    func logo(for agent: AgentKind) -> NSImage?
}

extension AgentKind {
    /// What an alert shows next to its title, and the home tile beside each session: the agent's mark,
    /// tinted to the notch's foreground when it is a template, or the agent's symbol when the mark is
    /// not available.
    @MainActor
    func alertIcon(_ logos: (any AgentLogoProviding)?) -> Image {
        guard let logo = logos?.logo(for: self) else { return Image(systemName: symbol) }
        return Image(nsImage: logo).renderingMode(logo.isTemplate ? .template : .original)
    }
}

/// Reads the marks from the installed apps, once per agent: Claude's menu bar mark (a template
/// image) from the Claude app, Codex's icon from the ChatGPT app, in the variant drawn for a dark
/// background so it reads on the black notch.
@MainActor
final class InstalledAppLogos: AgentLogoProviding {
    /// Bundle identifiers and image names in each app's Resources, in order of preference.
    static let sources: [AgentKind: (bundleIDs: [String], images: [String])] = [
        .claude: (["com.anthropic.claudefordesktop"], ["TrayIconTemplate"]),
        .codex: (["com.openai.codex", "com.openai.chat"], ["icon-codex-dark-color", "icon-codex-light"]),
    ]

    private var cache: [AgentKind: NSImage?] = [:]

    func logo(for agent: AgentKind) -> NSImage? {
        if let cached = cache[agent] { return cached }
        let image = Self.load(agent)
        cache[agent] = .some(image)
        return image
    }

    private static func load(_ agent: AgentKind) -> NSImage? {
        guard let source = sources[agent] else { return nil }
        for bundleID in source.bundleIDs {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
                  let bundle = Bundle(url: url) else { continue }
            // `image(forResource:)` also picks up the @2x and @3x files.
            if let image = source.images.lazy.compactMap({ bundle.image(forResource: $0) }).first {
                if agent == .claude { image.isTemplate = true }
                return image
            }
        }
        return nil
    }
}
