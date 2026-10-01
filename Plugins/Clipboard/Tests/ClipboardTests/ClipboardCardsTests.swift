import AppKit
import CryptoKit
import Foundation
import SwiftUI
import Testing
@testable import Clipboard

private let terminal = SourceApp(name: "Terminal", bundleID: "com.apple.Terminal")

/// A text from Terminal copied now, an image copied two minutes ago and a link five minutes ago, as
/// in the user's reference.
@MainActor
private func makeReferenceHistory() throws -> ClipboardHistory {
    let history = makeHistory(directory: try makeDirectory(), key: makeKey())
    let now = Date()
    history.record(.link("https://developer.apple.com/design"), at: now - 300)
    history.record(try #require(ClipCapture(png: samplePNG(width: 300, height: 180, seed: 90))), at: now - 120)
    history.record(.text("git push\norigin main"), at: now, source: terminal)
    history.flush()
    return history
}

/// Saves `image` as R27-render-<name>.png in CLIPBOARD_RENDER_DIR when it is set.
private func save(_ image: CGImage, as name: String) throws {
    guard let directory = ProcessInfo.processInfo.environment["CLIPBOARD_RENDER_DIR"] else { return }
    let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("R27-render-\(name).png"))
}

/// Counts the pixels of `image` whose blue clearly outweighs red and green: link text.
private func bluePixelCount(_ image: CGImage) throws -> Int {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = try #require(CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var count = 0
    for i in stride(from: 0, to: pixels.count, by: 4) {
        let red = Int(pixels[i]), green = Int(pixels[i + 1]), blue = Int(pixels[i + 2])
        if blue > red + 80, blue > green + 40 { count += 1 }
    }
    return count
}

/// The screen shows a text, an image and a link as three cards in one row, newest first, each with
/// "<app or kind> · <time ago>" under it; the link is drawn in blue. Renders R27-render-cards.png and,
/// with more entries than fit and pinned ones first, R27-render-many.png.
@MainActor
@Test func R27__cards_show_text_image_and_link_with_captions() throws {
    let history = try makeReferenceHistory()
    let cards = ClipboardView.cards(history.matching(""))
    #expect(cards.map(\.kind) == [.text, .image, .link])
    #expect(cards.map { $0.caption(at: Date()) } == ["Terminal · 지금", "이미지 · 2분", "링크 · 5분"])

    let size = NSHostingView(rootView: ClipboardView(history: history)).fittingSize
    #expect(size.width <= 390 && size.height <= 400, "\(size)")
    let (image, scale) = try renderOffscreen(ClipboardView(history: history).background(.black))
    try save(image, as: "cards")
    #expect(CGFloat(image.width) / scale == ClipboardView.width)
    #expect(try bluePixelCount(image) > 20, "the link card has no blue text")

    let many = makeHistory(directory: try makeDirectory(), key: makeKey())
    let start = Date() - 4 * 86_400
    for index in 1...7 {
        many.record(.text("메모 \(index)\nlet answer = \(index * 6)"), at: start + Double(index) * 3_000, source: terminal)
    }
    let oldest = try #require(many.items.last)
    many.setPinned(true, for: oldest.id)
    many.flush()
    #expect(ClipboardView.cards(many.matching("")).first?.id == oldest.id)
    #expect(ClipboardView.cards(many.matching("메모 3")).map(\.text) == ["메모 3\nlet answer = 18"])
    try save(try renderOffscreen(ClipboardView(history: many).background(.black)).image, as: "many")
}

/// Captions count whole minutes, hours and days, and name the kind when the app is not known.
@MainActor
@Test func R27__captions_count_minutes_hours_and_days() {
    let clock = ManualClock()
    let text = ClipItem(id: UUID(), content: .text("메모"), date: clock.now, isPinned: false)
    let fromTerminal = ClipItem(id: UUID(), content: .text("ls"), date: clock.now, isPinned: false, source: terminal)
    let link = ClipItem(id: UUID(), content: .link("https://example.com"), date: clock.now, isPinned: false)
    let image = ClipItem(id: UUID(), content: .image(digest: "d", thumbnail: Data()), date: clock.now, isPinned: false)

    let expected: [(TimeInterval, String)] = [
        (0, "지금"), (59, "지금"), (60, "1분"), (3_599, "59분"), (3_600, "1시간"), (86_399, "23시간"),
        (86_400, "1일"), (3 * 86_400 + 5, "3일"),
    ]
    for (elapsed, time) in expected {
        #expect(text.caption(at: clock.now + elapsed) == "텍스트 · \(time)")
    }
    #expect(fromTerminal.caption(at: clock.now + 120) == "Terminal · 2분")
    #expect(link.caption(at: clock.now + 300) == "링크 · 5분")
    #expect(image.caption(at: clock.now + 7_200) == "이미지 · 2시간")
}

/// A card's press puts its entry back on the screen's pasteboard, here a private one, as its
/// original type: the link as a URL, the image as its PNG.
@MainActor
@Test func R27__pressing_a_card_copies_it_again() throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let history = try makeReferenceHistory()
    let view = ClipboardView(history: history, pasteboard: pasteboard)
    let cards = ClipboardView.cards(history.matching(""))

    view.copy(cards[2])
    #expect(pasteboard.string(forType: .URL) == "https://developer.apple.com/design")
    #expect(pasteboard.string(forType: .string) == "https://developer.apple.com/design")
    view.copy(cards[0])
    #expect(pasteboard.string(forType: .string) == "git push\norigin main")
    view.copy(cards[1])
    #expect(pasteboard.data(forType: .png) == samplePNG(width: 300, height: 180, seed: 90))
}

/// ← and → move the selection between the cards and stop at either end; with no selection, or one
/// that the search has hidden, any arrow selects the first card.
@MainActor
@Test func R27__arrow_keys_move_between_cards() {
    let ids = (0..<3).map { _ in UUID() }
    #expect(ClipboardView.selection(from: nil, moving: 1, in: ids) == ids[0])
    #expect(ClipboardView.selection(from: nil, moving: -1, in: ids) == ids[0])
    #expect(ClipboardView.selection(from: ids[0], moving: 1, in: ids) == ids[1])
    #expect(ClipboardView.selection(from: ids[1], moving: 1, in: ids) == ids[2])
    #expect(ClipboardView.selection(from: ids[2], moving: 1, in: ids) == ids[2])
    #expect(ClipboardView.selection(from: ids[1], moving: -1, in: ids) == ids[0])
    #expect(ClipboardView.selection(from: ids[0], moving: -1, in: ids) == ids[0])
    #expect(ClipboardView.selection(from: UUID(), moving: 1, in: ids) == ids[0])
    #expect(ClipboardView.selection(from: nil, moving: 1, in: []) == nil)
}

/// The app a test puts in front.
@MainActor
private final class FrontmostApp {
    var app: SourceApp?
    init(_ app: SourceApp?) { self.app = app }
}

/// The app a copy came from: the pasteboard's own source marker wins, else the app in front. A
/// repeat keeps the app it knew when the new copy names none, a concealed copy stays unrecorded,
/// and the app is saved with the entry as its name and bundle id only.
@MainActor
@Test func R27__the_source_app_is_recorded_from_the_marker_or_the_frontmost_app() throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let directory = try makeDirectory()
    let key = makeKey()
    let safari = SourceApp(name: "Safari", bundleID: "com.apple.Safari")
    let front = FrontmostApp(safari)
    let lookup = SourceAppLookup(
        frontmost: { front.app },
        appName: { $0 == "com.apple.Terminal" ? "Terminal" : nil }
    )
    let history = ClipboardHistory(logError: { _ in }, sources: lookup)
    history.open(ClipboardStore(directory: directory, key: key))
    let marker = NSPasteboard.PasteboardType("org.nspasteboard.source")

    pasteboard.clearContents()
    pasteboard.declareTypes([.string, marker], owner: nil)
    pasteboard.setString("git status", forType: .string)
    pasteboard.setString("com.apple.Terminal", forType: marker)
    history.record(from: pasteboard)
    #expect(history.items.first?.source == terminal)

    pasteboard.clearContents()
    pasteboard.setString("https://swift.org", forType: .string)
    history.record(from: pasteboard)
    #expect(history.items.first?.source == safari)

    // A marker naming an app that cannot be found keeps its bundle id.
    pasteboard.clearContents()
    pasteboard.declareTypes([.string, marker], owner: nil)
    pasteboard.setString("from an unknown app", forType: .string)
    pasteboard.setString("com.example.Unknown", forType: marker)
    history.record(from: pasteboard)
    #expect(history.items.first?.source == SourceApp(name: "com.example.Unknown", bundleID: "com.example.Unknown"))

    // Copying "git status" again while this app is in front keeps Terminal.
    front.app = nil
    pasteboard.clearContents()
    pasteboard.setString("git status", forType: .string)
    history.record(from: pasteboard)
    #expect(history.items.first?.text == "git status")
    #expect(history.items.first?.source == terminal)

    pasteboard.clearContents()
    pasteboard.setString("no app known", forType: .string)
    history.record(from: pasteboard)
    #expect(history.items.first?.source == nil)
    #expect(history.items.first?.caption(at: Date()) == "텍스트 · 지금")

    pasteboard.clearContents()
    pasteboard.declareTypes([.string, marker, .init("org.nspasteboard.ConcealedType")], owner: nil)
    pasteboard.setString("hunter2", forType: .string)
    pasteboard.setString("com.apple.Terminal", forType: marker)
    history.record(from: pasteboard)
    #expect(!history.items.contains { $0.text == "hunter2" })

    history.flush()
    let reopened = makeHistory(directory: directory, key: key)
    #expect(reopened.items.map(\.source) == history.items.map(\.source))
    let encoded = try JSONEncoder().encode(try #require(history.items.first { $0.source == terminal }))
    let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let source = try #require(object["source"] as? [String: Any])
    #expect(Set(source.keys) == ["name", "bundleID"])
}

/// A list saved before entries had a source app still loads, its entries captioned by kind.
@MainActor
@Test func R27__a_list_saved_without_source_apps_still_loads() throws {
    let directory = try makeDirectory()
    let key = makeKey()
    let id = UUID()
    let old = #"[{"id":"\#(id.uuidString)","content":{"text":{"_0":"예전 메모"}},"date":800000000,"isPinned":true}]"#
    let sealed = try #require(try AES.GCM.seal(Data(old.utf8), using: key).combined)
    try sealed.write(to: directory.appendingPathComponent(ClipboardStore.listFileName))

    let history = makeHistory(directory: directory, key: key)
    #expect(!history.isStoreUnreadable)
    let item = try #require(history.items.first)
    #expect(item.id == id && item.text == "예전 메모" && item.isPinned && item.source == nil)
    #expect(item.caption(at: Date(timeIntervalSinceReferenceDate: 800_000_600)) == "텍스트 · 10분")
}
