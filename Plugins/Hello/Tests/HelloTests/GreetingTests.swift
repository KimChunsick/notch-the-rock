import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Hello

/// A seeded generator, so a test that picks a phrase at random always picks the same one.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Dates in a fixed zone and calendar, so slot boundaries never depend on the test machine.
enum Week {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        calendar.locale = Locale(identifier: "ko_KR")
        return calendar
    }()

    /// 2026-09-28 is a Monday; `day` 0...6 runs Monday through Sunday.
    static func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 28 + day, hour: hour, minute: minute))!
    }

    static let monday = 0, tuesday = 1, wednesday = 2, friday = 4, saturday = 5, sunday = 6

    /// Every phrase any hour of any day can pick.
    static var everyPhrase: Set<String> {
        var phrases = Set<String>()
        for day in 0..<7 {
            for hour in 0..<24 {
                phrases.formUnion(HelloPhrases.phrases(for: date(day: day, hour: hour), calendar: calendar))
            }
        }
        return phrases
    }
}

/// Height in points of the opaque ink (pixels at least 90% opaque), which leaves out the soft glow.
/// `band` limits it to rows that far from the top, in points.
@MainActor
func inkHeight(of image: CGImage, scale: CGFloat, band: Range<CGFloat>? = nil) -> CGFloat {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let rows = band.map { max(Int($0.lowerBound * scale), 0)..<min(Int($0.upperBound * scale), height) } ?? 0..<height
    var top: Int?, bottom: Int?
    for row in rows {
        for column in 0..<width where pixels[(row * width + column) * 4 + 3] >= 230 {
            top = top ?? row
            bottom = row
            break
        }
    }
    guard let top, let bottom else { return 0 }
    return CGFloat(bottom - top + 1) / scale
}

/// The rows each line of `phrase` takes in a render of its artwork at its own size, in points from
/// the top: the line's outlines with 8 pt for the pen on either side, less than half the space
/// between lines.
func lineBands(of phrase: String) -> [Range<CGFloat>] {
    let top = HelloArtwork(phrase: phrase).canvas.minY
    return HelloOutline.lines(for: phrase).map { line in
        let bounds = line.stroke.boundingRect
        return (bounds.minY - top - 8)..<(bounds.maxY - top + 8)
    }
}

extension HelloArtwork {
    /// "hello" at its size before R19: the takeover was 580×210 under a 32 pt notch with 8 pt
    /// padding, so the word was fitted into 564×162.
    static let formerHello = HelloArtwork(
        stroke: HelloLettering.stroke, canvas: HelloLettering.canvas, penWidth: HelloLettering.strokeWidth,
        pointsPerUnit: HelloLettering.scale(toFit: CGRect(x: 0, y: 0, width: 564, height: 162)),
        fillsWhenWritten: false
    )
}

@MainActor
func render(_ view: some View, proposed: ProposedViewSize = .unspecified) -> CGImage {
    let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
    renderer.scale = 2
    renderer.proposedSize = proposed
    return renderer.cgImage!
}

@MainActor
@Suite struct GreetingTests {
    @Test(arguments: [
        (Week.wednesday, 3, HelloPhrases.Slot.dawn, "고요한 새벽이에요."),
        (Week.sunday, 3, .dawn, "고요한 주말 새벽이에요."),
        (Week.wednesday, 8, .morning, "좋은 아침이에요."),
        (Week.saturday, 8, .morning, "여유로운 주말 아침이에요."),
        (Week.wednesday, 15, .afternoon, "오후도 힘내세요."),
        (Week.saturday, 15, .afternoon, "편안한 주말 오후 되세요."),
        (Week.wednesday, 19, .evening, "오늘 하루 수고했어요."),
        (Week.sunday, 19, .evening, "즐거운 주말 저녁 보내세요."),
        (Week.wednesday, 23, .night, "좋은 밤이에요."),
        (Week.saturday, 23, .night, "좋은 밤이에요."),
    ])
    func R19__each_slot_has_its_weekday_and_weekend_phrases(day: Int, hour: Int, slot: HelloPhrases.Slot, phrase: String) {
        let date = Week.date(day: day, hour: hour)
        #expect(HelloPhrases.slot(for: date, calendar: Week.calendar) == slot)
        #expect(HelloPhrases.phrases(for: date, calendar: Week.calendar).contains(phrase))
    }

    @Test func R19__weekend_and_weekday_pools_differ() {
        let weekdayAfternoon = HelloPhrases.phrases(for: Week.date(day: Week.wednesday, hour: 15), calendar: Week.calendar)
        let weekendAfternoon = HelloPhrases.phrases(for: Week.date(day: Week.sunday, hour: 15), calendar: Week.calendar)
        #expect(!weekdayAfternoon.contains("편안한 주말 오후 되세요."))
        #expect(weekendAfternoon.contains("편안한 주말 오후 되세요."))

        // A Monday morning and a Friday evening get a touch of their own.
        let mondayMorning = HelloPhrases.phrases(for: Week.date(day: Week.monday, hour: 9), calendar: Week.calendar)
        let tuesdayMorning = HelloPhrases.phrases(for: Week.date(day: Week.tuesday, hour: 9), calendar: Week.calendar)
        #expect(mondayMorning.contains("힘찬 한 주 보내세요."))
        #expect(!tuesdayMorning.contains("힘찬 한 주 보내세요."))
        let fridayEvening = HelloPhrases.phrases(for: Week.date(day: Week.friday, hour: 19), calendar: Week.calendar)
        #expect(fridayEvening.contains("한 주 동안 수고했어요."))
    }

    @Test(arguments: [
        (5, 59, HelloPhrases.Slot.dawn), (6, 0, .morning),
        (11, 59, .morning), (12, 0, .afternoon),
        (17, 59, .afternoon), (18, 0, .evening),
        (20, 59, .evening), (21, 0, .night),
        (23, 59, .night), (0, 0, .dawn),
    ])
    func R19__slot_boundaries(hour: Int, minute: Int, slot: HelloPhrases.Slot) {
        for day in [Week.wednesday, Week.saturday] {
            #expect(HelloPhrases.slot(for: Week.date(day: day, hour: hour, minute: minute), calendar: Week.calendar) == slot)
        }
    }

    /// Every hour of every day, Monday mornings and Friday evenings included.
    @Test(arguments: 0..<7)
    func R19__every_slot_pool_has_hello_and_annyeonghaseyo(day: Int) {
        for hour in 0..<24 {
            let pool = HelloPhrases.phrases(for: Week.date(day: day, hour: hour), calendar: Week.calendar)
            #expect(pool.contains(HelloPhrases.hello), "day \(day) hour \(hour)")
            #expect(pool.contains("안녕하세요!"), "day \(day) hour \(hour)")
        }
    }

    @Test func R19__hello_and_annyeonghaseyo_are_reachable() {
        var generator = SplitMix64(state: 19)
        // One hour in each slot: dawn, morning, afternoon, evening, night.
        for day in 0..<7 {
            for hour in [3, 9, 15, 19, 23] {
                let date = Week.date(day: day, hour: hour)
                var picked = Set<String>()
                for _ in 0..<64 {
                    picked.insert(HelloPhrases.phrase(for: date, calendar: Week.calendar, using: &generator))
                }
                #expect(picked.contains(HelloPhrases.hello), "day \(day) hour \(hour)")
                #expect(picked.contains("안녕하세요!"), "day \(day) hour \(hour)")
            }
        }
    }

    @Test func R19__seeded_pick_is_deterministic() {
        var first = SplitMix64(state: 42)
        var second = SplitMix64(state: 42)
        for day in 0..<7 {
            for hour in stride(from: 0, to: 24, by: 3) {
                let date = Week.date(day: day, hour: hour)
                let phrase = HelloPhrases.phrase(for: date, calendar: Week.calendar, using: &first)
                #expect(phrase == HelloPhrases.phrase(for: date, calendar: Week.calendar, using: &second))
                #expect(HelloPhrases.phrases(for: date, calendar: Week.calendar).contains(phrase))
            }
        }
    }

    @Test func R19__korean_phrase_becomes_several_glyph_contours() {
        #expect(CTFontCopyPostScriptName(HelloOutline.font) as String == HelloOutline.fontName)

        let path = HelloOutline.path(for: "좋은 아침이에요.")
        var contours = 0
        path.forEach { element in
            if case .move = element { contours += 1 }
        }
        #expect(!path.isEmpty)
        #expect(contours > 1)
        #expect(path.boundingRect.width > path.boundingRect.height * 4)

        // Every phrase except the handwritten word is drawn along its outlines.
        for phrase in Week.everyPhrase where phrase != HelloPhrases.hello {
            let artwork = HelloArtwork(phrase: phrase)
            #expect(!artwork.stroke.isEmpty, "\(phrase)")
            #expect(artwork.fillsWhenWritten)
        }
        #expect(HelloArtwork(phrase: HelloPhrases.hello).stroke == HelloLettering.stroke)
    }

    @Test func R19__every_phrase_is_written_and_gone_within_three_seconds() throws {
        #expect(HelloTimeline.total <= 3.0)
        #expect(HelloTimeline.frame(at: HelloTimeline.drawEnd).drawn == 1)
        #expect(HelloTimeline.frame(at: HelloTimeline.fadeStart).fill == 1)
        #expect(HelloTimeline.frame(at: HelloTimeline.drawStart).fill == 0)
        for phrase in Week.everyPhrase {
            let artwork = HelloArtwork(phrase: phrase)
            // The whole outline is traced by `drawEnd`, whatever its length.
            let written = artwork.path(in: CGRect(origin: .zero, size: artwork.size))
                .trimmedPath(from: 0, to: HelloTimeline.frame(at: HelloTimeline.drawEnd).drawn)
            #expect(abs(written.boundingRect.height - artwork.stroke.boundingRect.height * artwork.pointsPerUnit) < 0.5, "\(phrase)")
        }
        try withContext { context, host in
            HelloPlugin(context: context).activate()
            let duration = try #require(host.takeovers.first?.duration)
            #expect(duration <= .seconds(3))
        }
    }

    @Test func R19__greeting_is_half_its_former_height() throws {
        let former = HelloArtwork.formerHello
        let written = HelloTimeline.frame(at: HelloTimeline.fadeStart)
        let formerHeight = inkHeight(of: render(HelloLetteringView(artwork: former, frame: written)), scale: 2)
        let helloHeight = inkHeight(of: render(HelloLetteringView(artwork: .hello, frame: written)), scale: 2)
        #expect(formerHeight > 100)
        #expect(abs(helloHeight / formerHeight - 0.5) < 0.05)

        for phrase in Week.everyPhrase where phrase != HelloPhrases.hello {
            let artwork = HelloArtwork(phrase: phrase)
            // A definite size, so a content-sized notch can fit itself to the greeting.
            let image = render(HelloLetteringView(artwork: artwork, frame: written))
            #expect(abs(CGFloat(image.width) / 2 - artwork.size.width.rounded()) <= 1, "\(phrase)")
            #expect(abs(CGFloat(image.height) / 2 - artwork.size.height.rounded()) <= 1, "\(phrase)")
            // Every line of a wrapped phrase is half as tall as the former hello.
            for band in lineBands(of: phrase) {
                let height = inkHeight(of: image, scale: 2, band: band)
                #expect(abs(height / formerHeight - 0.5) < 0.075, "\(phrase): \(height) pt")
            }

            // In the former fixed-size takeover the widest phrase shrinks to fit instead of clipping.
            let squeezed = render(HelloLetteringView(artwork: artwork, frame: written), proposed: ProposedViewSize(width: 564, height: 162))
            #expect(squeezed.width <= 564 * 2, "\(phrase)")
        }
    }

    @Test func R19__every_phrase_fits_the_maximum_line_width() {
        for phrase in Week.everyPhrase where phrase != HelloPhrases.hello {
            let artwork = HelloArtwork(phrase: phrase)
            #expect(artwork.stroke.boundingRect.width <= HelloOutline.maxLineWidth, "\(phrase)")
            #expect(artwork.size.width <= HelloOutline.maxLineWidth + 2 * HelloOutline.margin, "\(phrase)")
            // Lines are centred on one another.
            for line in HelloOutline.lines(for: phrase) {
                #expect(abs(line.stroke.boundingRect.midX - artwork.stroke.boundingRect.midX) < 0.5, "\(phrase): \(line.text)")
            }
        }
        // The handwritten word never wraps.
        #expect(HelloArtwork(phrase: HelloPhrases.hello).size == HelloArtwork.hello.size)
    }

    @Test func R19__long_phrases_wrap_at_spaces() {
        #expect(HelloOutline.lineBreaks(for: "편안한 주말 오후 되세요.") == ["편안한 주말", "오후 되세요."])
        // Two even lines rather than a long first line and a short last one.
        #expect(HelloOutline.lineBreaks(for: "오늘 밤도 푹 쉬세요.") == ["오늘 밤도", "푹 쉬세요."])
        #expect(HelloOutline.lineBreaks(for: "안녕하세요!") == ["안녕하세요!"])

        for phrase in Week.everyPhrase where phrase != HelloPhrases.hello {
            let breaks = HelloOutline.lineBreaks(for: phrase)
            #expect(breaks.joined(separator: " ") == phrase)
            if HelloOutline.width(of: phrase) > HelloOutline.maxLineWidth {
                #expect(breaks.count >= 2, "\(phrase)")
            } else {
                #expect(breaks == [phrase])
            }
        }
    }

    @Test func R19__word_wider_than_a_line_breaks_between_characters() {
        let word = "가나다라마바사아자차카타파하"
        #expect(HelloOutline.width(of: word) > 2 * HelloOutline.maxLineWidth)
        let breaks = HelloOutline.lineBreaks(for: word)
        #expect(breaks.count == 3)
        #expect(breaks.joined() == word)
        for line in breaks {
            #expect(HelloOutline.width(of: line) <= HelloOutline.maxLineWidth, "\(line)")
        }
    }

    @Test func R19__wrapped_lines_keep_the_single_line_glyph_height() {
        let written = HelloTimeline.frame(at: HelloTimeline.fadeStart)
        let wrapped = Week.everyPhrase.filter { HelloOutline.lineBreaks(for: $0).count > 1 }
        #expect(!wrapped.isEmpty)
        for phrase in wrapped {
            let image = render(HelloLetteringView(artwork: HelloArtwork(phrase: phrase), frame: written))
            for (line, band) in zip(HelloOutline.lines(for: phrase), lineBands(of: phrase)) {
                let alone = render(HelloLetteringView(artwork: HelloArtwork(phrase: line.text), frame: written))
                let height = inkHeight(of: image, scale: 2, band: band)
                #expect(abs(height - inkHeight(of: alone, scale: 2)) <= 1, "\(phrase): \(line.text) \(height) pt")
            }
        }
    }

    @Test func R19__lines_are_written_in_reading_order() throws {
        for phrase in Week.everyPhrase where HelloOutline.lineBreaks(for: phrase).count > 1 {
            let artwork = HelloArtwork(phrase: phrase)
            let lines = HelloOutline.lines(for: phrase).map { $0.stroke.boundingRect }
            for (upper, lower) in zip(lines, lines.dropFirst()) {
                #expect(upper.maxY < lower.minY, "\(phrase)")
            }
            // The pen moves from line to line, top to bottom, never back.
            var current = 0
            for step in 1...100 {
                let tip = try #require(artwork.stroke.trimmedPath(from: 0, to: Double(step) / 100).currentPoint)
                let line = try #require(lines.firstIndex { $0.insetBy(dx: -1, dy: -1).contains(tip) }, "\(phrase)")
                #expect(line >= current, "\(phrase)")
                current = line
            }
            #expect(current == lines.count - 1, "\(phrase)")
        }
    }

    /// Offscreen captures of wrapped greetings, written only when HELLO_CAPTURE_DIR is set:
    /// `R19-wrap-<phrase>-<seconds>s.png` mid-writing and finished, plus every phrase's line breaks
    /// and laid-out size in `R19-wrap.txt`.
    @Test func R19__offscreen_captures() throws {
        guard let directory = ProcessInfo.processInfo.environment["HELLO_CAPTURE_DIR"] else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        let phrases = Week.everyPhrase.filter { $0 != HelloPhrases.hello }
            .sorted { HelloOutline.width(of: $0) > HelloOutline.width(of: $1) }
        let captures: [(name: String, phrase: String)] = [
            ("pyeonan-jumal-ohu", "편안한 주말 오후 되세요."), ("jeulgeoun-jumal-jeonyeok", "즐거운 주말 저녁 보내세요."),
        ]
        // The second capture is the phrase that is widest on one line.
        #expect(phrases.first == captures[1].phrase)
        for capture in captures {
            let artwork = HelloArtwork(phrase: capture.phrase)
            for elapsed in [1.0, 2.5] {
                let frame = HelloTimeline.frame(at: elapsed)
                let image = render(HelloLetteringView(artwork: artwork, frame: frame).padding(8).background(Color.black))
                let url = folder.appendingPathComponent("R19-wrap-\(capture.name)-\(elapsed)s.png")
                let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try data.write(to: url)
            }
        }

        let written = HelloTimeline.frame(at: HelloTimeline.fadeStart)
        let formerHeight = inkHeight(of: render(HelloLetteringView(artwork: .formerHello, frame: written)), scale: 2)
        var report = [
            "# R19 wrap — line breaks and laid-out size of every phrase, widest first (max line width \(Int(HelloOutline.maxLineWidth)) pt, baselines \(Int(HelloOutline.lineSpacing)) pt apart), measured offscreen",
            "",
            "former hello ink \(formerHeight) pt; hello: handwritten, never wraps, canvas \(Int(HelloArtwork.hello.size.width))×\(Int(HelloArtwork.hello.size.height)) pt",
        ]
        for phrase in phrases {
            let artwork = HelloArtwork(phrase: phrase)
            let image = render(HelloLetteringView(artwork: artwork, frame: written))
            let inks = lineBands(of: phrase).map { band in
                let height = inkHeight(of: image, scale: 2, band: band)
                return "\(height) pt (\(String(format: "%.3f", height / formerHeight)))"
            }
            let breaks = HelloOutline.lineBreaks(for: phrase)
            let lines = breaks.map { "\"\($0)\"" }.joined(separator: " / ")
            let ink = artwork.stroke.boundingRect
            report.append(
                "\(phrase): one line \(Int(HelloOutline.width(of: phrase).rounded())) pt → \(breaks.count) line(s) \(lines); "
                    + "laid out \(Int(ink.width.rounded()))×\(Int(ink.height.rounded())) pt, canvas \(Int(artwork.size.width.rounded()))×\(Int(artwork.size.height.rounded())) pt; "
                    + "line ink height (ratio to former hello) \(inks.joined(separator: ", "))"
            )
        }
        try (report.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("R19-wrap.txt"), atomically: true, encoding: .utf8)
    }
}
