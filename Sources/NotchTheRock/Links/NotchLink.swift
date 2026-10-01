import Foundation

/// A `notchtherock://` link and what it asks the notch to show. The Raycast extension in
/// `Integrations/Raycast` opens these; so does `open 'notchtherock://open/<plugin-id>'`.
///
/// | Link | Shows |
/// |---|---|
/// | `notchtherock://`, `notchtherock://open`, `notchtherock://home` | the home |
/// | `notchtherock://open/<plugin-id>` | the plugin's screen (the home when it has none) |
///
/// Scheme and route ignore case, the plugin id keeps it, one trailing slash is allowed and the id
/// may be percent-encoded. Every other URL is not a link.
enum NotchLink: Equatable {
    case home
    case plugin(id: String)

    static let scheme = "notchtherock"
    /// The longest plugin id a link carries, as long as a bundle identifier gets in practice.
    static let maximumPluginIDLength = 255

    /// nil for another scheme, an unknown route, extra path parts, a query or fragment, or an id
    /// that is not a plugin id.
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil
        else { return nil }
        // Split before decoding, so an encoded slash stays inside its part and fails the id check.
        var path = components.percentEncodedPath
        if path.hasSuffix("/") { path.removeLast() }
        guard path.isEmpty || path.hasPrefix("/") else { return nil }
        let parts = path.isEmpty ? [] : path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        switch ((components.host ?? "").lowercased(), parts.count) {
        case ("", 0), ("open", 0), ("home", 0):
            self = .home
        case ("open", 1):
            guard let id = parts[0].removingPercentEncoding, Self.isPluginID(id) else { return nil }
            self = .plugin(id: id)
        default:
            return nil
        }
    }

    /// Reverse-DNS: ASCII letters, digits and hyphens in at least two dot-separated parts, the rule
    /// `scripts/new-plugin.sh` gives new plugins.
    static func isPluginID(_ id: String) -> Bool {
        id.utf8.count <= maximumPluginIDLength && id.wholeMatch(of: /[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+/) != nil
    }
}
