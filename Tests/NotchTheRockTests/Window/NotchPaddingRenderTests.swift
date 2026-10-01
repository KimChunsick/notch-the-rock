import AppKit
import Foundation
import NotchKit
import SwiftUI
import Testing
@testable import NotchTheRock

/// The visible gaps between what the expanded notch draws and the shape's edges, measured on an
/// offscreen render the way the end-to-end capture measures them. The host's composition is the
/// app's own (`NotchSurface`, `IntrinsicSizeLayout`, `NotchLayout.metrics`, `HomeView`, `HomeBand`,
/// `PluginScreenView`). The root package cannot import the plugin packages, and activating the real
/// plugins would read the machine (battery, audio, pasteboard, sensors) or ask for permissions, so
/// each plugin screen is a stand-in that repeats its tab view's layout code with fixed values.
@MainActor
@Suite struct NotchPaddingRenderTests {
    /// About the size of the 13-inch MacBook Air's notch.
    nonisolated static let notch = CGSize(width: 185, height: 32)
    /// Blue like the menu bar around the shape, so its edges stand out from the black.
    static let backdrop = Color(red: 0, green: 0.2, blue: 1)
    static let margin: CGFloat = 20

    struct Gaps: CustomStringConvertible {
        var content: CGSize
        var shape: CGSize
        var left: CGFloat
        var right: CGFloat
        var bottom: CGFloat

        var description: String {
            String(format: "content %.1f x %.1f, shape %.1f x %.1f, gap left %.1f right %.1f bottom %.1f pt",
                   content.width, content.height, shape.width, shape.height, left, right, bottom)
        }
    }

    // MARK: Rendering as the app composes it

    /// Draws `view` offscreen in a borderless window that is never shown.
    func snapshot(_ view: some View, size: CGSize) throws -> NSBitmapImageRep {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    /// The expanded notch showing `content`, with `band` over the notch, measured and placed by the
    /// host. Writes `R15-render-<name>-T74.png` when NOTCH_RENDER_DIR is set.
    func measure(_ name: String, minWidth: CGFloat = 0, _ content: some View, band: @escaping (CGFloat) -> some View = { _ in EmptyView() }) async throws -> Gaps {
        let measured = IntrinsicSizeLayout(maxSize: NotchSizing.maxContentSize) { content }
        let contentSize = NSHostingView(rootView: measured.environment(\.colorScheme, .dark)).fittingSize
        let metrics = NotchLayout.metrics(for: .expanded, notch: Self.notch, hasActivity: false, content: contentSize, minWidth: minWidth)
        let canvas = CGSize(width: metrics.size.width + 2 * Self.margin, height: metrics.size.height + Self.margin)
        let rep = try snapshot(
            NotchSurface(metrics: metrics) { measured } band: { band(metrics.size.width) }
                .frame(width: canvas.width, height: canvas.height, alignment: .top)
                .background(Self.backdrop),
            size: canvas
        )
        if let directory = ProcessInfo.processInfo.environment["NOTCH_RENDER_DIR"] {
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("R15-render-\(name)-T74.png"))
        }
        // Off the main actor: scanning the pixels of a debug build takes a while, and other suites'
        // main-actor tests wait on deadlines meanwhile.
        let image = try #require(rep.cgImage)
        let scale = CGFloat(image.width) / rep.size.width
        var gaps = try #require(await Task.detached { Self.inkGaps(image, scale: scale) }.value, "no content ink in \(name)")
        gaps.content = contentSize
        gaps.shape = metrics.size
        print("R15 \(name): \(gaps)")
        return gaps
    }

    /// As the end-to-end capture measures: the shape's side walls on a row just under the notch
    /// band, its bottom on the centre column, and the outermost content ink (any channel at least
    /// 14) inside it, leaving out the rounded bottom corners.
    nonisolated static func inkGaps(_ image: CGImage, scale: CGFloat) -> Gaps? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        func brightness(_ x: Int, _ y: Int) -> Int {
            let i = (y * width + x) * 4
            return Int(max(pixels[i], pixels[i + 1], pixels[i + 2]))
        }
        let px = { (points: CGFloat) in Int((points * scale).rounded()) }
        let center = width / 2
        let row = px(Self.notch.height + 4)
        var left = center, right = center
        while left > 0 && brightness(left - 1, row) <= 60 { left -= 1 }
        while right < width - 1 && brightness(right + 1, row) <= 60 { right += 1 }
        // From the backdrop under the shape up to its last black row.
        var bottom = height - 1
        while bottom > 0 && brightness(center, bottom) > 60 { bottom -= 1 }

        let corner = px(NotchLayout.openBottom)
        var minX = width, maxX = 0, maxY = 0
        for y in 0..<(bottom - corner) {
            for x in (left + 2)...(right - 2) where brightness(x, y) >= 14 {
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
        for y in 0..<bottom {
            for x in (left + corner)...(right - corner) where brightness(x, y) >= 14 {
                maxY = max(maxY, y)
            }
        }
        guard maxX > minX else { return nil }
        return Gaps(
            content: .zero,
            shape: .zero,
            left: CGFloat(minX - left) / scale,
            right: CGFloat(right - maxX) / scale,
            bottom: CGFloat(bottom - maxY) / scale
        )
    }

    func expectEqualPadding(_ gaps: Gaps, _ name: String) {
        for (side, gap) in [("left", gaps.left), ("right", gaps.right), ("bottom", gaps.bottom)] {
            #expect(abs(gap - NotchSizing.padding) <= 2, "\(name) \(side) gap \(gap) pt: \(gaps)")
        }
    }

    /// A plugin's screen as the host shows it: the back control over the plugin's tab view.
    func pluginScreen(_ name: String, _ tab: some View) -> some View {
        PluginScreenView(
            host: NotchHostModel(),
            plugin: HomePlugin(pluginID: "com.example.\(name)", name: name, symbol: "square", tab: nil, tile: nil),
            tab: PluginTab(title: name, symbol: "square") { tab }
        )
    }

    // MARK: Screens

    @Test func R15__the_home_keeps_the_same_padding_on_every_side() async throws {
        let fixture = try PluginFixture()
        defer { fixture.cleanUp() }
        try fixture.makeShaped("Agents", .init(name: "코딩 에이전트", symbol: "apple.terminal", tab: true))
        try fixture.makeShaped("Battery", .init(name: "배터리", symbol: "battery.100percent", tab: true, sizes: [.small, .wide]))
        try fixture.makeShaped("Clipboard", .init(name: "클립보드", symbol: "doc.on.clipboard", tab: true, sizes: [.wide, .small]))
        try fixture.makeShaped("MediaKeys", .init(name: "볼륨과 밝기", symbol: "speaker.wave.2.fill", tab: true, sizes: [.small, .wide]))
        try fixture.makeShaped("NowPlaying", .init(name: "지금 재생 중", symbol: "music.note", tab: true, sizes: [.wide, .small]))
        try fixture.makeShaped("SystemStats", .init(name: "시스템 상태", symbol: "cpu", tab: true, sizes: [.small, .wide, .large]))
        let (catalog, host) = fixture.shapedCatalog()
        catalog.loadAll()
        let minWidth = BandLayout.minimumWidth(notch: Self.notch, leading: HomeChrome.editWidth, trailing: HomeChrome.gearWidth)
        let gaps = try await measure("home", minWidth: minWidth, HomeView(host: host)) { width in
            HomeBand(home: host.home, notchSize: Self.notch, width: width, openSettings: {})
        }
        expectEqualPadding(gaps, "home")
    }

    @Test func R15__the_battery_screen_keeps_the_same_padding_on_every_side() async throws {
        let gaps = try await measure("battery", pluginScreen("배터리", BatteryStandIn()))
        expectEqualPadding(gaps, "battery")
    }

    @Test func R15__the_volume_and_brightness_screen_keeps_the_same_padding_on_every_side() async throws {
        let gaps = try await measure("mediakeys", pluginScreen("볼륨과 밝기", MediaKeysStandIn()))
        expectEqualPadding(gaps, "mediakeys")
    }

    @Test func R15__the_now_playing_screen_keeps_the_same_padding_on_every_side() async throws {
        let gaps = try await measure("nowplaying", pluginScreen("지금 재생 중", NowPlayingStandIn()))
        expectEqualPadding(gaps, "nowplaying")
    }

    @Test func R15__the_now_playing_screen_keeps_the_same_padding_on_every_side_while_a_track_plays() async throws {
        let gaps = try await measure("nowplaying-track", pluginScreen("지금 재생 중", NowPlayingTrackStandIn()))
        expectEqualPadding(gaps, "nowplaying-track")
    }

    @Test func R15__the_clipboard_screen_keeps_the_same_padding_on_every_side() async throws {
        let gaps = try await measure("clipboard", pluginScreen("클립보드", ClipboardStandIn()))
        expectEqualPadding(gaps, "clipboard")
    }

    @Test func R15__the_clipboard_screen_keeps_the_same_padding_on_every_side_with_a_short_history() async throws {
        let gaps = try await measure("clipboard-rows", pluginScreen("클립보드", ClipboardRowsStandIn()))
        expectEqualPadding(gaps, "clipboard-rows")
    }

    @Test func R15__the_system_stats_screen_keeps_the_same_padding_on_every_side() async throws {
        let gaps = try await measure("systemstats", pluginScreen("시스템 상태", SystemStatsStandIn()))
        expectEqualPadding(gaps, "systemstats")
    }
}

// MARK: Stand-ins: each repeats its plugin's tab view layout (Plugins/<Name>/Sources) with fixed values.

/// `BatteryView`, fully charged.
private struct BatteryStandIn: View {
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "battery.100percent")
                .font(.system(size: 44))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.primary)
            VStack(alignment: .leading, spacing: 4) {
                Text("100%")
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("완전히 충전됨")
                    .font(.headline)
            }
        }
    }
}

/// `MediaKeysView` with a volume and a brightness.
private struct MediaKeysStandIn: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            group("볼륨") {
                HStack(spacing: 10) {
                    Toggle(isOn: .constant(false)) { Image(systemName: "speaker.wave.1.fill") }
                        .toggleStyle(.button)
                        .frame(width: 28)
                    Slider(value: .constant(0.06), in: 0...1) { Text("볼륨") }
                        .labelsHidden()
                        .frame(width: 200)
                    Text("6%")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
            group("밝기") {
                HStack(spacing: 10) {
                    Image(systemName: "sun.max.fill")
                        .frame(width: 28)
                    Slider(value: .constant(0.5), in: 0...1) { Text("밝기") }
                        .labelsHidden()
                        .frame(width: 200)
                    Text("50%")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
    }

    private func group(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

/// `NowPlayingView` with nothing playing, as on the end-to-end capture.
private struct NowPlayingStandIn: View {
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Color.white.opacity(0.12)
                Image(systemName: "music.note")
                    .font(.system(size: 88 * 0.45, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 88, height: 88)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text("재생 중인 음악이 없어요.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// `NowPlayingView` while a track plays (grey art).
private struct NowPlayingTrackStandIn: View {
    var body: some View {
        HStack(spacing: 14) {
            Color.white.opacity(0.3)
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("Hey Jude")
                    .font(.headline)
                Text("The Beatles")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                VStack(spacing: 3) {
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.15))
                        Capsule().frame(width: 230 * 0.4)
                    }
                    .frame(width: 230, height: 4)
                    HStack {
                        Text("1:23")
                        Spacer(minLength: 0)
                        Text("7:11")
                    }
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 230)
                }
                .padding(.top, 4)
                HStack(spacing: 24) {
                    transport("backward.fill", size: 16)
                    transport("pause.fill", size: 22)
                    transport("forward.fill", size: 16)
                }
                .frame(width: 230)
            }
            .lineLimit(1)
            .frame(width: 230, alignment: .leading)
        }
    }

    /// `TransportButton`'s label.
    private func transport(_ symbol: String, size: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .frame(width: size + 12, height: size)
    }
}

/// `ClipboardView` with an empty history, as on the end-to-end capture.
private struct ClipboardStandIn: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ClipboardSearchStandIn()
            Text("복사한 텍스트, 이미지, 링크가 여기에 쌓여요.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 360)
        }
        .frame(width: 360)
    }
}

/// `ClipboardView` with two text entries, not hovered: each row on its resting background.
private struct ClipboardRowsStandIn: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ClipboardSearchStandIn()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    row("회의 메모", "방금")
                    row("https://example.com", "3분 전")
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 180)
        }
        .frame(width: 360)
    }

    /// `ClipRow`.
    private func row(_ preview: String, _ time: String) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "text.alignleft")
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 20)
                Text(preview)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(time)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Image(systemName: "pin")
                .foregroundStyle(.secondary)
            Image(systemName: "xmark")
                .opacity(0)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.08)))
    }
}

/// `ClipboardView`'s search field, empty.
private struct ClipboardSearchStandIn: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("기록 검색", text: .constant(""))
                .textFieldStyle(.plain)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.1)))
    }
}

/// `SystemStatsView` before the first reading: six cards of a fixed width in a 2 x 3 grid.
private struct SystemStatsStandIn: View {
    var body: some View {
        VStack(spacing: 6) {
            ForEach(0..<3) { row in
                HStack(spacing: 6) {
                    ForEach(0..<2) { column in
                        card(["CPU", "GPU", "메모리", "디스크", "네트워크", "센서"][row * 2 + column])
                    }
                }
            }
        }
    }

    private func card(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("—")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }
            Color.clear.frame(height: 20)
            Text("—")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(height: 13, alignment: .leading)
        }
        .padding(6)
        .frame(width: 188, alignment: .topLeading)
        .lineLimit(1)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}
