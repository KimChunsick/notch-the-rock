import SwiftUI

/// The album art in a rounded square, or a note on a grey square when there is none.
struct AlbumArt: View {
    let image: CGImage?
    let side: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note")
                        .font(.system(size: side * 0.45, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Bars that bounce while playing and stand still while paused.
struct PlaybackBars: View {
    let isPlaying: Bool

    static let barWidth: CGFloat = 3
    static let spacing: CGFloat = 2
    static let maxHeight: CGFloat = 14
    /// Paused heights, as fractions of `maxHeight`.
    static let stillLevels: [Double] = [0.35, 0.6, 0.45, 0.3]
    /// Each bar's speed in radians per second, so the bars never move in step.
    private static let speeds: [Double] = [7.3, 9.1, 6.2, 10.4]

    /// Bar heights at `date`, as fractions of `maxHeight`: moving while playing, the still pattern
    /// while paused.
    static func levels(at date: Date, isPlaying: Bool) -> [Double] {
        guard isPlaying else { return stillLevels }
        let time = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
        return speeds.enumerated().map { index, speed in
            0.2 + 0.8 * (0.5 + 0.5 * sin(time * speed + Double(index) * 1.3))
        }
    }

    var body: some View {
        // A paused timeline stops redrawing, so the still bars cost nothing.
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !isPlaying)) { context in
            HStack(spacing: Self.spacing) {
                ForEach(Array(Self.levels(at: context.date, isPlaying: isPlaying).enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .frame(width: Self.barWidth, height: Self.maxHeight * level)
                }
            }
            .frame(height: Self.maxHeight)
            .foregroundStyle(.white.opacity(isPlaying ? 0.95 : 0.45))
        }
    }
}

/// The views beside the collapsed notch. They read the model, so they follow every change of the
/// posted activity's item.
enum NowPlayingWings {
    static let artSide: CGFloat = 22

    struct Leading: View {
        let model: NowPlayingModel

        var body: some View {
            AlbumArt(image: model.artwork, side: NowPlayingWings.artSide, cornerRadius: 5)
        }
    }

    struct Trailing: View {
        let model: NowPlayingModel

        var body: some View {
            PlaybackBars(isPlaying: model.track?.isPlaying ?? false)
        }
    }
}

/// A transport button: an SF Symbol without a bezel.
struct TransportButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 16
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size + 12, height: size + 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

extension TransportButton {
    /// Pause while playing, play otherwise.
    static func playPause(for info: TrackInfo, size: CGFloat, send: @escaping (NowPlayingCommand) -> Void) -> TransportButton {
        TransportButton(
            symbol: info.isPlaying ? "pause.fill" : "play.fill",
            label: info.isPlaying ? "일시정지" : "재생",
            size: size
        ) {
            send(info.playPauseCommand)
        }
    }
}

/// The expanded tab: the art, the title and artist, the progress with elapsed and total time, and
/// previous, play/pause and next. 364 pt wide whatever plays.
struct NowPlayingView: View {
    let model: NowPlayingModel
    let send: (NowPlayingCommand) -> Void

    static let artSide: CGFloat = 88
    static let columnWidth: CGFloat = 230

    var body: some View {
        HStack(spacing: 14) {
            AlbumArt(image: model.artwork, side: Self.artSide, cornerRadius: 10)
            Group {
                switch model.state {
                case .track(let info):
                    track(info)
                case .nothing:
                    message("재생 중인 음악이 없어요.")
                case .unavailable:
                    message("이 Mac에서 재생 정보를 읽을 수 없어요.")
                }
            }
            .frame(width: Self.columnWidth, alignment: .leading)
        }
        .padding()
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private func track(_ info: TrackInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(info.title)
                .font(.headline)
            Text(info.artist ?? info.album ?? " ")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ProgressRow(info: info, width: Self.columnWidth)
                .padding(.top, 4)
            HStack(spacing: 24) {
                TransportButton(symbol: "backward.fill", label: "이전 곡") { send(.previous) }
                TransportButton.playPause(for: info, size: 22, send: send)
                TransportButton(symbol: "forward.fill", label: "다음 곡") { send(.next) }
            }
            .frame(width: Self.columnWidth)
        }
        .lineLimit(1)
    }
}

/// A thin bar filled to the item's progress over the elapsed and the total time. While playing it
/// moves on every second from the helper's sample.
private struct ProgressRow: View {
    let info: TrackInfo
    let width: CGFloat

    var body: some View {
        TimelineView(.periodic(from: info.sampledAt, by: 1)) { context in
            VStack(spacing: 3) {
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule().frame(width: width * (info.progress(at: context.date) ?? 0))
                }
                .frame(width: width, height: 4)
                HStack {
                    Text(info.elapsed(at: context.date).map(timeText) ?? "--:--")
                    Spacer(minLength: 0)
                    Text(info.duration.map(timeText) ?? "--:--")
                }
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: width)
            }
        }
    }
}
