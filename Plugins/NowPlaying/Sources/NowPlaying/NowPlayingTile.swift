import NotchKit
import SwiftUI

/// The home tile; tapping it opens the tab. Wide: the art beside the title, the artist and
/// previous, play/pause and next. Small: the art over play/pause. It draws the model the tab draws.
struct NowPlayingTile: View {
    let model: NowPlayingModel
    let size: TileSize
    let send: (NowPlayingCommand) -> Void

    /// The buttons' hit targets are this tall, and at least this wide.
    static let buttonHeight: CGFloat = 24

    var body: some View {
        switch size {
        case .small:
            small
        case .wide, .large:
            wide
        @unknown default:
            wide
        }
    }

    /// 188 × 82 pt.
    private var wide: some View {
        HStack(spacing: 10) {
            AlbumArt(image: model.artwork, side: 62, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 2) {
                switch model.state {
                case .track(let info):
                    Text(info.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(info.artist ?? info.album ?? " ")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    buttonRow(for: info)
                        .padding(.leading, -6)
                case .nothing:
                    caption("재생 중인 음악이 없어요.")
                case .unavailable:
                    caption("재생 정보를 읽을 수 없어요.")
                }
            }
            .lineLimit(1)
            .frame(width: 96, alignment: .leading)
        }
        .padding(10)
    }

    /// 58 × 86 pt.
    private var small: some View {
        VStack(spacing: 4) {
            AlbumArt(image: model.artwork, side: 42, cornerRadius: 7)
            switch model.state {
            case .track(let info):
                buttonRow(for: info)
            case .nothing:
                caption("재생 없음")
                    .frame(height: 24)
            case .unavailable:
                caption("읽을 수 없어요")
                    .frame(height: 24)
            }
        }
        .lineLimit(1)
        .padding(8)
    }

    /// The tab's commands: previous, play/pause and next on the wide tile; play/pause alone on the
    /// small one, whose 58 pt column under the art has no room for three 24 pt targets apart.
    static func buttons(for info: TrackInfo, size: TileSize, send: @escaping (NowPlayingCommand) -> Void) -> [TransportButton] {
        let playPause = TransportButton.playPause(for: info, size: 16, height: buttonHeight, send: send)
        guard size != .small else { return [playPause] }
        return [
            .previous(size: 13, height: buttonHeight, send: send),
            playPause,
            .next(size: 13, height: buttonHeight, send: send),
        ]
    }

    private func buttonRow(for info: TrackInfo) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(Self.buttons(for: info, size: size, send: send).enumerated()), id: \.offset) { _, button in
                button
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}
