import AppKit
import Foundation
import NotchKit
import SwiftUI
import Testing
@testable import NotchTheRock

/// Attentions drawn offscreen by the app's root view: the top row splits around the camera like a
/// plugin screen's band, the source icon and the title left of the camera and the countdown and the
/// close button right of it, with nothing under the camera housing; the message, the choices and
/// the buttons sit below with the host's 18-pt margin.
@MainActor
@Suite struct AttentionBandRenderTests {
    nonisolated static let notch = NotchPaddingRenderTests.notch
    /// Blue like the menu bar around the shape (`NotchPaddingRenderTests.backdrop`).
    static let backdrop = Color(red: 0, green: 0.2, blue: 1)
    /// Blue, so the countdown is told from the white title and close button.
    static let accent = Color(red: 0.1, green: 0.35, blue: 1)
    /// The agent notice's shape height as the host drew it before the title and the countdown moved
    /// beside the camera (f1d2e40).
    static let oldAgentNoticeHeight: CGFloat = 189

    /// A drawn source icon: a green disc, so its pixels are told from the white text.
    static var icon: Image {
        let image = NSImage(size: NSSize(width: 40, height: 40), flipped: false) { rect in
            NSColor(red: 0, green: 0.9, blue: 0, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        return Image(nsImage: image)
    }

    /// Like the agents' notice when Claude Code finishes a turn.
    static var agentNotice: AttentionRequest {
        AttentionRequest(
            title: "briefs", message: "Claude Code가 작업을 마쳤어요.", accent: accent, sourceIcon: icon,
            buttons: [AttentionButton(id: "open", title: "터미널로 이동", role: .primary)], timeout: .seconds(30)
        )
    }

    static var plainNotice: AttentionRequest {
        AttentionRequest(
            title: "알림", message: "내려받기가 끝났어요.", accent: accent,
            buttons: [AttentionButton(id: "ok", title: "확인", role: .primary)], timeout: .seconds(30)
        )
    }

    static var approval: AttentionRequest {
        AttentionRequest(
            title: "아주 긴 이름의 프로젝트에서 보낸 승인 요청이라 카메라 앞에서 잘려야 하는 제목이에요 끝까지 다 보이면 안 돼요",
            message: "Bash 명령을 실행해도 될까요?", accent: accent, sourceIcon: icon,
            choices: [AttentionChoices(id: "answer", prompt: "", options: ["허용", "이번 세션 동안 허용", "거부"])],
            releaseTitle: "터미널에서 답하기", timeout: .seconds(60)
        )
    }

    /// What the render shows, in points from the canvas's left edge and top.
    struct Drawn: CustomStringConvertible {
        var shape: CGSize
        var cameraLeft: CGFloat
        var cameraRight: CGFloat
        /// The shape's left side wall.
        var wallLeft: CGFloat
        /// Ink in the band beside the camera: the green icon, the white title left of the camera,
        /// the accent countdown and the white close button right of it.
        var icon: CGRect?
        var title: CGRect?
        var countdown: CGRect?
        var close: CGRect?
        /// Ink pixels under the camera housing: there must be none.
        var stray: Int

        var description: String {
            func box(_ rect: CGRect?) -> String {
                rect.map { String(format: "x %.1f–%.1f y %.1f–%.1f", $0.minX, $0.maxX, $0.minY, $0.maxY) } ?? "none"
            }
            return String(format: "shape %.1f x %.1f, camera %.1f–%.1f, wall %.1f; ", shape.width, shape.height, cameraLeft, cameraRight, wallLeft)
                + "icon \(box(icon)), title \(box(title)), countdown \(box(countdown)), close \(box(close)), stray \(stray)"
        }
    }

    /// Asks the host for `request` and draws the root view over `backdrop` until the shape and its
    /// contents settle. Writes `<file>.png`, `R46-render-<name>-T139.png` by default, when
    /// NOTCH_RENDER_DIR is set.
    func draw(
        _ name: String, _ request: AttentionRequest, backdrop: Color = Self.backdrop, file: String? = nil
    ) async throws -> (image: CGImage, scale: CGFloat, metrics: NotchLayout.Metrics) {
        let host = NotchHostModel()
        let answer = Task { await host.requestAttention(request, from: "com.example.agents") }
        defer { answer.cancel() }
        for _ in 0..<100 where host.state != .attention { await Task.yield() }
        try #require(host.state == .attention)
        var targets: [NotchLayout.Metrics] = []
        var drawn: NotchLayout.Metrics?
        let root = NotchRootView(host: host, notchSize: Self.notch, openSettings: { _ in },
                                 metricsChanged: { targets.append($0) }, shapeDrawn: { drawn = $0 })
        let size = NotchLayout.canvasSize
        let hosting = NSHostingView(rootView: root.background(backdrop).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        // The countdown ticks, so only the shape's inside away from it is compared between captures.
        var previous: [UInt8]?
        var settled: (CGImage, NotchLayout.Metrics)?
        for _ in 0..<60 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            let capture = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: capture)
            guard let image = capture.cgImage, targets.count > 1, let target = targets.last, drawn == target else { continue }
            let inside = Self.inside(image, scale: CGFloat(image.width) / size.width, shape: target.size)
            if inside == previous {
                settled = (image, target)
                break
            }
            previous = inside
        }
        let (image, metrics) = try #require(settled, "the attention did not settle: \(targets.count) targets, drawn \(String(describing: drawn))")
        if let directory = ProcessInfo.processInfo.environment["NOTCH_RENDER_DIR"] {
            let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("\(file ?? "R46-render-\(name)-T139").png"))
        }
        return (image, CGFloat(image.width) / size.width, metrics)
    }

    /// The shape's pixels inside its side walls and above its rounded bottom, without the right
    /// wing's band row, where the countdown changes every second.
    nonisolated static func inside(_ image: CGImage, scale: CGFloat, shape: CGSize) -> [UInt8] {
        let center = CGFloat(image.width) / 2
        let half = (shape.width / 2 - NotchLayout.openShoulder - 2) * scale
        let rect = CGRect(x: center - half, y: 0, width: half * 2, height: (shape.height - NotchLayout.openBottom) * scale).integral
        guard let crop = image.cropping(to: rect) else { return [] }
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        guard let context = CGContext(
            data: &pixels, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: crop.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        let bandRows = Int((notch.height * scale).rounded(.up)) * crop.width * 4
        let cameraRight = Int((center + notch.width / 2 * scale) - rect.minX) * 4
        for row in stride(from: 0, to: bandRows, by: crop.width * 4) {
            for i in (row + cameraRight)..<(row + crop.width * 4) { pixels[i] = 0 }
        }
        return pixels
    }

    /// The band's ink beside the camera, sorted by colour: green is the icon, blue the countdown's
    /// seconds, grey to white (channels within 40 of each other, the brightest at least 60) the
    /// title left of the camera and, right of it, the close button after the seconds. The
    /// countdown's timer symbol comes before the seconds and counts with them: an offscreen render
    /// draws SF Symbols white whatever their style. Any channel of at least 30 under the camera
    /// housing is stray.
    nonisolated static func measure(_ image: CGImage, scale: CGFloat, shape: CGSize) -> Drawn {
        let width = image.width
        var pixels = [UInt8](repeating: 0, count: width * image.height * 4)
        if let context = CGContext(
            data: &pixels, width: width, height: image.height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))
        }
        let center = CGFloat(width) / 2
        let cameraLeft = Int(center - notch.width / 2 * scale), cameraRight = Int(center + notch.width / 2 * scale)
        let wallLeft = Int(center - (shape.width / 2 - NotchLayout.openShoulder) * scale)
        let wallRight = Int(center + (shape.width / 2 - NotchLayout.openShoulder) * scale)
        var icon: CGRect?, title: CGRect?, countdown: CGRect?, close: CGRect?
        var stray = 0
        var rightWhite: [(Int, Int)] = []
        func add(_ x: Int, _ y: Int, to box: inout CGRect?) {
            let pixel = CGRect(x: CGFloat(x) / scale, y: CGFloat(y) / scale, width: 1 / scale, height: 1 / scale)
            box = box?.union(pixel) ?? pixel
        }
        for y in 0..<Int(notch.height * scale) {
            for x in (wallLeft + 2)...(wallRight - 2) {
                let i = (y * width + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                let high = max(r, g, b), low = min(r, g, b)
                if x >= cameraLeft && x <= cameraRight {
                    if high >= 30 { stray += 1 }
                } else if g - max(r, b) > 40 {
                    add(x, y, to: &icon)
                } else if b - max(r, g) > 40 {
                    add(x, y, to: &countdown)
                } else if high >= 60 && high - low <= 40 {
                    if x < cameraLeft { add(x, y, to: &title) } else { rightWhite.append((x, y)) }
                }
            }
        }
        let seconds = countdown.map { Int(($0.maxX * scale).rounded()) } ?? cameraRight
        for (x, y) in rightWhite {
            if x >= seconds { add(x, y, to: &close) } else { add(x, y, to: &countdown) }
        }
        return Drawn(
            shape: shape, cameraLeft: CGFloat(cameraLeft) / scale, cameraRight: CGFloat(cameraRight) / scale,
            wallLeft: CGFloat(wallLeft) / scale, icon: icon, title: title, countdown: countdown, close: close, stray: stray
        )
    }

    func band(_ name: String, _ request: AttentionRequest) async throws -> Drawn {
        let (image, scale, metrics) = try await draw(name, request)
        let drawn = await Task.detached { Self.measure(image, scale: scale, shape: metrics.size) }.value
        print("R46 \(name): \(drawn)")
        return drawn
    }

    /// The countdown and then the close button right of the camera, nothing under the housing.
    func expectRightWing(_ drawn: Drawn, _ name: String) throws {
        let countdown = try #require(drawn.countdown, "\(name): no countdown beside the camera: \(drawn)")
        let close = try #require(drawn.close, "\(name): no close button beside the camera: \(drawn)")
        #expect(countdown.minX > drawn.cameraRight, "\(name): \(drawn)")
        #expect(close.minX > countdown.maxX, "\(name): the close button is not right of the countdown: \(drawn)")
        #expect(drawn.stray == 0, "\(name): \(drawn.stray) ink pixels under the camera housing: \(drawn)")
    }

    @Test func R46__an_agent_notice_puts_its_icon_and_title_left_of_the_camera_and_is_lower() async throws {
        let drawn = try await band("agent-notice", Self.agentNotice)
        let icon = try #require(drawn.icon, "no icon beside the camera: \(drawn)")
        let title = try #require(drawn.title, "no title beside the camera: \(drawn)")
        #expect((17...21).contains(icon.height), "icon \(icon.height) pt tall: \(drawn)")
        #expect(abs(icon.minX - drawn.wallLeft - NotchSizing.padding) <= 2, "icon not at the left inset: \(drawn)")
        #expect(icon.maxX < title.minX, "the title is not right of the icon: \(drawn)")
        #expect(title.maxX < drawn.cameraLeft - BandLayout.cameraClearance + 2, "\(drawn)")
        try expectRightWing(drawn, "agent notice")
        #expect(drawn.shape.height < Self.oldAgentNoticeHeight, "shape \(drawn.shape.height) pt, before \(Self.oldAgentNoticeHeight) pt")
    }

    @Test func R46__a_notice_without_an_icon_starts_its_title_at_the_left_inset() async throws {
        let drawn = try await band("plain-notice", Self.plainNotice)
        let title = try #require(drawn.title, "no title beside the camera: \(drawn)")
        #expect(drawn.icon == nil, "\(drawn)")
        #expect(abs(title.minX - drawn.wallLeft - NotchSizing.padding) <= 2, "title not at the left inset: \(drawn)")
        #expect(title.maxX < drawn.cameraLeft - BandLayout.cameraClearance + 2, "\(drawn)")
        try expectRightWing(drawn, "plain notice")
    }

    @Test func R46__a_long_request_title_is_cut_short_before_the_camera() async throws {
        let drawn = try await band("approval", Self.approval)
        let icon = try #require(drawn.icon, "no icon beside the camera: \(drawn)")
        let title = try #require(drawn.title, "no title beside the camera: \(drawn)")
        #expect(icon.maxX < title.minX, "\(drawn)")
        // Cut short: it runs up to the camera's clearance and no further.
        #expect(title.maxX < drawn.cameraLeft - BandLayout.cameraClearance + 2, "the title runs under the camera: \(drawn)")
        #expect(title.maxX > drawn.cameraLeft - BandLayout.cameraClearance - 16, "the title stops short of the camera: \(drawn)")
        #expect(drawn.shape.width == NotchSizing.maxWidth, "\(drawn)")
        try expectRightWing(drawn, "approval")
    }

    @Test func R46__attentions_keep_the_18_pt_margin_on_every_side() async throws {
        for (name, request) in [("agent-notice", Self.agentNotice), ("plain-notice", Self.plainNotice), ("approval", Self.approval)] {
            let (image, scale, metrics) = try await draw(name, request)
            let gaps = try #require(await Task.detached { NotchPaddingRenderTests.inkGaps(image, scale: scale) }.value, "no ink in \(name)")
            print("R46 \(name) margins: \(gaps), shape \(metrics.size)")
            for (side, gap) in [("left", gaps.left), ("right", gaps.right), ("bottom", gaps.bottom)] {
                #expect(abs(gap - NotchPaddingRenderTests.edgePadding) <= 2, "\(name) \(side) gap \(gap) pt: \(gaps)")
            }
        }
    }

    /// Pixels outside the shape, more than 2 px past its edges, whose red runs more than 20 above
    /// their blue: the warm accent tinting the light grey backdrop.
    nonisolated static func tinted(_ image: CGImage, scale: CGFloat, shape: CGSize) -> Int {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return -1 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let center = CGFloat(width) / 2
        let left = Int(center - shape.width / 2 * scale) - 2, right = Int(center + shape.width / 2 * scale) + 2
        let bottom = Int(shape.height * scale) + 2
        var count = 0
        for y in 0..<height {
            for x in 0..<width where x < left || x > right || y > bottom {
                let i = (y * width + x) * 4
                if Int(pixels[i]) - Int(pixels[i + 2]) > 20 { count += 1 }
            }
        }
        return count
    }

    @Test func R47__an_agent_notice_draws_nothing_outside_the_notch_shape() async throws {
        var notice = Self.agentNotice
        notice.accent = Color(red: 0.85, green: 0.47, blue: 0.34)
        let (image, scale, metrics) = try await draw("agent-notice", notice, backdrop: Color(white: 0.92), file: "R47-render-after-T141")
        let tinted = await Task.detached { Self.tinted(image, scale: scale, shape: metrics.size) }.value
        print("R47 agent notice over light grey: shape \(metrics.size), \(tinted) accent-tinted pixels outside it")
        #expect(tinted == 0, "\(tinted) accent-tinted pixels outside the shape")
    }
}
