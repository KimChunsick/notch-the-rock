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
@MainActor
func inkHeight(of image: CGImage, scale: CGFloat) -> CGFloat {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var top: Int?, bottom: Int?
    for row in 0..<height {
        for column in 0..<width where pixels[(row * width + column) * 4 + 3] >= 230 {
            top = top ?? row
            bottom = row
            break
        }
    }
    guard let top, let bottom else { return 0 }
    return CGFloat(bottom - top + 1) / scale
}

extension HelloArtwork {
    /// "hello" at its size before R19: the takeover was 580×210 under a 32 pt notch with 8 pt
    /// padding, so the word was fitted into 564×162.
    static let formerHello = HelloArtwork(
        stroke: HelloLettering.stroke, canvas: HelloLettering.canvas, penWidth: HelloLettering.strokeWidth,
        pointsPerUnit: HelloLettering.scale(toFit: CGRect(x: 0, y: 0, width: 564, height: 162))
    )
}

@MainActor
func render(_ view: some View, proposed: ProposedViewSize = .unspecified) -> CGImage {
    let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
    renderer.scale = 2
    renderer.proposedSize = proposed
    return renderer.cgImage!
}

/// The pen's position after writing `fraction` of `stroke`.
func tip(of stroke: Path, at fraction: Double) throws -> CGPoint {
    try #require(stroke.trimmedPath(from: 0, to: fraction).currentPoint)
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

    /// Mornings, afternoons, evenings and nights of weekdays and weekends, Monday mornings and Friday
    /// evenings included: the line under the word is always a phrase of its own, never one of the
    /// greetings the pen writes.
    @Test(arguments: [
        (Week.wednesday, 9), (Week.wednesday, 15), (Week.wednesday, 19), (Week.wednesday, 23),
        (Week.saturday, 9), (Week.sunday, 15), (Week.saturday, 19), (Week.sunday, 23),
        (Week.monday, 9), (Week.friday, 19), (Week.tuesday, 3),
    ])
    func R20__subtitle_is_never_a_handwritten_word(day: Int, hour: Int) {
        let everyday: Set = ["hello", "안녕하세요", "안녕하세요!"]
        let date = Week.date(day: day, hour: hour)
        let pool = HelloPhrases.phrases(for: date, calendar: Week.calendar)
        #expect(!pool.isEmpty)
        #expect(everyday.isDisjoint(with: pool), "\(pool)")
        var generator = SplitMix64(state: UInt64(day * 24 + hour))
        for _ in 0..<32 {
            let greeting = HelloGreeting.random(for: date, calendar: Week.calendar, using: &generator)
            #expect(pool.contains(greeting.subtitle))
        }
    }

    @Test func R19__monday_morning_and_friday_evening_subtitles() {
        var generator = SplitMix64(state: 7)
        var monday = Set<String>(), friday = Set<String>()
        for _ in 0..<64 {
            monday.insert(HelloGreeting.random(for: Week.date(day: Week.monday, hour: 9), calendar: Week.calendar, using: &generator).subtitle)
            friday.insert(HelloGreeting.random(for: Week.date(day: Week.friday, hour: 19), calendar: Week.calendar, using: &generator).subtitle)
        }
        #expect(monday == ["좋은 아침이에요.", "힘찬 한 주 보내세요."])
        #expect(friday == ["오늘 하루 수고했어요.", "편안한 저녁 보내세요.", "한 주 동안 수고했어요."])
    }

    /// Every slot of every day writes "hello" or "안녕하세요", and both turn up.
    @Test(arguments: 0..<7)
    func R20__written_word_is_one_of_the_two_handwritten_strokes(day: Int) throws {
        let strokes = [HelloLettering.stroke, HangulLettering.stroke]
        #expect(HelloArtwork.words.map(\.stroke) == strokes)
        var generator = SplitMix64(state: UInt64(day))
        for hour in [3, 9, 15, 19, 23] {
            var written = Set<Int>()
            for _ in 0..<32 {
                let greeting = HelloGreeting.random(for: Week.date(day: day, hour: hour), calendar: Week.calendar, using: &generator)
                written.insert(try #require(strokes.firstIndex(of: greeting.word.stroke), "day \(day) hour \(hour)"))
            }
            #expect(written == [0, 1], "day \(day) hour \(hour)")
        }
    }

    @Test func R19__seeded_pick_is_deterministic() {
        var first = SplitMix64(state: 42)
        var second = SplitMix64(state: 42)
        for day in 0..<7 {
            for hour in stride(from: 0, to: 24, by: 3) {
                let date = Week.date(day: day, hour: hour)
                let one = HelloGreeting.random(for: date, calendar: Week.calendar, using: &first)
                let other = HelloGreeting.random(for: date, calendar: Week.calendar, using: &second)
                #expect(one.word.stroke == other.word.stroke)
                #expect(one.subtitle == other.subtitle)
            }
        }
    }

    /// Both words are a single pen stroke of cubic curves, the way `HelloLettering` draws "hello".
    @Test func R20__handwritten_words_are_single_cubic_strokes() {
        for word in HelloArtwork.words {
            var moves = 0, curves = 0, others = 0
            word.stroke.forEach { element in
                switch element {
                case .move: moves += 1
                case .curve: curves += 1
                default: others += 1
                }
            }
            #expect(moves == 1)
            #expect(others == 0)
            #expect(curves >= 15)
            #expect(word.penWidth == HelloLettering.strokeWidth)
        }
    }

    /// Nothing in the plugin sets letters from a font: the module has no CoreText glyph outlines.
    @Test func R20__module_draws_no_font_outlines() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Hello")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count >= 6)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for symbol in ["CoreText", "CTFont", "CTLine", "CTRun", "PathForGlyph"] {
                #expect(!source.contains(symbol), "\(file.lastPathComponent) uses \(symbol)")
            }
        }
    }

    @Test func R20__annyeonghaseyo_fits_its_canvas_without_jumps() throws {
        let stroke = HangulLettering.stroke
        let bounds = stroke.boundingRect
        #expect(bounds.width > 0 && bounds.height > 0)
        #expect(HangulLettering.canvas.contains(bounds.insetBy(dx: -HangulLettering.strokeWidth, dy: -HangulLettering.strokeWidth)))
        // Walking the stroke never jumps: consecutive points along it stay close together.
        var previous = try tip(of: stroke, at: 0.001)
        for step in 1...300 {
            let point = try tip(of: stroke, at: Double(step) / 300)
            #expect(hypot(point.x - previous.x, point.y - previous.y) < HangulLettering.canvas.width / 30, "step \(step)")
            previous = point
        }
    }

    /// The pen writes from left to right overall, whatever loops back within a syllable.
    @Test func R20__writing_runs_left_to_right() throws {
        for word in HelloArtwork.words {
            let xs = try [0.001, 0.25, 0.5, 0.75, 1].map { try tip(of: word.stroke, at: $0).x }
            #expect(xs == xs.sorted(), "\(xs)")
            #expect(Set(xs).count == xs.count, "\(xs)")
        }
    }

    @Test func R19__words_are_half_the_former_hello_height() {
        let written = HelloTimeline.frame(at: HelloTimeline.fadeStart)
        let formerHeight = inkHeight(of: render(HelloLetteringView(artwork: .formerHello, frame: written)), scale: 2)
        #expect(formerHeight > 100)
        for word in HelloArtwork.words {
            // The same pen, in points, and the same canvas height.
            #expect(word.penWidth * word.pointsPerUnit == HelloArtwork.hello.penWidth * HelloArtwork.hello.pointsPerUnit)
            #expect(word.size.height == HelloLettering.displayHeight)
            let height = inkHeight(of: render(HelloLetteringView(artwork: word, frame: written)), scale: 2)
            #expect(abs(height / formerHeight - 0.5) < 0.075, "\(height) pt of \(formerHeight) pt")
        }
    }

    /// The greeting never widens the notch past the maximum width, and every phrase stays one line.
    @Test func R20__greeting_fits_the_maximum_width_with_a_one_line_subtitle() {
        let written = HelloTimeline.frame(at: HelloTimeline.fadeStart)
        for word in HelloArtwork.words {
            let wordHeight = CGFloat(render(HelloLetteringView(artwork: word, frame: written)).height) / 2
            for phrase in Week.everyPhrase {
                let greeting = HelloGreeting(word: word, subtitle: phrase)
                let takeover = render(HelloGreetingView(greeting: greeting))
                #expect(CGFloat(takeover.width) / 2 <= HelloGreeting.maxWidth, "\(phrase)")
                let frame = render(HelloGreetingFrame(greeting: greeting, frame: written))
                // One line of 14 pt text under the word; a second line would add about 17 pt more.
                let subtitle = CGFloat(frame.height) / 2 - wordHeight
                #expect(subtitle > 12 && subtitle < 24, "\(phrase): \(subtitle) pt")
            }
        }
    }

    @Test func R20__subtitle_fades_in_once_the_word_is_written() throws {
        #expect(HelloTimeline.total <= 3.5)
        #expect(HelloTimeline.frame(at: HelloTimeline.drawEnd).drawn == 1)
        #expect(HelloTimeline.frame(at: HelloTimeline.fadeStart).subtitle == 1)
        for step in 0...70 {
            let frame = HelloTimeline.frame(at: Double(step) / 20)
            // The line appears only as the pen lands the last strokes, and goes with the word.
            if frame.subtitle > 0 { #expect(frame.drawn > 0.9, "\(Double(step) / 20) s") }
        }
        #expect(HelloTimeline.frame(at: HelloTimeline.total).opacity == 0)
        try withContext { context, host in
            HelloPlugin(context: context).activate()
            let duration = try #require(host.takeovers.first?.duration)
            #expect(duration == HelloTimeline.duration)
        }
    }

    /// Offscreen frames of both words, written only when HELLO_CAPTURE_DIR is set:
    /// `R20-render-frame-<word>-<moment>.png` with the pen at 30% and 60% of the word and the
    /// finished word with its subtitle.
    @Test func R20__offscreen_frames() throws {
        guard let directory = ProcessInfo.processInfo.environment["HELLO_CAPTURE_DIR"] else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        let finished = HelloTimeline.frame(at: HelloTimeline.fadeStart)
        let moments: [(name: String, frame: HelloTimeline.Frame)] = [
            ("0.3", HelloTimeline.Frame(drawn: 0.3, opacity: 1, glow: 0.65, subtitle: 0)),
            ("0.6", HelloTimeline.Frame(drawn: 0.6, opacity: 1, glow: 0.65, subtitle: 0)),
            ("complete", finished),
        ]
        let words: [(name: String, word: HelloArtwork, subtitle: String)] = [
            ("hello", .hello, "좋은 아침이에요."), ("annyeonghaseyo", .annyeonghaseyo, "즐거운 주말 저녁 보내세요."),
        ]
        for word in words {
            for moment in moments {
                let view = HelloGreetingFrame(greeting: HelloGreeting(word: word.word, subtitle: word.subtitle), frame: moment.frame)
                let image = render(view.padding(8).background(Color.black))
                let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try data.write(to: folder.appendingPathComponent("R20-render-frame-\(word.name)-\(moment.name).png"))
            }
        }
    }
}
