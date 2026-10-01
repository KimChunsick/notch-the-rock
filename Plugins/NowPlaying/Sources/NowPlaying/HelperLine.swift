import Foundation

/// The item that is playing, as the helper reports it.
struct TrackInfo: Equatable, Sendable {
    var title: String
    var artist: String?
    var album: String?
    /// Length in seconds; nil when the app does not say.
    var duration: TimeInterval?
    /// Seconds into the item at `sampledAt`; nil when the app does not say.
    var elapsed: TimeInterval?
    /// When the app sampled `elapsed`.
    var sampledAt: Date
    /// 1 at normal speed, 0 while paused; nil when the app does not say.
    var rate: Double?
    var isPlaying: Bool
    /// The app that plays it (the browser for web content), when MediaRemote names it.
    var bundleID: String?

    init(
        title: String,
        artist: String? = nil,
        album: String? = nil,
        duration: TimeInterval? = nil,
        elapsed: TimeInterval? = nil,
        sampledAt: Date,
        rate: Double? = nil,
        isPlaying: Bool,
        bundleID: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.elapsed = elapsed
        self.sampledAt = sampledAt
        self.rate = rate
        self.isPlaying = isPlaying
        self.bundleID = bundleID
    }
}

/// The artwork part of an `info` line: the helper sends the image only when it changed.
enum ArtworkUpdate: Equatable, Sendable {
    /// The line has no `artwork` key: the image the reader holds stays.
    case unchanged
    /// `"artwork": null`: the item has no image any more.
    case removed
    case image(Data, mime: String?)
}

/// One line of the helper's output (the format is in NowPlayingBridge.h).
enum HelperLine: Equatable, Sendable {
    /// Nothing is playing.
    case nothing
    case info(TrackInfo, artwork: ArtworkUpdate)
    /// The helper cannot reach MediaRemote, and exits.
    case unavailable(reason: String)

    /// The largest artwork the reader takes: 8 MiB of image data. A larger payload is refused
    /// before its base64 is decoded, and the item shows the placeholder.
    static let maxArtworkBytes = 8 << 20

    /// Nil for a line that is none of these; the reader ignores it.
    init?(_ line: some StringProtocol) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }
        switch type {
        case "none":
            self = .nothing
        case "unavailable":
            self = .unavailable(reason: object["reason"] as? String ?? "")
        case "info":
            guard let title = object["title"] as? String,
                  let timestamp = object["timestamp"] as? Double, timestamp.isFinite,
                  let isPlaying = object["playing"] as? Bool
            else { return nil }
            let artwork: ArtworkUpdate
            switch object["artwork"] {
            case nil:
                artwork = .unchanged
            case is NSNull:
                artwork = .removed
            case let image as [String: Any]:
                guard let base64 = image["data"] as? String else { return nil }
                if base64.utf8.count > (Self.maxArtworkBytes + 2) / 3 * 4 {
                    // Refused before decoding: the held image belongs to the previous item, so the
                    // placeholder shows.
                    artwork = .removed
                } else {
                    guard let data = Data(base64Encoded: base64) else { return nil }
                    artwork = .image(data, mime: image["mime"] as? String)
                }
            default:
                return nil
            }
            let info = TrackInfo(
                title: title,
                artist: object["artist"] as? String,
                album: object["album"] as? String,
                duration: number(object["duration"], in: TrackInfo.secondsRange),
                elapsed: number(object["elapsed"], in: TrackInfo.secondsRange),
                sampledAt: Date(timeIntervalSince1970: timestamp),
                rate: number(object["rate"], in: TrackInfo.rateRange),
                isPlaying: isPlaying,
                bundleID: object["bundleID"] as? String
            )
            self = .info(info, artwork: artwork)
        default:
            return nil
        }
    }
}

/// A number field within `range` (so finite), or nil: an out-of-range field is dropped and the rest
/// of the line still applies.
private func number(_ value: Any?, in range: ClosedRange<Double>) -> Double? {
    guard let value = value as? Double, range.contains(value) else { return nil }
    return value
}

extension TrackInfo {
    /// The lengths and positions the reader takes, in seconds: up to a week. A value outside is not
    /// a real item, and keeping within it keeps the time text within `Int`.
    static let secondsRange: ClosedRange<TimeInterval> = 0...604_800
    /// The playback rates the reader takes.
    static let rateRange: ClosedRange<Double> = -4...4

    /// Seconds into the item at `date`: the sampled time, moved on at the playback rate while
    /// playing, kept within the item (within `secondsRange` when the app gives no length). Nil when
    /// the app reports no elapsed time.
    func elapsed(at date: Date) -> TimeInterval? {
        guard let elapsed else { return nil }
        var value = elapsed
        if isPlaying {
            value += (rate ?? 1) * date.timeIntervalSince(sampledAt)
        }
        let end = if let duration, duration > 0 { duration } else { Self.secondsRange.upperBound }
        return min(max(value, 0), end)
    }

    /// How far the item is at `date`, from 0 to 1; nil without an elapsed time and a duration.
    func progress(at date: Date) -> Double? {
        guard let duration, duration > 0, let elapsed = elapsed(at: date) else { return nil }
        return elapsed / duration
    }

    /// The transport button between previous and next: pause while playing, otherwise play. Asking
    /// for the state the button shows, not a toggle, keeps a repeated press from undoing the first.
    var playPauseCommand: NowPlayingCommand {
        isPlaying ? .pause : .play
    }
}

/// `187` → `3:07`, `3723` → `1:02:03`. A value outside `TrackInfo.secondsRange` shows as the nearer
/// limit and NaN as zero, so the conversion to `Int` cannot trap.
func timeText(_ seconds: TimeInterval) -> String {
    let range = TrackInfo.secondsRange
    let total = seconds.isNaN ? 0 : Int(min(max(seconds, range.lowerBound), range.upperBound))
    let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
    return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
}
