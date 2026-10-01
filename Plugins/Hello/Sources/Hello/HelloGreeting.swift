import SwiftUI

/// When the greeting writes its phrase, holds it and fades, in seconds from the moment it appears.
/// The takeover lasts `total`, so the notch collapses as the fade ends.
struct HelloTimeline: Equatable {
    struct Frame: Equatable {
        /// Fraction of the writing time gone, 0...1. Each hand moves its pen through it its own way.
        var writing: Double
        var opacity: Double
        /// Strength of the glow around the ink, 0...1.
        var glow: Double
    }

    /// The notch finishes opening before the pen starts.
    static let drawStart: TimeInterval = 0.2
    let drawEnd: TimeInterval
    /// The finished phrase holds from `drawEnd` until the fade starts.
    let fadeStart: TimeInterval
    let total: TimeInterval

    /// "hello": written in 1.8 s and held for about a second.
    static let hello = HelloTimeline(drawEnd: 2.0, fadeStart: 3.05, total: 3.4)

    private init(drawEnd: TimeInterval, fadeStart: TimeInterval, total: TimeInterval) {
        self.drawEnd = drawEnd
        self.fadeStart = fadeStart
        self.total = total
    }

    /// A phrase the pen writes in `writing` seconds, held a second and a little more for each of its
    /// `syllables` so it can be read, then faded out.
    init(writing: TimeInterval, syllables: Int) {
        drawEnd = Self.drawStart + writing
        fadeStart = drawEnd + 1.0 + 0.06 * Double(syllables)
        total = fadeStart + 0.35
    }

    var duration: Duration { .milliseconds(Int((total * 1000).rounded())) }

    func frame(at elapsed: TimeInterval) -> Frame {
        // The glow swells as the last stroke lands, then settles while the phrase holds.
        let swell = fraction(of: elapsed, from: drawEnd - 0.3, to: drawEnd + 0.15)
        let settle = fraction(of: elapsed, from: drawEnd + 0.15, to: fadeStart)
        return Frame(
            writing: fraction(of: elapsed, from: Self.drawStart, to: drawEnd),
            opacity: 1 - fraction(of: elapsed, from: fadeStart, to: total),
            glow: 0.65 + 0.35 * swell - 0.15 * settle
        )
    }

    private func fraction(of elapsed: TimeInterval, from start: TimeInterval, to end: TimeInterval) -> Double {
        min(max((elapsed - start) / (end - start), 0), 1)
    }
}

/// The takeover content: writes the greeting from the moment it appears.
struct HelloGreetingView: View {
    let greeting: HelloGreeting
    @State private var start: Date?

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = start.map { timeline.date.timeIntervalSince($0) } ?? 0
            HelloGreetingFrame(greeting: greeting, frame: greeting.timeline.frame(at: elapsed))
        }
        .padding(HelloGreeting.padding)
        .onAppear { start = .now }
    }
}

/// One frame of the greeting: the phrase as far as the pen has written it, and nothing else.
struct HelloGreetingFrame: View {
    let greeting: HelloGreeting
    let frame: HelloTimeline.Frame

    var body: some View {
        Group {
            switch greeting.writing {
            case .hello: HelloLetteringView(artwork: .hello, frame: frame)
            case .hangul(let handwriting): HangulHandwritingView(handwriting: handwriting, frame: frame)
            }
        }
        .opacity(frame.opacity)
    }
}

/// The greeting's ink, the same for both hands: `path` stroked `width` wide in a soft gradient from
/// sky blue through lavender and pink to peach, leading to trailing across the whole frame it is
/// given, with a bright core and a blurred glow beneath it as strong as `glow`.
struct GreetingInk: View {
    let path: Path
    let width: CGFloat
    let glow: Double

    private static let gradient = Gradient(colors: [
        Color(red: 0.47, green: 0.82, blue: 1.00),
        Color(red: 0.64, green: 0.62, blue: 1.00),
        Color(red: 0.98, green: 0.56, blue: 0.82),
        Color(red: 1.00, green: 0.77, blue: 0.52),
    ])

    var body: some View {
        let ink = LinearGradient(gradient: Self.gradient, startPoint: .leading, endPoint: .trailing)
        ZStack {
            path.stroke(ink, style: Self.pen(width * 3.2))
                .blur(radius: width * 2.4)
                .opacity(0.55 * glow)
            path.stroke(ink, style: Self.pen(width * 1.7))
                .blur(radius: width * 0.7)
                .opacity(0.85 * glow)
            path.stroke(ink, style: Self.pen(width))
            path.stroke(Color.white.opacity(0.45), style: Self.pen(width * 0.3))
        }
    }

    private static func pen(_ width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }
}

/// The handwritten word in one frame: the written part of the stroke in the greeting's ink and a
/// bright pen tip while writing. It is the artwork's own size and shrinks to fit when offered less.
struct HelloLetteringView: View {
    let artwork: HelloArtwork
    let frame: HelloTimeline.Frame

    /// Fraction of the stroke written once `writing` of the writing time has gone: half linear, half
    /// smoothstep, so the pen starts and lands gently without rushing the middle.
    static func drawn(at writing: Double) -> Double {
        0.5 * writing + 0.5 * writing * writing * (3 - 2 * writing)
    }

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let width = artwork.penWidth * artwork.scale(toFit: bounds)
            let drawn = Self.drawn(at: frame.writing)
            ZStack {
                GreetingInk(path: artwork.trim(from: 0, to: drawn).path(in: bounds), width: width, glow: frame.glow)
                if drawn > 0, drawn < 1,
                   let tip = artwork.path(in: bounds).trimmedPath(from: 0, to: drawn).currentPoint {
                    Circle()
                        .fill(Color.white)
                        .frame(width: width * 1.8, height: width * 1.8)
                        .blur(radius: width * 0.6)
                        .position(tip)
                }
            }
        }
        .aspectRatio(artwork.canvas.width / artwork.canvas.height, contentMode: .fit)
        .frame(
            idealWidth: artwork.size.width, maxWidth: artwork.size.width,
            idealHeight: artwork.size.height, maxHeight: artwork.size.height
        )
    }
}

/// A Korean phrase in one frame: the strokes written so far in the greeting's ink with round ends,
/// its gradient running across the whole phrase (both lines when it wraps), and a soft pen tip
/// while the pen is down.
struct HangulHandwritingView: View {
    let handwriting: HangulHandwriting
    let frame: HelloTimeline.Frame

    var body: some View {
        let pen = handwriting.pen(at: frame.writing * handwriting.duration)
        let ink = handwriting.ink(for: pen)
        let width = HangulHandwriting.penWidth
        ZStack {
            GreetingInk(path: ink, width: width, glow: frame.glow)
            if frame.writing > 0, frame.writing < 1, let tip = handwriting.tip(for: pen) {
                Circle()
                    .fill(Color.white)
                    .frame(width: width * 1.6, height: width * 1.6)
                    .blur(radius: width * 0.5)
                    .position(tip)
            }
        }
        .frame(width: handwriting.size.width, height: handwriting.size.height)
    }
}
