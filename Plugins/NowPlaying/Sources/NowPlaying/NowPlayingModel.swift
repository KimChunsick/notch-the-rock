import Foundation
import ImageIO
import Observation

/// What the notch shows about playback.
enum PlaybackState: Equatable {
    /// Nothing is playing, or the helper has not said yet.
    case nothing
    case track(TrackInfo)
    /// The helper cannot reach MediaRemote on this Mac.
    case unavailable
}

/// The latest state from the helper, shared by the plugin, the wings, the tab and the tile.
@MainActor
@Observable
final class NowPlayingModel {
    private(set) var state = PlaybackState.nothing
    /// The current item's album art, decoded once per change; nil when it has none or it cannot be
    /// decoded.
    private(set) var artwork: CGImage?

    /// The longest side of the decoded artwork in pixels: twice the largest art on screen (the tab's
    /// 88 pt) at 2x.
    static let artworkMaxPixelSize = Int(NowPlayingView.artSide) * 2 * 2

    var track: TrackInfo? {
        if case .track(let info) = state { info } else { nil }
    }

    func apply(_ line: HelperLine) {
        switch line {
        case .nothing:
            state = .nothing
            artwork = nil
        case .info(var info, let update):
            // Playing at rate 0 counts as paused; the plugin's pause grace keeps the wings while that lasts
            // no longer than the grace.
            info.isPlaying = info.isEffectivelyPlaying
            state = .track(info)
            switch update {
            case .unchanged:
                break
            case .removed:
                artwork = nil
            case .image(let data, _):
                artwork = Self.thumbnail(of: data)
            }
        case .unavailable:
            state = .unavailable
            artwork = nil
        }
    }

    /// Decodes `data` as a thumbnail no larger than `artworkMaxPixelSize`, so a large cover costs no
    /// more memory than the art on screen needs. Smaller images keep their size.
    private static func thumbnail(of data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: artworkMaxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The helper ended without saying why, or the plugin stopped it: what plays now is unknown, and
    /// a new helper reports from scratch.
    func reset() {
        state = .nothing
        artwork = nil
    }
}
