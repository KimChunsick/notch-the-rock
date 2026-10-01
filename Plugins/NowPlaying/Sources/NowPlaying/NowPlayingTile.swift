import NotchKit
import SwiftUI

/// The home tile; tapping it opens the tab. Wide: the art beside the title, the artist and
/// play/pause. Small: the art over play/pause. It draws the model the tab draws.
struct NowPlayingTile: View {
    let model: NowPlayingModel
    let size: TileSize
    let send: (NowPlayingCommand) -> Void

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
                    TransportButton.playPause(for: info, size: 16, send: send)
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
                TransportButton.playPause(for: info, size: 16, send: send)
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

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}
