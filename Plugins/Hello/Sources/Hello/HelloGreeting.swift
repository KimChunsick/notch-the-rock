import SwiftUI

/// When the greeting writes its word, shows the phrase under it, holds and fades, in seconds from
/// the moment it appears. The takeover lasts `total`, so the notch collapses as the fade ends.
enum HelloTimeline {
    struct Frame: Equatable {
        /// Fraction of the stroke written, 0...1.
        var drawn: Double
        var opacity: Double
        /// Strength of the glow around the ink, 0...1.
        var glow: Double
        /// Opacity of the phrase under the word, before the whole greeting fades.
        var subtitle: Double
    }

    /// The notch finishes opening before the pen starts.
    static let drawStart: TimeInterval = 0.2
    static let drawEnd: TimeInterval = 2.0
    /// The phrase fades in under the word as the pen lands.
    static let subtitleStart: TimeInterval = 1.9
    static let subtitleEnd: TimeInterval = 2.35
    /// The finished word and its phrase hold from `subtitleEnd` until the fade starts, long enough
    /// to read the phrase.
    static let fadeStart: TimeInterval = 3.05
    static let total: TimeInterval = 3.4
    static var duration: Duration { .milliseconds(Int((total * 1000).rounded())) }

    static func frame(at elapsed: TimeInterval) -> Frame {
        let writing = fraction(of: elapsed, from: drawStart, to: drawEnd)
        // Half linear, half smoothstep: the pen starts and lands gently without rushing the middle.
        let drawn = 0.5 * writing + 0.5 * writing * writing * (3 - 2 * writing)
        // The glow swells as the last letter lands, then settles while the word holds.
        let swell = fraction(of: elapsed, from: drawEnd - 0.3, to: drawEnd + 0.15)
        let settle = fraction(of: elapsed, from: drawEnd + 0.15, to: fadeStart)
        return Frame(
            drawn: drawn,
            opacity: 1 - fraction(of: elapsed, from: fadeStart, to: total),
            glow: 0.65 + 0.35 * swell - 0.15 * settle,
            subtitle: fraction(of: elapsed, from: subtitleStart, to: subtitleEnd)
        )
    }

    private static func fraction(of elapsed: TimeInterval, from start: TimeInterval, to end: TimeInterval) -> Double {
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
            HelloGreetingFrame(greeting: greeting, frame: HelloTimeline.frame(at: elapsed))
        }
        .padding(8)
        .onAppear { start = .now }
    }
}

/// One frame of the greeting: the handwritten word with one small line under it for the time and
/// day, centred. A phrase wider than the greeting's maximum width wraps at word boundaries.
struct HelloGreetingFrame: View {
    let greeting: HelloGreeting
    let frame: HelloTimeline.Frame

    var body: some View {
        VStack(spacing: 2) {
            HelloLetteringView(artwork: greeting.word, frame: frame)
            Text(greeting.subtitle)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: HelloGreeting.maxWidth)
                .opacity(frame.subtitle)
        }
        .opacity(frame.opacity)
    }
}

/// The handwritten word in one frame: the written part of the stroke in a soft gradient, a blurred
/// glow beneath it and a bright pen tip while writing. It is the artwork's own size and shrinks to
/// fit when offered less.
struct HelloLetteringView: View {
    let artwork: HelloArtwork
    let frame: HelloTimeline.Frame

    private static let ink = Gradient(colors: [
        Color(red: 0.47, green: 0.82, blue: 1.00),
        Color(red: 0.64, green: 0.62, blue: 1.00),
        Color(red: 0.98, green: 0.56, blue: 0.82),
        Color(red: 1.00, green: 0.77, blue: 0.52),
    ])

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let width = artwork.penWidth * artwork.scale(toFit: bounds)
            let written = artwork.trim(from: 0, to: frame.drawn)
            let gradient = LinearGradient(gradient: Self.ink, startPoint: .leading, endPoint: .trailing)
            ZStack {
                written.stroke(gradient, style: Self.pen(width * 3.2))
                    .blur(radius: width * 2.4)
                    .opacity(0.55 * frame.glow)
                written.stroke(gradient, style: Self.pen(width * 1.7))
                    .blur(radius: width * 0.7)
                    .opacity(0.85 * frame.glow)
                written.stroke(gradient, style: Self.pen(width))
                written.stroke(Color.white.opacity(0.45), style: Self.pen(width * 0.3))
                if frame.drawn > 0, frame.drawn < 1,
                   let tip = artwork.path(in: bounds).trimmedPath(from: 0, to: frame.drawn).currentPoint {
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

    private static func pen(_ width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }
}
