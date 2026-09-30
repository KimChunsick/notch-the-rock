import Foundation
import Testing
@testable import Clipboard

@MainActor
@Test func R09__identical_repeat_moves_the_entry_to_the_top() throws {
    let history = makeHistory(directory: try makeDirectory(), key: makeKey())
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let png = samplePNG()

    history.record(.text("first"), at: start)
    history.record(try #require(ClipCapture(png: png)), at: start + 1)
    history.record(.link("https://example.com"), at: start + 2)
    let firstID = try #require(history.items.last?.id)
    history.record(.text("first"), at: start + 3)
    history.record(try #require(ClipCapture(png: png)), at: start + 4)

    #expect(history.items.count == 3)
    #expect(history.items.map(\.kind) == [.image, .text, .link])
    #expect(history.items[1].id == firstID)
    #expect(history.items[1].date == start + 3)
    #expect(history.items[0].date == start + 4)
}

@MainActor
@Test func R09__unpinned_entries_are_capped_at_200_and_pinned_entries_stay() throws {
    let directory = try makeDirectory()
    let history = makeHistory(directory: directory, key: makeKey())
    history.record(try #require(ClipCapture(png: samplePNG())))
    history.record(.text("pinned 1"))
    history.record(.text("pinned 2"))
    for item in history.items where item.kind == .text {
        history.setPinned(true, for: item.id)
    }
    #expect(try files(in: directory).count == 2)  // the list and the image

    for number in 1...250 {
        history.record(.text("entry \(number)"))
    }

    let pinned = history.items.filter(\.isPinned)
    let unpinned = history.items.filter { !$0.isPinned }
    #expect(pinned.map(\.content) == [.text("pinned 2"), .text("pinned 1")])
    #expect(unpinned.count == ClipboardHistory.unpinnedLimit)
    #expect(unpinned.first?.content == .text("entry 250"))
    #expect(unpinned.last?.content == .text("entry 51"))
    // The dropped image took its encrypted file with it.
    #expect(try files(in: directory).count == 1)

    // Unpinning enters the capped set: the older of the two is now past the limit.
    history.setPinned(false, for: pinned[1].id)
    #expect(history.items.filter { !$0.isPinned }.count == ClipboardHistory.unpinnedLimit)
    #expect(!history.items.contains { $0.id == pinned[1].id })
}

@MainActor
@Test func R09__delete_one_entry_and_clear_the_unpinned_ones() throws {
    let directory = try makeDirectory()
    let key = makeKey()
    let history = makeHistory(directory: directory, key: key)
    history.record(.text("keep"))
    history.record(.text("delete me"))
    history.record(try #require(ClipCapture(png: samplePNG())))
    history.record(.link("https://example.com"))
    let keep = try #require(history.items.first { $0.content == .text("keep") })
    history.setPinned(true, for: keep.id)

    history.delete(try #require(history.items.first { $0.content == .text("delete me") }).id)
    #expect(history.items.map(\.kind) == [.link, .image, .text])

    history.clearUnpinned()
    #expect(history.items.map(\.id) == [keep.id])
    #expect(try files(in: directory).count == 1)  // the list only; the image file is gone
    #expect(makeHistory(directory: directory, key: key).items.map(\.id) == [keep.id])
}

@MainActor
@Test func R09__search_matches_text_and_links_case_insensitively() throws {
    let history = makeHistory(directory: try makeDirectory(), key: makeKey())
    history.record(.text("Meeting notes for Monday"))
    history.record(.link("https://Example.com/Notes"))
    history.record(try #require(ClipCapture(png: samplePNG())))
    history.record(.text("장보기 목록"))

    #expect(history.matching("NOTES").map(\.kind) == [.link, .text])
    #expect(history.matching("장보기").map(\.content) == [.text("장보기 목록")])
    #expect(history.matching("  ").count == 4)
    #expect(history.matching("nothing like this").isEmpty)
}
