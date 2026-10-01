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

    /// Every phrase the Hangul hand writes, in a stable order.
    static var koreanPhrases: [String] {
        everyPhrase.filter { $0 != HelloPhrases.hello }.sorted()
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
func render(_ view: some View, scale: CGFloat = 2) -> CGImage {
    let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
    renderer.scale = scale
    return renderer.cgImage!
}

@MainActor
func writePNG(_ view: some View, scale: CGFloat, to url: URL) throws {
    let image = render(view.background(Color.black), scale: scale)
    let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    try data.write(to: url)
}

extension HelloTimeline.Frame {
    /// The pen `writing` of the way through its time, fully opaque, with the glow it has while writing.
    static func writing(_ writing: Double) -> Self {
        Self(writing: writing, opacity: 1, glow: 0.65)
    }
}

@MainActor
@Suite struct GreetingTests {
    @Test(arguments: [
        (Week.wednesday, 3, HelloPhrases.Slot.dawn, "고요한 새벽이에요"),
        (Week.sunday, 3, .dawn, "고요한 주말 새벽이에요"),
        (Week.wednesday, 8, .morning, "좋은 아침이에요"),
        (Week.saturday, 8, .morning, "여유로운 주말 아침이에요"),
        (Week.wednesday, 15, .afternoon, "오후도 힘내세요"),
        (Week.saturday, 15, .afternoon, "편안한 주말 오후 되세요"),
        (Week.wednesday, 19, .evening, "오늘 하루 수고했어요"),
        (Week.sunday, 19, .evening, "즐거운 주말 저녁 보내세요"),
        (Week.wednesday, 23, .night, "좋은 밤이에요"),
        (Week.saturday, 23, .night, "느긋한 주말 밤이에요"),
    ])
    func R19__each_slot_has_its_weekday_and_weekend_phrases(day: Int, hour: Int, slot: HelloPhrases.Slot, phrase: String) {
        let date = Week.date(day: day, hour: hour)
        #expect(HelloPhrases.slot(for: date, calendar: Week.calendar) == slot)
        #expect(HelloPhrases.phrases(for: date, calendar: Week.calendar).contains(phrase))
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

    /// With the date injected, the greeting is one phrase of that hour's pool, and over many picks
    /// every phrase of it turns up, "hello" and "안녕하세요" included.
    @Test(arguments: [
        (Week.wednesday, 9, ["좋은 아침이에요"]),
        (Week.wednesday, 15, ["오후도 힘내세요"]),
        (Week.wednesday, 19, ["오늘 하루 수고했어요", "편안한 저녁 보내세요"]),
        (Week.wednesday, 23, ["좋은 밤이에요", "오늘 밤도 푹 쉬세요"]),
        (Week.tuesday, 3, ["고요한 새벽이에요", "새벽까지 수고 많아요"]),
        (Week.saturday, 9, ["좋은 아침이에요", "여유로운 주말 아침이에요"]),
        (Week.sunday, 15, ["편안한 주말 오후 되세요"]),
        (Week.saturday, 19, ["즐거운 주말 저녁 보내세요", "편안한 저녁 보내세요"]),
        (Week.sunday, 23, ["좋은 밤이에요", "느긋한 주말 밤이에요"]),
        (Week.monday, 9, ["좋은 아침이에요", "힘찬 한 주 보내세요"]),
        (Week.friday, 19, ["오늘 하루 수고했어요", "편안한 저녁 보내세요", "한 주 동안 수고했어요"]),
    ])
    func R19__greeting_is_one_phrase_of_the_hours_pool(day: Int, hour: Int, own: [String]) {
        let date = Week.date(day: day, hour: hour)
        #expect(HelloPhrases.phrases(for: date, calendar: Week.calendar) == own + ["hello", "안녕하세요"])
        var generator = SplitMix64(state: UInt64(day * 24 + hour))
        var picked = Set<String>()
        for _ in 0..<96 {
            picked.insert(HelloGreeting.random(for: date, calendar: Week.calendar, using: &generator).phrase)
        }
        #expect(picked == Set(own + ["hello", "안녕하세요"]))
    }

    /// Every hour of every day offers "hello" and "안녕하세요", and no phrase carries punctuation the
    /// pen would have to write.
    @Test func R21__hello_and_annyeonghaseyo_are_in_every_pool() {
        for day in 0..<7 {
            for hour in 0..<24 {
                let pool = HelloPhrases.phrases(for: Week.date(day: day, hour: hour), calendar: Week.calendar)
                #expect(pool.contains("hello") && pool.contains("안녕하세요"), "day \(day) hour \(hour)")
            }
        }
        for phrase in Week.everyPhrase {
            #expect(phrase.allSatisfy { $0.isLetter || $0 == " " }, "\(phrase)")
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
                #expect(one.phrase == other.phrase)
            }
        }
    }

    /// "hello" is still the one cursive stroke on its own timing; every other phrase is the Hangul hand.
    @Test func R21__hello_keeps_its_cursive_and_korean_uses_the_hangul_hand() {
        for phrase in Week.everyPhrase {
            switch HelloGreeting(phrase: phrase).writing {
            case .hello: #expect(phrase == "hello")
            case .hangul(let handwriting): #expect(handwriting.lines.joined(separator: " ") == phrase)
            }
        }
        #expect(HelloGreeting(phrase: "hello").timeline == .hello)
        #expect(HelloTimeline.hello.drawEnd == 2.0 && HelloTimeline.hello.fadeStart == 3.05 && HelloTimeline.hello.total == 3.4)
    }

    /// Every syllable of every Korean phrase decomposes into jamo whose strokes are drawn by hand.
    @Test func R21__every_pool_syllable_has_hand_drawn_jamo() {
        for phrase in Week.koreanPhrases {
            #expect(HangulHandwriting.missingJamo(in: phrase).isEmpty, "\(phrase): \(HangulHandwriting.missingJamo(in: phrase))")
            for syllable in phrase where syllable != " " {
                #expect(HangulHandwriting.missingJamo(in: String(syllable)).isEmpty, "\(syllable) in \(phrase)")
            }
        }
        // A jamo the table lacks is reported, never drawn as nothing.
        #expect(HangulHandwriting.missingJamo(in: "커") != [])
        #expect(HangulHandwriting.missingJamo(in: "a") != [])
    }

    /// Nothing in the plugin sets letters from a font: no glyph outlines, no text under the pen.
    @Test func R21__module_draws_no_font_outlines() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Hello")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count >= 6)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for symbol in ["CoreText", "CTFont", "CTLine", "CTRun", "PathForGlyph", "NSFont", "NSAttributedString", "glyph"] {
                #expect(!source.contains(symbol), "\(file.lastPathComponent) uses \(symbol)")
            }
            if file.lastPathComponent != "HelloSettings.swift" {
                #expect(!source.contains("Text("), "\(file.lastPathComponent) sets text")
            }
        }
    }

    /// The greeting is the handwriting alone: its frame is exactly the handwriting's size.
    @Test func R21__greeting_is_only_the_handwriting() {
        for phrase in Week.everyPhrase {
            let greeting = HelloGreeting(phrase: phrase)
            let image = render(HelloGreetingFrame(greeting: greeting, frame: .writing(1)), scale: 1)
            let expected: CGSize = switch greeting.writing {
            case .hello: HelloArtwork.hello.size
            case .hangul(let handwriting): handwriting.size
            }
            #expect(abs(CGFloat(image.width) - expected.width) <= 1 && abs(CGFloat(image.height) - expected.height) <= 1, "\(phrase)")
        }
    }

    /// Every phrase lays out within the maximum width in at most two lines, wrapping at spaces, with
    /// all its ink inside its frame; the longer phrases do wrap.
    @Test func R21__every_phrase_fits_the_maximum_width_in_two_lines() {
        var wrapped = 0
        for phrase in Week.koreanPhrases {
            let handwriting = HangulHandwriting(phrase)
            #expect(handwriting.lines.count <= 2, "\(phrase): \(handwriting.lines)")
            #expect(handwriting.lines.joined(separator: " ") == phrase)
            if handwriting.lines.count == 2 { wrapped += 1 }
            #expect(handwriting.size.width + 2 * HelloGreeting.padding <= HelloGreeting.maxWidth, "\(phrase)")
            let takeover = render(HelloGreetingView(greeting: HelloGreeting(phrase: phrase)), scale: 1)
            #expect(CGFloat(takeover.width) <= HelloGreeting.maxWidth, "\(phrase)")
            var ink = Path()
            for stroke in handwriting.strokes { ink.addPath(stroke.path) }
            let inked = ink.boundingRect.insetBy(dx: -HangulHandwriting.penWidth / 2, dy: -HangulHandwriting.penWidth / 2)
            #expect(CGRect(origin: .zero, size: handwriting.size).contains(inked), "\(phrase): \(inked)")
        }
        #expect(wrapped >= 3)
        #expect(HangulHandwriting("안녕하세요").lines == ["안녕하세요"])
        #expect(HangulHandwriting("즐거운 주말 저녁 보내세요").lines.count == 2)
    }

    /// The pen moves at one speed and lifts between strokes: what it has written only grows, its tip
    /// slides along the stroke while down and is lifted, never dragged, from one stroke to the next.
    @Test(arguments: ["안녕하세요", "좋은 아침이에요", "즐거운 주말 저녁 보내세요"])
    func R21__pen_writes_stroke_by_stroke_and_lifts_between(phrase: String) throws {
        let handwriting = HangulHandwriting(phrase)
        let step = HangulHandwriting.liftPause / 3
        var previous: (pen: HangulHandwriting.Pen, tip: CGPoint?, length: CGFloat)?
        var lifted = false
        var time = 0.0
        while time <= handwriting.duration + step {
            let pen = handwriting.pen(at: time)
            let tip = handwriting.tip(for: pen)
            let length = handwriting.inkedLength(for: pen)
            #expect((tip != nil) == pen.isDown)
            if let previous {
                #expect(length >= previous.length - 0.001, "t \(time)")
                #expect(pen.stroke >= previous.pen.stroke, "t \(time)")
                // SwiftUI measures a curve a few percent differently from the pen's own measure.
                if let tip, let last = previous.tip, pen.stroke == previous.pen.stroke {
                    #expect(hypot(tip.x - last.x, tip.y - last.y) <= HangulHandwriting.penSpeed * step * 1.15, "t \(time)")
                }
                if pen.isDown, previous.pen.isDown, pen.stroke != previous.pen.stroke {
                    Issue.record("t \(time): the pen moved to stroke \(pen.stroke) without lifting")
                }
            }
            if !pen.isDown { lifted = true }
            previous = (pen, tip, length)
            time += step
        }
        #expect(lifted)
        let end = handwriting.pen(at: handwriting.duration + 1)
        #expect(end.stroke == handwriting.strokes.count && !end.isDown)
        let total = handwriting.strokes.reduce(0) { $0 + $1.length }
        #expect(abs(handwriting.inkedLength(for: end) - total) < 0.001)
        // Each stroke starts where the pen lands.
        for (index, stroke) in handwriting.strokes.enumerated() {
            let landing = try #require(handwriting.tip(for: HangulHandwriting.Pen(stroke: index, fraction: 0.0001, isDown: true)))
            #expect(hypot(landing.x - stroke.start.x, landing.y - stroke.start.y) < 0.5)
        }
    }

    /// The pen keeps one speed, so the takeover lasts as long as the phrase needs: "안녕하세요" in
    /// about 1.6–2 s, the longest phrase in at most about 4 s, then a read hold and a fade.
    @Test func R21__duration_follows_the_phrase() throws {
        let annyeong = HangulHandwriting("안녕하세요")
        #expect(annyeong.duration >= 1.6 && annyeong.duration <= 2.0, "\(annyeong.duration)")
        var longest = 0.0
        for phrase in Week.koreanPhrases {
            let greeting = HelloGreeting(phrase: phrase)
            guard case .hangul(let handwriting) = greeting.writing else { continue }
            longest = max(longest, handwriting.duration)
            let timeline = greeting.timeline
            #expect(timeline.drawEnd == HelloTimeline.drawStart + handwriting.duration)
            #expect(timeline.fadeStart - timeline.drawEnd >= 1.0, "\(phrase)")
            #expect(timeline.total > timeline.fadeStart)
            #expect(timeline.frame(at: timeline.drawEnd).writing == 1)
            #expect(timeline.frame(at: timeline.total).opacity == 0)
        }
        #expect(longest <= 4.0, "\(longest)")
    }

    /// The takeover lasts exactly as long as the greeting the plugin writes, so a long Korean phrase
    /// is never cut short at hello's length.
    @Test func R21__takeover_lasts_as_long_as_the_written_greeting() throws {
        let long = HelloGreeting(phrase: "즐거운 주말 저녁 보내세요")
        #expect(long.timeline.duration > HelloTimeline.hello.duration)
        for (phrase, expected) in [(long.phrase, long.timeline.duration), (HelloPhrases.hello, HelloTimeline.hello.duration)] {
            try withContext { context, host in
                HelloPlugin(context: context) { HelloGreeting(phrase: phrase) }.activate()
                let duration = try #require(host.takeovers.first?.duration)
                #expect(duration == expected, "\(phrase)")
            }
        }
    }

    /// The same phrase always comes out the same, while each syllable keeps a wobble of its own.
    @Test func R21__paths_are_deterministic_with_per_syllable_wobble() throws {
        for phrase in Week.koreanPhrases {
            #expect(HangulHandwriting(phrase).strokes.map(\.path) == HangulHandwriting(phrase).strokes.map(\.path))
        }
        // "고요한 주말 새벽이에요" writes 요 twice; the two differ beyond where they sit.
        let strokes = HangulHandwriting("요 요").strokes
        #expect(strokes.count % 2 == 0)
        let first = strokes[..<(strokes.count / 2)], second = strokes[(strokes.count / 2)...]
        let shift = CGPoint(x: second.first!.start.x - first.first!.start.x, y: second.first!.start.y - first.first!.start.y)
        let shapes = zip(first, second).map { one, other in
            hypot(other.start.x - one.start.x - shift.x, other.start.y - one.start.y - shift.y) + abs(other.length - one.length)
        }
        #expect(shapes.reduce(0, +) > 0.5)
    }

    /// One line of Korean is as tall as "hello": half the hello before R19, within 15%.
    @Test func R19__writing_is_half_the_former_hello_height() {
        let formerHeight = inkHeight(of: render(HelloLetteringView(artwork: .formerHello, frame: .writing(1))), scale: 2)
        #expect(formerHeight > 100)
        for phrase in ["hello", "안녕하세요", "좋은 밤이에요"] {
            let height = inkHeight(of: render(HelloGreetingFrame(greeting: HelloGreeting(phrase: phrase), frame: .writing(1))), scale: 2)
            #expect(abs(height / formerHeight - 0.5) < 0.075, "\(phrase): \(height) pt of \(formerHeight) pt")
        }
    }

    /// Offscreen renders, written only when HELLO_CAPTURE_DIR is set (HELLO_CAPTURE_TAG names the
    /// iteration, "final" by default): every Korean phrase finished at real size and at 3×,
    /// "안녕하세요" at 3×, and the pen at 30% and 60% of three phrases above the finished phrase.
    @Test func R21__offscreen_renders() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["HELLO_CAPTURE_DIR"] else { return }
        let tag = environment["HELLO_CAPTURE_TAG"] ?? "final"
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        func written(_ phrase: String, _ writing: Double = 1) -> some View {
            HelloGreetingFrame(greeting: HelloGreeting(phrase: phrase), frame: .writing(writing))
        }
        let phrases = Week.koreanPhrases
        let sheet = VStack(alignment: .leading, spacing: 10) {
            ForEach(phrases, id: \.self) { written($0) }
        }.padding(12)
        try writePNG(sheet, scale: 1, to: folder.appendingPathComponent("R21-render-sheet-\(tag).png"))
        let half = (phrases.count + 1) / 2
        let grid = HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) { ForEach(phrases[..<half], id: \.self) { written($0) } }
            VStack(alignment: .leading, spacing: 10) { ForEach(phrases[half...], id: \.self) { written($0) } }
        }.padding(12)
        try writePNG(grid, scale: 3, to: folder.appendingPathComponent("R21-render-sheet3x-\(tag).png"))
        try writePNG(written("안녕하세요").padding(12), scale: 3, to: folder.appendingPathComponent("R21-render-annyeonghaseyo-\(tag).png"))
        for (name, phrase) in [("annyeonghaseyo", "안녕하세요"), ("joeun-achim", "좋은 아침이에요"), ("longest", "즐거운 주말 저녁 보내세요")] {
            let frames = VStack(alignment: .leading, spacing: 10) {
                written(phrase, 0.3)
                written(phrase, 0.6)
                written(phrase)
            }.padding(12)
            try writePNG(frames, scale: 2, to: folder.appendingPathComponent("R21-render-frames-\(name)-\(tag).png"))
        }
    }
}
