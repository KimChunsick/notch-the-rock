import AppKit
import SwiftUI
import Testing
@testable import Agents

/// How far the outermost ink of `view` (any channel at least 14 over black, as the end-to-end
/// capture counts it) stays from its left, right and bottom edges, drawn offscreen at its ideal
/// size. The host adds the notch's margin around a tab, so a tab's own outer padding shows here.
@MainActor
private func inkInsets(_ view: some View) throws -> (left: CGFloat, right: CGFloat, bottom: CGFloat) {
    let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
    let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = hosting
    // Measured in the window, at its backing scale, as the app measures a tab.
    let size = hosting.fittingSize
    window.setContentSize(size)
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    let image = try #require(rep.cgImage)
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = try #require(CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var minX = width, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            if max(pixels[i], pixels[i + 1], pixels[i + 2]) >= 14 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
    }
    try #require(maxX >= 0, "no ink in \(size)")
    let scale = window.backingScaleFactor
    return (CGFloat(minX) / scale, CGFloat(width - 1 - maxX) / scale, CGFloat(height - 1 - maxY) / scale)
}

/// Offered more width than its own, as the host does when the band beside the camera makes the
/// notch wider than the screen, the title row, the request and the buttons run across it and the reason field stretches; at its own width it keeps today's size.
@MainActor
@Test func R15__agents_screen_fills_a_wider_offer() async throws {
    let model = AgentsScreenModel()
    let waiting = Task {
        await model.show(
            title: "Bash 실행을 허용할까요?", content: .permission(OperationDetail(tool: "Bash", input: nil)), accent: .orange,
            allowsSession: true, takesDenyReason: true, until: ContinuousClock.now + .seconds(60)
        )
    }
    while model.items.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    // Today's size.
    let cases: [(String, AgentsScreen, CGSize)] = [("approval", AgentsScreen(model: model), CGSize(width: 369, height: 151))]
    for (name, view, today) in cases {
        let ideal = NSHostingView(rootView: view).fittingSize
        print("R15 agents \(name) ideal \(ideal)")
        #expect(abs(ideal.width - today.width) <= 0.5 && abs(ideal.height - today.height) <= 0.5, "\(name): the screen's own size changed: \(ideal)")
        let offered = ideal.width + 80
        let wide = NSHostingView(rootView: view.frame(width: offered)).fittingSize
        #expect(abs(wide.height - ideal.height) <= 1, "\(name): wrapped or cut at \(offered) pt: \(wide) vs \(ideal)")
        let insets = try inkInsets(view.frame(width: offered))
        print("R15 agents \(name) offered \(offered) pt: ink insets left \(insets.left) right \(insets.right)")
        #expect(insets.left <= 2 && insets.right <= 2, "\(name): the screen does not reach both edges of a \(offered) pt offer: \(insets)")
    }
    model.cancelAll()
    _ = await waiting.value
}

/// With no request waiting, a dimmed terminal and the message sit at either end, so the screen
/// reaches both edges of a wider offer.
@MainActor
@Test func R15__agents_screen_without_a_request_fills_a_wider_offer() throws {
    let view = AgentsScreen(model: AgentsScreenModel())
    let ideal = NSHostingView(rootView: view).fittingSize
    print("R15 agents without a request ideal \(ideal)")
    // Its own size: the message row is as tall as the message alone was.
    #expect(abs(ideal.width - 153) <= 0.5 && abs(ideal.height - 16) <= 0.5, "the screen's own size changed: \(ideal)")
    let offered = ideal.width + 80
    let wide = NSHostingView(rootView: view.frame(width: offered)).fittingSize
    #expect(abs(wide.height - ideal.height) <= 1, "wrapped or cut at \(offered) pt: \(wide) vs \(ideal)")
    let insets = try inkInsets(view.frame(width: offered))
    print("R15 agents without a request offered \(offered) pt: ink insets left \(insets.left) right \(insets.right)")
    #expect(insets.left <= 2 && insets.right <= 2, "the screen does not reach both edges of a \(offered) pt offer: \(insets)")
}
