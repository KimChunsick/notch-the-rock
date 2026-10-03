import SwiftUI

/// A plugin's screen's controls in the top band, where the home has its own: ‹ and the plugin's
/// name in the left wing, back to the home, and the plugin's settings gear in the right wing when it
/// has a settings page. The shape grows until the left wing holds the whole name, up to its widest;
/// a name longer than that is cut short, never under the camera's clearance.
struct PluginBand: View {
    let host: NotchHostModel
    let plugin: HomePlugin
    let notchSize: CGSize
    let width: CGFloat
    let openSettings: @MainActor (_ pluginID: String?) -> Void

    /// The narrowest expanded shape that shows the plugin's whole name beside the camera.
    static func minimumWidth(notch: CGSize, plugin: HomePlugin) -> CGFloat {
        BandLayout.minimumWidth(notch: notch, leading: backWidth(plugin.name), trailing: plugin.hasSettings ? HomeChrome.gearWidth : 0)
    }

    /// The back control's own width with the whole name, measured once per name.
    static func backWidth(_ name: String) -> CGFloat {
        if let width = backWidths[name] { return width }
        let width = NSHostingView(rootView: BackLabel(name: name)).fittingSize.width.rounded(.up)
        backWidths[name] = width
        return width
    }

    private static var backWidths: [String: CGFloat] = [:]

    func back() {
        host.back()
    }

    /// What the gear does; nil for a plugin without a settings page, which has no gear.
    var settingsAction: (@MainActor () -> Void)? {
        guard plugin.hasSettings else { return nil }
        return { [openSettings, plugin] in openSettings(plugin.pluginID) }
    }

    var body: some View {
        let leading = min(Self.backWidth(plugin.name), BandLayout.wingRoom(notch: notchSize, width: width))
        let layout = BandLayout(notch: notchSize, width: width, leading: leading, trailing: HomeChrome.gearWidth)
        ZStack(alignment: .topLeading) {
            Button(action: back) {
                BackLabel(name: plugin.name)
                    .frame(width: layout.leadingFrame.width, height: layout.leadingFrame.height, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .help("홈으로")
            .accessibilityLabel("\(plugin.name), 홈으로 돌아가기")
            .position(x: layout.leadingFrame.midX, y: layout.leadingFrame.midY)
            if let settingsAction {
                BandGear(frame: layout.trailingFrame, label: "\(plugin.name) 설정", action: settingsAction)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.9))
        .frame(width: width, height: notchSize.height, alignment: .topLeading)
    }
}

/// ‹ and a plugin's name, on one line that is cut short at the end when it has to be.
private struct BackLabel: View {
    let name: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.left")
                .font(.system(size: 12, weight: .semibold))
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// The settings gear in the band's right wing, on the home and on a plugin's screen.
private struct BandGear: View {
    let frame: CGRect
    let label: String
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .medium))
                .frame(width: frame.width, height: frame.height)
                .contentShape(Rectangle())
        }
        .help(label)
        .accessibilityLabel(label)
        .position(x: frame.midX, y: frame.midY)
    }
}

/// The home's controls in the top band: 편집/완료 in the left wing, the settings gear in the right.
struct HomeBand: View {
    let home: HomeModel
    let notchSize: CGSize
    let width: CGFloat
    let openSettings: @MainActor (_ pluginID: String?) -> Void

    var body: some View {
        let layout = BandLayout(notch: notchSize, width: width, leading: HomeChrome.editWidth, trailing: HomeChrome.gearWidth)
        ZStack(alignment: .topLeading) {
            Button {
                if home.isEditing { home.finishEditing() } else { home.beginEditing() }
            } label: {
                Text(home.isEditing ? "완료" : "편집")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: layout.leadingFrame.width, height: layout.leadingFrame.height)
                    .background(Capsule().fill(.white.opacity(home.isEditing ? 0.24 : 0.1)))
                    .contentShape(Capsule())
            }
            .help(home.isEditing ? "편집 마치기" : "홈 편집")
            .position(x: layout.leadingFrame.midX, y: layout.leadingFrame.midY)
            BandGear(frame: layout.trailingFrame, label: "설정") { openSettings(nil) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.9))
        .frame(width: width, height: notchSize.height, alignment: .topLeading)
    }
}
