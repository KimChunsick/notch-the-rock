import AppKit
import Foundation
import NotchKit
import SwiftUI
import Testing
@testable import NotchTheRock

/// Attentions drawn offscreen by the app's root view: the top row splits around the camera like a
/// plugin screen's band, the source icon and the title left of the camera and the countdown and the
/// close button right of it, with nothing under the camera housing; the message, the choices and
/// the buttons sit below with the host's 18-pt margin. A title too long for the band is cut short
/// there and shown whole, wrapped, above the message.
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
            title: "아주 긴 이름의 프로젝트에서 보낸 승인 요청이라 카메라 옆에서는 잘리고 본문에서 줄을 바꿔 끝까지 보여야 하는 제목이에요",
            message: "Bash 명령을 실행해도 될까요?", accent: accent, sourceIcon: icon,
            choices: [AttentionChoices(id: "answer", prompt: "", options: ["허용", "이번 세션 동안 허용", "거부"])],
            releaseTitle: "터미널에서 답하기", timeout: .seconds(60)
        )
    }

    static var question: AttentionRequest {
        AttentionRequest(
            title: "다른 긴 이름의 프로젝트에서 보낸 질문이에요 어느 브랜치에 올릴지 정해야 해서 답을 기다리고 있어요",
            message: "올릴 브랜치 이름을 적어 주세요.", accent: accent, sourceIcon: icon,
            textField: AttentionTextField(placeholder: "브랜치 이름"), timeout: .seconds(60)
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
    /// contents settle. Writes `<file>.png`, `R46-render-<name>-T148.png` by default, when
    /// NOTCH_RENDER_DIR is set.
    func draw(
        _ name: String, _ request: AttentionRequest, backdrop: Color = Self.backdrop, file: String? = nil
    ) async throws -> (image: CGImage, scale: CGFloat, metrics: NotchLayout.Metrics) {
        let host = NotchHostModel()
        let answer = Task { await host.requestAttention(request, from: "com.example.agents") }
        defer { answer.cancel() }
        for _ in 0..<100 where host.state != .attention { await Task.yield() }
        try #require(host.state == .attention)
        return try await render(host, backdrop: backdrop, file: file ?? "R46-render-\(name)-T148")
    }

    /// Draws the root view of `host`, which shows an attention, over `backdrop` until the shape and
    /// its contents settle. Writes `<file>.png` when `file` is given and NOTCH_RENDER_DIR is set.
    func render(
        _ host: NotchHostModel, backdrop: Color = Self.backdrop, file: String? = nil
    ) async throws -> (image: CGImage, scale: CGFloat, metrics: NotchLayout.Metrics) {
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
        if let file, let directory = ProcessInfo.processInfo.environment["NOTCH_RENDER_DIR"] {
            let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("\(file).png"))
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

    /// RGBA bytes of `image`, its rows from the top.
    nonisolated static func rgba(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        if let context = CGContext(
            data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    /// The lines of ink inside `rect` (points from the image's top-left), top to bottom, each as the
    /// box around its ink in points from `rect`'s origin. Ink is a channel of at least 60; rows of
    /// ink less than 2 pt apart belong to one line, so a Hangul syllable's parts stay together.
    nonisolated static func lines(_ image: CGImage, scale: CGFloat, in rect: CGRect) -> [CGRect] {
        let pixels = rgba(image)
        let x0 = max(0, Int(rect.minX * scale)), x1 = min(image.width, Int(rect.maxX * scale))
        let y0 = max(0, Int(rect.minY * scale)), y1 = min(image.height, Int(rect.maxY * scale))
        let joins = Int(2 * scale)
        var lines: [CGRect] = []
        var lastInkRow: Int?
        for y in y0..<y1 {
            var minX = Int.max, maxX = Int.min
            for x in x0..<x1 {
                let i = (y * image.width + x) * 4
                if max(pixels[i], pixels[i + 1], pixels[i + 2]) >= 60 { minX = min(minX, x); maxX = max(maxX, x) }
            }
            guard minX <= maxX else { continue }
            let row = CGRect(x: CGFloat(minX - x0) / scale, y: CGFloat(y - y0) / scale, width: CGFloat(maxX - minX + 1) / scale, height: 1 / scale)
            if let lastInkRow, y - lastInkRow <= joins, let last = lines.last {
                lines[lines.count - 1] = last.union(row)
            } else {
                lines.append(row)
            }
            lastInkRow = y
        }
        return lines
    }

    /// The lines `title` makes in the body's title font laid out alone `width` wide, white on black,
    /// as `lines(_:scale:in:)` finds them.
    func titleLines(_ title: String, width: CGFloat, scale: CGFloat) throws -> [CGRect] {
        let text = Text(title)
            .font(AttentionBand.titleFont)
            .foregroundStyle(.white)
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.black)
        let hosting = NSHostingView(rootView: text.environment(\.colorScheme, .dark))
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        let capture = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: capture)
        let image = try #require(capture.cgImage)
        try #require(abs(CGFloat(image.width) / size.width - scale) < 0.01, "the reference is drawn at another scale")
        return Self.lines(image, scale: scale, in: CGRect(origin: .zero, size: size))
    }

    /// The attention's content area in points from the canvas's top-left.
    nonisolated static func content(of metrics: NotchLayout.Metrics) -> CGRect {
        metrics.content.offsetBy(dx: (NotchLayout.canvasSize.width - metrics.size.width) / 2, dy: 0)
    }

    nonisolated static func matches(_ line: CGRect, _ expected: CGRect) -> Bool {
        abs(line.minX - expected.minX) <= 1.5 && abs(line.maxX - expected.maxX) <= 1.5
            && abs(line.minY - expected.minY) <= 1.5 && abs(line.maxY - expected.maxY) <= 1.5
    }

    /// A title too long for the band: the band keeps the icon and the start of the title, cut short
    /// before the camera's clearance, and the body starts with the whole title, wrapped into the same
    /// lines as the title laid out alone at the content's width, the last one ending where that
    /// one does, with the next row of the request below it.
    func expectWholeTitleInBody(_ name: String, _ request: AttentionRequest) async throws {
        let (image, scale, metrics) = try await draw(name, request)
        let drawn = await Task.detached { Self.measure(image, scale: scale, shape: metrics.size) }.value
        let icon = try #require(drawn.icon, "\(name): no icon beside the camera: \(drawn)")
        let bandTitle = try #require(drawn.title, "\(name): no title beside the camera: \(drawn)")
        #expect(icon.maxX < bandTitle.minX, "\(name): \(drawn)")
        #expect(bandTitle.maxX < drawn.cameraLeft - BandLayout.cameraClearance + 2, "\(name): the band title runs under the camera: \(drawn)")
        #expect(drawn.shape.width == NotchSizing.maxWidth, "\(name): \(drawn)")
        try expectRightWing(drawn, name)

        let expected = try titleLines(request.title, width: metrics.content.width, scale: scale)
        let content = Self.content(of: metrics)
        let body = await Task.detached { Self.lines(image, scale: scale, in: content) }.value
        print("R46 \(name): \(drawn); content \(content); title alone \(expected); body \(body)")
        #expect(expected.count >= 2, "\(name): the title fits one line at the content's width: \(expected)")
        #expect(body.count > expected.count, "\(name): body \(body)")
        for (index, line) in expected.enumerated() {
            let found = index < body.count ? body[index] : nil
            #expect(found.map { Self.matches($0, line) } == true, "\(name): title line \(index + 1) \(line), body has \(String(describing: found))")
        }
        if body.count > expected.count {
            let gap = body[expected.count].minY - body[expected.count - 1].maxY
            #expect(gap >= 4, "\(name): the row below the title is \(gap) pt from it")
        }
    }

    @Test func R46__a_long_approval_title_is_cut_short_in_the_band_and_shown_whole_above_the_message() async throws {
        try await expectWholeTitleInBody("long-approval", Self.approval)
    }

    @Test func R46__a_long_question_title_is_cut_short_in_the_band_and_shown_whole_above_its_field() async throws {
        try await expectWholeTitleInBody("long-question", Self.question)
    }

    /// A title that fits the band shows there whole and nowhere in the body.
    @Test func R46__a_short_title_shows_once_in_the_band() async throws {
        for (name, request) in [("agent-notice", Self.agentNotice), ("plain-notice", Self.plainNotice)] {
            let (image, scale, metrics) = try await draw(name, request)
            let drawn = await Task.detached { Self.measure(image, scale: scale, shape: metrics.size) }.value
            let bandTitle = try #require(drawn.title, "\(name): no title beside the camera: \(drawn)")
            let expected = try titleLines(request.title, width: metrics.content.width, scale: scale)
            let whole = try #require(expected.first, "\(name): the title alone draws nothing")
            let content = Self.content(of: metrics)
            let body = await Task.detached { Self.lines(image, scale: scale, in: content) }.value
            print("R46 \(name): band title \(bandTitle), title alone \(expected), body \(body)")
            #expect(expected.count == 1, "\(name): \(expected)")
            #expect(abs(bandTitle.width - whole.width) <= 2, "\(name): the band title is \(bandTitle.width) pt wide, alone \(whole.width) pt")
            #expect(!body.contains { abs($0.width - whole.width) <= 1.5 && abs($0.height - whole.height) <= 1.5 }, "\(name): the title shows in the body too: \(body)")
        }
    }

    @Test func R46__attentions_keep_the_18_pt_margin_on_every_side() async throws {
        for (name, request) in [
            ("agent-notice", Self.agentNotice), ("plain-notice", Self.plainNotice),
            ("long-approval", Self.approval), ("long-question", Self.question),
        ] {
            let (image, scale, metrics) = try await draw(name, request)
            let gaps = try #require(await Task.detached { NotchPaddingRenderTests.inkGaps(image, scale: scale) }.value, "no ink in \(name)")
            print("R46 \(name) margins: \(gaps), shape \(metrics.size)")
            for (side, gap) in [("left", gaps.left), ("right", gaps.right), ("bottom", gaps.bottom)] {
                #expect(abs(gap - NotchPaddingRenderTests.edgePadding) <= 2, "\(name) \(side) gap \(gap) pt: \(gaps)")
            }
        }
    }

    /// The drawn shape as a mask over an image of the canvas `scale` px per point: the `NotchShape`
    /// outline filled and stroked 2 pt wide, so it reaches 1 pt past the outline for antialiasing.
    /// Non-zero is on the shape; the side walls' and the rounded bottom corners' outside stay clear.
    func shapeMask(width: Int, height: Int, scale: CGFloat, metrics: NotchLayout.Metrics) throws -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: width * height)
        let path = metrics.shape.path(in: CGRect(origin: .zero, size: metrics.size)).cgPath
        let context = try #require(CGContext(
            data: &mask, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: (CGFloat(width) / scale - metrics.size.width) / 2, y: 0)
        context.setFillColor(gray: 1, alpha: 1)
        context.setStrokeColor(gray: 1, alpha: 1)
        context.setLineWidth(2)
        context.addPath(path)
        context.fillPath()
        context.addPath(path)
        context.strokePath()
        return mask
    }

    /// Pixels off the shape's mask whose red runs more than 20 above their blue: the warm accent
    /// tinting the light grey backdrop.
    nonisolated static func tinted(_ image: CGImage, mask: [UInt8]) -> Int {
        let pixels = rgba(image)
        var count = 0
        for p in 0..<(image.width * image.height) where mask[p] == 0 {
            if Int(pixels[p * 4]) - Int(pixels[p * 4 + 2]) > 20 { count += 1 }
        }
        return count
    }

    @Test func R47__an_agent_notice_draws_nothing_outside_the_notch_shape() async throws {
        var notice = Self.agentNotice
        notice.accent = Color(red: 0.85, green: 0.47, blue: 0.34)
        let (image, scale, metrics) = try await draw("agent-notice", notice, backdrop: Color(white: 0.92), file: "R47-render-mask-T148")
        let mask = try shapeMask(width: image.width, height: image.height, scale: scale, metrics: metrics)
        // The mask is the outline, not its bounding rectangle: on under the camera, off beside the
        // left wall and in the rounded bottom-left corner, both inside the rectangle.
        let left = (NotchLayout.canvasSize.width - metrics.size.width) / 2, bottom = metrics.size.height
        func on(_ x: CGFloat, _ y: CGFloat) -> Bool { mask[Int(y * scale) * image.width + Int(x * scale)] != 0 }
        #expect(on(NotchLayout.canvasSize.width / 2, 2))
        #expect(!on(left + 2, bottom - 2), "the mask covers the outside of the left wall")
        #expect(!on(left + NotchLayout.openShoulder + 3, bottom - 3), "the mask covers the outside of the bottom-left corner")
        let tinted = await Task.detached { Self.tinted(image, mask: mask) }.value
        print("R47 agent notice over light grey: shape \(metrics.size), \(tinted) accent-tinted pixels off the shape's outline")
        #expect(tinted == 0, "\(tinted) accent-tinted pixels outside the notch shape")
    }
}
