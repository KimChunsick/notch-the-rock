import AppKit
import Foundation
import NotchKit
import SwiftUI
import Testing
@testable import NotchTheRock

/// The visible gaps between what the expanded notch draws and the shape's edges, measured on an
/// offscreen render the way the end-to-end capture measures them. The host's composition is the
/// app's own (`NotchSurface`, `IntrinsicSizeLayout`, `NotchLayout.metrics`, `HomeView`, `HomeBand`,
/// `PluginBand`). The root package cannot import the plugin packages, and activating the real
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
    /// host; `fill` is the width a plugin's screen is offered when it is narrower. Writes
    /// `R15-render-<name>-T102.png` when NOTCH_RENDER_DIR is set.
    func measure(_ name: String, minWidth: CGFloat = 0, fill: CGFloat = 0, _ content: some View, band: @escaping (CGFloat) -> some View = { _ in EmptyView() }) async throws -> Gaps {
        let measured = IntrinsicSizeLayout(maxSize: NotchSizing.maxContentSize, minWidth: fill) { content }
        let contentSize = NSHostingView(rootView: measured.environment(\.colorScheme, .dark)).fittingSize
        let metrics = NotchLayout.metrics(for: .expanded, notch: Self.notch, content: contentSize, minWidth: minWidth)
        let canvas = CGSize(width: metrics.size.width + 2 * Self.margin, height: metrics.size.height + Self.margin)
        let rep = try snapshot(
            NotchSurface(metrics: metrics) { measured } band: { band(metrics.size.width) }
                .frame(width: canvas.width, height: canvas.height, alignment: .top)
                .background(Self.backdrop),
            size: canvas
        )
        if let directory = ProcessInfo.processInfo.environment["NOTCH_RENDER_DIR"] {
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("R15-render-\(name)-T102.png"))
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
    /// 14) inside it. Along the rounded bottom corners only what lies inside the shape on that row
    /// counts, so a short screen's last row is measured too.
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
        // The backdrop is blue with no red; the shape and its antialiased edge are not.
        func isBackdrop(_ x: Int, _ y: Int) -> Bool {
            let i = (y * width + x) * 4
            return Int(pixels[i + 2]) - Int(pixels[i]) > 100
        }
        for y in 0..<bottom {
            var rowLeft = left, rowRight = right
            if y >= bottom - corner {
                while rowLeft < center && isBackdrop(rowLeft, y) { rowLeft += 1 }
                while rowRight > center && isBackdrop(rowRight, y) { rowRight -= 1 }
            }
            guard rowLeft + 2 <= rowRight - 2 else { continue }
            for x in (rowLeft + 2)...(rowRight - 2) where brightness(x, y) >= 14 {
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

    /// A plugin's screen as the host shows it: the plugin's tab view under the band, which holds ‹
    /// and the plugin's name left of the camera and, with a settings page, the gear right of it.
    func measureScreen(_ name: String, _ pluginName: String, hasSettings: Bool, _ tab: some View) async throws -> Gaps {
        let plugin = HomePlugin(pluginID: "com.example.\(name)", name: pluginName, symbol: "square", tab: nil, tile: nil, hasSettings: hasSettings)
        let host = NotchHostModel()
        let bandWidth = PluginBand.minimumWidth(notch: Self.notch, plugin: plugin)
        return try await measure(name, minWidth: bandWidth, fill: NotchSizing.contentWidth(filling: bandWidth), tab) { width in
            PluginBand(host: host, plugin: plugin, notchSize: Self.notch, width: width, openSettings: { _ in })
        }
    }

    /// The same padding on every side: when the band needs a wider shape for the plugin's name than
    /// for its view, the host offers the view the width between the shape's paddings and the view
    /// spreads across it.
    func expectScreenPadding(_ gaps: Gaps, _ name: String) {
        expectEqualPadding(gaps, name)
    }

    /// A view that keeps its own width under a wider band (a third-party view, or a message alone)
    /// stays centred under the camera: the back control keeps the padding on the left and nothing
    /// comes closer on the right.
    func expectCentredScreen(_ gaps: Gaps, _ name: String) {
        #expect(abs(gaps.left - NotchSizing.padding) <= 2, "\(name) left gap \(gaps.left) pt: \(gaps)")
        #expect(abs(gaps.bottom - NotchSizing.padding) <= 2, "\(name) bottom gap \(gaps.bottom) pt: \(gaps)")
        #expect(gaps.right >= NotchSizing.padding - 2, "\(name) right gap \(gaps.right) pt: \(gaps)")
    }

    // MARK: Screens

    @Test func R15__the_home_keeps_the_same_padding_on_every_side() async throws {
        let fixture = try PluginFixture()
        defer { fixture.cleanUp() }
        try fixture.makeShaped("Agents", .init(name: "코딩 에이전트", symbol: "apple.terminal", tab: true))
        try fixture.makeShaped("Battery", .init(name: "배터리", symbol: "battery.100percent", tab: true, sizes: [.small, .wide]))
        try fixture.makeShaped("Clipboard", .init(name: "클립보드", symbol: "doc.on.clipboard", tab: true, sizes: [.wide, .small]))
        try fixture.makeShaped("Brightness", .init(name: "밝기", symbol: "sun.max.fill", tab: true, sizes: [.small, .wide]))
        try fixture.makeShaped("NowPlaying", .init(name: "지금 재생 중", symbol: "music.note", tab: true, sizes: [.wide, .small]))
        try fixture.makeShaped("SystemStats", .init(name: "시스템 상태", symbol: "cpu", tab: true, sizes: [.small, .wide, .large]))
        try fixture.makeShaped("Volume", .init(name: "볼륨", symbol: "speaker.wave.2.fill", tab: true, sizes: [.small, .wide]))
        let (catalog, host) = fixture.shapedCatalog()
        catalog.loadAll()
        let minWidth = BandLayout.minimumWidth(notch: Self.notch, leading: HomeChrome.editWidth, trailing: HomeChrome.gearWidth)
        let gaps = try await measure("home", minWidth: minWidth, HomeView(host: host)) { width in
            HomeBand(home: host.home, notchSize: Self.notch, width: width, openSettings: { _ in })
        }
        expectEqualPadding(gaps, "home")
    }

    @Test func R15__the_battery_screen_keeps_the_same_padding_on_every_side() async throws {
        let gaps = try await measureScreen("battery", "배터리", hasSettings: false, BatteryStandIn())
        expectScreenPadding(gaps, "battery")
    }

    @Test func R15__the_volume_screen_keeps_the_same_padding_on_every_side() async throws {
        let gaps = try await measureScreen("volume", "볼륨", hasSettings: true, VolumeStandIn())
        expectScreenPadding(gaps, "volume")
    }

    @Test func R15__the_brightness_screen_keeps_the_same_padding_on_every_side() async throws {
        let gaps = try await measureScreen("brightness", "밝기", hasSettings: true, BrightnessStandIn())
        expectScreenPadding(gaps, "brightness")
    }

    @Test func R15__the_now_playing_screen_keeps_the_same_padding_on_every_side() async throws {
        let gaps = try await measureScreen("nowplaying", "지금 재생 중", hasSettings: false, NowPlayingStandIn())
        expectCentredScreen(gaps, "nowplaying")
    }

    @Test func R15__the_now_playing_screen_keeps_the_same_padding_on_every_side_while_a_track_plays() async throws {
        let gaps = try await measureScreen("nowplaying-track", "지금 재생 중", hasSettings: false, NowPlayingTrackStandIn())
        expectScreenPadding(gaps, "nowplaying-track")
    }

    @Test func R15__the_clipboard_screen_keeps_the_same_padding_on_every_side() async throws {
        let gaps = try await measureScreen("clipboard", "클립보드", hasSettings: true, ClipboardStandIn())
        expectScreenPadding(gaps, "clipboard")
    }

    @Test func R15__the_clipboard_screen_keeps_the_same_padding_on_every_side_with_a_short_history() async throws {
        let gaps = try await measureScreen("clipboard-rows", "클립보드", hasSettings: true, ClipboardRowsStandIn())
        expectScreenPadding(gaps, "clipboard-rows")
    }

    @Test func R15__the_system_stats_screen_keeps_the_same_padding_on_every_side() async throws {
        let gaps = try await measureScreen("systemstats", "시스템 상태", hasSettings: false, SystemStatsStandIn())
        expectScreenPadding(gaps, "systemstats")
    }

    /// A view of a fixed width, narrower than the band's room, that ignores the wider offer: it keeps
    /// its width and stays centred under the camera, the documented fallback.
    @Test func R15__a_fixed_width_screen_stays_centred_under_a_wider_band() async throws {
        let gaps = try await measureScreen("fixed", "고정된 화면이에요", hasSettings: false, Color.white.frame(width: 160, height: 60))
        expectCentredScreen(gaps, "fixed")
        #expect(abs(gaps.content.width - 160) <= 0.5, "the fixed view took the offer: \(gaps)")
        let centred = (gaps.shape.width - gaps.content.width) / 2 - NotchLayout.openShoulder
        #expect(abs(gaps.right - centred) <= 2, "fixed view not centred under the camera: right gap \(gaps.right) pt, centred \(centred) pt: \(gaps)")
        #expect(gaps.right > NotchSizing.padding + 2, "the band is not wider than the fixed view: \(gaps)")
    }

    /// Under the band with a narrow view that fills what it is offered, the shape is exactly as wide
    /// as the band needs, and a second layout pass leaves it there: the offer comes from the band's
    /// width, not from the measured view, so the shape never creeps.
    @Test func R15__a_filling_screen_keeps_the_band_width_across_layout_passes() async throws {
        let fixture = HomeDefaults()
        defer { fixture.cleanUp() }
        let plugin = HomePlugin(
            pluginID: "com.example.battery", name: "배터리", symbol: "battery.100percent",
            tab: PluginTab(title: "배터리", symbol: "battery.100percent") { BatteryStandIn() }, tile: nil
        )
        let host = NotchHostModel(now: { .now }, pinnedExpansion: true, homeStore: fixture.store)
        host.plugins = [plugin]
        host.open(pluginID: plugin.pluginID)
        var widths: [CGFloat] = []
        let root = NotchRootView(host: host, notchSize: Self.notch, openSettings: { _ in }, metricsChanged: { widths.append($0.size.width) })
        let hosting = NSHostingView(rootView: root.environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: NotchLayout.canvasSize), styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: NotchLayout.canvasSize)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let first = try #require(widths.last, "no metrics reported")
        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let second = try #require(widths.last)
        let band = PluginBand.minimumWidth(notch: Self.notch, plugin: plugin)
        print("R15 band width \(band) pt, shape \(first) then \(second) pt: \(widths)")
        #expect(abs(first - band) <= 0.5, "shape \(first) pt under a band of \(band) pt")
        #expect(first == second, "the shape moved on the second pass: \(widths)")
    }
}

// MARK: Stand-ins: each repeats its plugin's tab view layout (Plugins/<Name>/Sources) with fixed values.

/// `BatteryView`, fully charged: the symbol and the percentage at either end of what it is offered.
struct BatteryStandIn: View {
    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "battery.100percent")
                .font(.system(size: 44))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.primary)
            Spacer(minLength: 16)
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

/// `VolumeView` with a volume: the slider stretches across what it is offered.
private struct VolumeStandIn: View {
    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: .constant(false)) { Image(systemName: "speaker.wave.1.fill") }
                .toggleStyle(.button)
                .frame(width: 28)
            Slider(value: .constant(0.06), in: 0...1) { Text("볼륨") }
                .labelsHidden()
                .frame(minWidth: 200, idealWidth: 200, maxWidth: .infinity)
            Text("6%")
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
    }
}

/// `BrightnessView` with a brightness: the slider stretches across what it is offered.
private struct BrightnessStandIn: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.max.fill")
            Slider(value: .constant(0.5), in: 0...1) { Text("밝기") }
                .labelsHidden()
                .frame(minWidth: 200, idealWidth: 200, maxWidth: .infinity)
            Text("50%")
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
    }
}

/// `NowPlayingView` with nothing playing, as on the end-to-end capture: the message keeps its own
/// width.
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

/// `NowPlayingView` while a track plays (grey art): the column stretches beside the art.
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
                    .frame(height: 4)
                    .frame(minWidth: 230, idealWidth: 230, maxWidth: .infinity)
                    HStack {
                        Text("1:23")
                        Spacer(minLength: 0)
                        Text("7:11")
                    }
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 230, idealWidth: 230, maxWidth: .infinity)
                }
                .padding(.top, 4)
                HStack(spacing: 24) {
                    transport("backward.fill", size: 16)
                    transport("pause.fill", size: 22)
                    transport("forward.fill", size: 16)
                }
                .frame(minWidth: 230, idealWidth: 230, maxWidth: .infinity)
            }
            .lineLimit(1)
            .frame(minWidth: 230, idealWidth: 230, maxWidth: .infinity, alignment: .leading)
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
                .frame(minWidth: 360, idealWidth: 360, maxWidth: .infinity)
        }
        .frame(minWidth: 360, idealWidth: 360, maxWidth: .infinity)
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
        .frame(minWidth: 360, idealWidth: 360, maxWidth: .infinity)
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

/// `SystemStatsView` before the first reading: six cards, each at least 188 pt wide, in a 2 x 3 grid
/// that stretches across what it is offered.
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
        .frame(minWidth: 188, idealWidth: 188, maxWidth: .infinity, alignment: .topLeading)
        .lineLimit(1)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}
