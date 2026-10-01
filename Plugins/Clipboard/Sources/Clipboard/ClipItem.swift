import Foundation

/// One entry of the history, as stored in the encrypted list. An image's PNG bytes live in their
/// own encrypted file named after `id`; the list keeps their digest and the thumbnail.
struct ClipItem: Codable, Hashable, Identifiable, Sendable {
    enum Kind: Hashable, Sendable {
        case text
        case link
        case image
    }

    enum Content: Codable, Hashable, Sendable {
        case text(String)
        case link(String)
        /// `digest` is the SHA-256 of the PNG bytes and identifies a repeat of the same image.
        case image(digest: String, thumbnail: Data)
    }

    let id: UUID
    let content: Content
    /// When this content was last copied.
    var date: Date
    var isPinned: Bool
    /// The app it was last copied from, when that is known. Lists saved before entries had one
    /// leave it out.
    var source: SourceApp? = nil

    var kind: Kind {
        switch content {
        case .text: .text
        case .link: .link
        case .image: .image
        }
    }

    /// The text or URL, nil for an image.
    var text: String? {
        switch content {
        case .text(let text), .link(let text): text
        case .image: nil
        }
    }
}
