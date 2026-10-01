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
            // The bars stand on the bottom edge, so the wing's inset below them is the host's.
            HStack(alignment: .bottom, spacing: Self.spacing) {
                ForEach(Array(Self.levels(at: context.date, isPlaying: isPlaying).enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .frame(width: Self.barWidth, height: Self.maxHeight * level)
                }
            }
            .frame(height: Self.maxHeight, alignment: .bottom)
            .foregroundStyle(.white.opacity(isPlaying ? 0.95 : 0.45))
        }
    }
}

/// The views beside the collapsed notch, without space of their own: the host keeps the same space
/// beside and below each. They read the model, so they follow every change of the posted activity's
/// item.
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

/// A transport button: an SF Symbol without a bezel, by default as tall as the symbol so the
/// screen's last row ends where its ink does.
struct TransportButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 16
    /// The hit target's height when it should be taller than the symbol.
    var height: CGFloat?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size + 12, height: height ?? size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

extension TransportButton {
    static func previous(size: CGFloat, height: CGFloat? = nil, send: @escaping (NowPlayingCommand) -> Void) -> TransportButton {
        TransportButton(symbol: "backward.fill", label: "이전 곡", size: size, height: height) { send(.previous) }
    }

    /// Pause while playing, play otherwise.
    static func playPause(for info: TrackInfo, size: CGFloat, height: CGFloat? = nil, send: @escaping (NowPlayingCommand) -> Void) -> TransportButton {
        TransportButton(
            symbol: info.isPlaying ? "pause.fill" : "play.fill",
            label: info.isPlaying ? "일시정지" : "재생",
            size: size,
            height: height
        ) {
            send(info.playPauseCommand)
        }
    }

    static func next(size: CGFloat, height: CGFloat? = nil, send: @escaping (NowPlayingCommand) -> Void) -> TransportButton {
        TransportButton(symbol: "forward.fill", label: "다음 곡", size: size, height: height) { send(.next) }
    }
}

/// The expanded tab: the art, the title and artist, the progress with elapsed and total time, and
/// previous, play/pause and next. 332 pt wide in every state, and offered more (under a wider band)
/// the column stretches beside the art. With nothing playing, or when playback cannot be read, the
/// message takes the title line over a dimmed track and dimmed controls, so the screen keeps the
/// same skeleton and reaches the same edges. The host adds the margin around it.
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
            .frame(minWidth: Self.columnWidth, idealWidth: Self.columnWidth, maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The track's column without a track: the message in the title line, then the progress track
    /// and previous, play and next, dimmed and disabled.
    private func message(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Capsule()
                .fill(.white.opacity(0.15))
                .frame(height: 4)
                .padding(.top, 4)
            HStack(spacing: 24) {
                TransportButton(symbol: "backward.fill", label: "이전 곡", size: 16) {}
                TransportButton(symbol: "play.fill", label: "재생", size: 22) {}
                TransportButton(symbol: "forward.fill", label: "다음 곡", size: 16) {}
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(.tertiary)
            .disabled(true)
        }
        .lineLimit(1)
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
                TransportButton.previous(size: 16, send: send)
                TransportButton.playPause(for: info, size: 22, send: send)
                TransportButton.next(size: 16, send: send)
            }
            .frame(minWidth: Self.columnWidth, idealWidth: Self.columnWidth, maxWidth: .infinity)
        }
        .lineLimit(1)
    }
}

/// A thin bar filled to the item's progress over the elapsed and the total time, `width` wide or as
/// wide as it is offered beyond that. While playing it moves on every second from the helper's sample.
private struct ProgressRow: View {
    let info: TrackInfo
    let width: CGFloat

    var body: some View {
        TimelineView(.periodic(from: info.sampledAt, by: 1)) { context in
            VStack(spacing: 3) {
                GeometryReader { bar in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.15))
                        Capsule().frame(width: bar.size.width * (info.progress(at: context.date) ?? 0))
                    }
                }
                .frame(height: 4)
                HStack {
                    Text(info.elapsed(at: context.date).map(timeText) ?? "--:--")
                    Spacer(minLength: 0)
                    Text(info.duration.map(timeText) ?? "--:--")
                }
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            .frame(minWidth: width, idealWidth: width, maxWidth: .infinity)
        }
    }
}
