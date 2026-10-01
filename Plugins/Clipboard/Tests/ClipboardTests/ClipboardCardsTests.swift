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

/// The screen in a borderless window far off every display, ordered in without activating this
/// process, so mouse and key events sent to the window reach the real controls as on screen.
@MainActor
private final class HostedScreen {
    let window: NSWindow
    let hosting: NSHostingView<ClipboardView>

    init(_ view: ClipboardView) {
        _ = NSApplication.shared
        hosting = NSHostingView(rootView: view)
        let origin = NSPoint(x: -6_000, y: -6_000)
        window = NSWindow(contentRect: NSRect(origin: origin, size: CGSize(width: 10, height: 10)), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        window.setFrameOrigin(origin)
        window.orderFrontRegardless()
        settle()
    }

    func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }

    func close() {
        window.orderOut(nil)
    }

    /// Clicks the middle of card `index`, counted from the left.
    func clickCard(_ index: Int) {
        let size = ClipboardView.cardSize
        let x = size.width / 2 + CGFloat(index) * (size.width + ClipboardView.cardSpacing)
        let top = ClipboardView.searchHeight + ClipboardView.spacing + size.height / 2
        let point = hosting.convert(NSPoint(x: x, y: hosting.isFlipped ? top : hosting.bounds.height - top), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!)
            settle()
        }
    }

    /// Sends `characters` as one key press, as the keyboard does.
    func type(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) {
        window.sendEvent(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        )!)
        settle()
    }

    func press(_ key: ClipboardView.Key) {
        let arrow: NSEvent.ModifierFlags = [.numericPad, .function]
        switch key {
        case .left: type("\u{F702}", keyCode: 123, flags: arrow)
        case .right: type("\u{F703}", keyCode: 124, flags: arrow)
        case .up: type("\u{F700}", keyCode: 126, flags: arrow)
        case .down: type("\u{F701}", keyCode: 125, flags: arrow)
        case .tab: type("\t", keyCode: 48)
        case .backTab: type("\u{19}", keyCode: 48, flags: .shift)
        case .enter: type("\r", keyCode: 36)
        }
    }

    /// The search field's editor while the field has the focus.
    var fieldEditor: NSTextView? {
        window.firstResponder as? NSTextView
    }
}

/// Clicking a card in the window puts that card's entry back on the screen's pasteboard, here a
/// private one, as its original type; clicking another card puts that one there instead.
@MainActor
@Test func R27__clicking_a_card_copies_it_again() throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let history = try makeReferenceHistory()
    let screen = HostedScreen(ClipboardView(history: history, pasteboard: pasteboard))
    defer { screen.close() }

    screen.clickCard(2)
    #expect(pasteboard.string(forType: .URL) == "https://developer.apple.com/design")
    #expect(pasteboard.string(forType: .string) == "https://developer.apple.com/design")
    screen.clickCard(0)
    #expect(pasteboard.string(forType: .string) == "git push\norigin main")
    #expect(pasteboard.string(forType: .URL) == nil)
    screen.clickCard(1)
    #expect(pasteboard.data(forType: .png) == samplePNG(width: 300, height: 180, seed: 90))
}

/// The keys the screen takes: ← and → move between the cards only when the search field is empty
/// or the focus is in the card row, and are left to the field's caret otherwise; ↓ or Tab moves
/// into the row and ↑ or Shift-Tab back; Return copies the selected card, or the first; an input
/// method that composes keeps every key.
@MainActor
@Test func R27__key_routing_keeps_the_caret_while_the_field_has_text() {
    func action(_ key: ClipboardView.Key, text: Bool = false, composing: Bool = false, in area: ClipboardView.Area = .field, selection: Int? = nil, count: Int = 3) -> ClipboardView.KeyAction {
        ClipboardView.action(for: key, fieldHasText: text, isComposing: composing, area: area, selection: selection, count: count)
    }
    // Text in the field: the arrows move its caret.
    #expect(action(.left, text: true) == .passThrough)
    #expect(action(.right, text: true, selection: 1) == .passThrough)
    // An empty field: → and ← select, starting at the first card and stopping at either end.
    #expect(action(.right) == .select(0))
    #expect(action(.left) == .select(0))
    #expect(action(.right, selection: 0) == .select(1))
    #expect(action(.right, selection: 2) == .select(2))
    #expect(action(.left, selection: 1) == .select(0))
    #expect(action(.left, selection: 0) == .select(0))
    // ↓ or Tab moves into the row, keeping a selection; there the arrows select whatever the field holds.
    #expect(action(.down, text: true) == .enterCards(0))
    #expect(action(.tab, selection: 2) == .enterCards(2))
    #expect(action(.left, text: true, in: .cards, selection: 2) == .select(1))
    #expect(action(.right, text: true, in: .cards, selection: 1) == .select(2))
    // ↑ or Shift-Tab goes back to the field; in the field they stay its own.
    #expect(action(.up, in: .cards, selection: 1) == .focusField)
    #expect(action(.backTab, in: .cards) == .focusField)
    #expect(action(.up, text: true) == .passThrough)
    #expect(action(.backTab) == .passThrough)
    #expect(action(.down, in: .cards) == .passThrough)
    // Return copies the selected card, or the first one.
    #expect(action(.enter, text: true) == .copy(0))
    #expect(action(.enter, text: true, selection: 2) == .copy(2))
    #expect(action(.enter, in: .cards, selection: 1) == .copy(1))
    // An input method composing, as for an unfinished Hangul syllable, keeps every key.
    for key in [ClipboardView.Key.left, .right, .up, .down, .tab, .backTab, .enter] {
        #expect(action(key, composing: true) == .passThrough)
        #expect(action(key, text: true, composing: true, selection: 1) == .passThrough)
    }
    // No cards: nothing to select or copy.
    #expect(action(.right, count: 0) == .passThrough)
    #expect(action(.enter, count: 0) == .passThrough)
    #expect(action(.down, count: 0) == .passThrough)
}

/// The same keys sent to the screen in a window: with text in the field ← moves the caret and leaves
/// the selection; an empty field's → selects; ↓ takes the focus out of the field into the row and
/// ↑ brings it back, as Tab and Shift-Tab do; Return copies the selected card.
@MainActor
@Test func R27__keys_in_a_window_reach_the_caret_or_the_cards() throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let history = makeHistory(directory: try makeDirectory(), key: makeKey())
    let now = Date()
    for (offset, text) in ["alpha one", "alpha two", "alpha three"].enumerated() {
        history.record(.text(text), at: now + Double(offset))
    }
    let screen = HostedScreen(ClipboardView(history: history, pasteboard: pasteboard))
    defer { screen.close() }
    #expect(screen.fieldEditor != nil, "the search field has the focus")

    // An empty field: → → selects the second card.
    screen.press(.right)
    screen.press(.right)
    screen.press(.enter)
    #expect(pasteboard.string(forType: .string) == "alpha two")

    // Text in the field: ← moves the caret and the selection stays.
    screen.type("a", keyCode: 0)
    screen.type("l", keyCode: 37)
    #expect(screen.fieldEditor?.string == "al")
    #expect(screen.fieldEditor?.selectedRange().location == 2)
    screen.press(.left)
    #expect(screen.fieldEditor?.selectedRange().location == 1)
    pasteboard.clearContents()
    screen.press(.enter)
    #expect(pasteboard.string(forType: .string) == "alpha two")

    // ↓ moves into the row, where → selects the next card; ↑ goes back to the field.
    screen.press(.down)
    #expect(screen.fieldEditor == nil, "the focus left the field")
    screen.press(.right)
    screen.press(.enter)
    #expect(pasteboard.string(forType: .string) == "alpha one")
    screen.press(.up)
    #expect(screen.fieldEditor?.string == "al")

    // Tab and Shift-Tab do the same.
    screen.press(.tab)
    #expect(screen.fieldEditor == nil, "the focus left the field")
    screen.press(.backTab)
    #expect(screen.fieldEditor?.string == "al")
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
