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

    var track: TrackInfo? {
        if case .track(let info) = state { info } else { nil }
    }

    func apply(_ line: HelperLine) {
        switch line {
        case .nothing:
            state = .nothing
            artwork = nil
        case .info(let info, let update):
            state = .track(info)
            switch update {
            case .unchanged:
                break
            case .removed:
                artwork = nil
            case .image(let data, _):
                artwork = CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            }
        case .unavailable:
            state = .unavailable
            artwork = nil
        }
    }

    /// The helper ended without saying why, or the plugin stopped it: what plays now is unknown, and
    /// a new helper reports from scratch.
    func reset() {
        state = .nothing
        artwork = nil
    }
}
