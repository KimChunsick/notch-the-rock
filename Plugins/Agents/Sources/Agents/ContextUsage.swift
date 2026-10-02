import Foundation
import HookBridge

/// How full a session's context window is, in percent, counted the way each agent counts it itself.
enum ContextUsage {
    static let claudeWindow = 200_000
    static let claudeLongWindow = 1_000_000
    /// Models whose window is 1M without opting in: `native_1m` in Claude Code 2.1.287's bundled model catalog.
    static let claudeLongModels = [
        "claude-opus-4-7", "claude-opus-4-8", "claude-opus-5", "claude-opus-5-5", "claude-sonnet-5", "claude-sonnet-5-5",
        "claude-fable-5", "claude-fable-5-1", "claude-mythos-5", "claude-mythos-5-1",
    ]
    /// Models Claude Code 2.1.287 never runs with 1M (`bpe`), besides every `claude-3-` model. `claude-opus-4` is
    /// how the API names `claude-opus-4-0`. Opus 4.6 and Sonnet 4 to 4.6 run with 1M only when the session opted
    /// in, which a transcript does not record.
    static let claudeShortModels = ["claude-opus-4", "claude-opus-4-0", "claude-opus-4-1", "claude-opus-4-5", "claude-haiku-4-5"]
    /// How much of a transcript's end is read; the latest assistant message is near it.
    static let tailBytes = 512 << 10
    /// Tokens codex counts as always in the window (`BASELINE_TOKENS` in codex's protocol).
    static let codexBaseline = 12_000

    /// The window Claude Code sizes a session's model with, when the transcript settles it: the `[1m]` opt-in,
    /// a model that is always 1M or more than 200k used (only a 1M session holds that) mean 1M, a model that
    /// never runs with 1M means 200k. Nil for a model that may run with either and one the catalog lacks.
    static func claudeWindow(model: String, used: Int) -> Int? {
        if model.range(of: "[1m]", options: .caseInsensitive) != nil || used > claudeWindow || claudeLongModels.contains(where: { names(model, $0) }) {
            return claudeLongWindow
        }
        if model.contains("claude-3-") || claudeShortModels.contains(where: { names(model, $0) }) {
            return claudeWindow
        }
        return nil
    }

    /// Whether the transcript's `model` (dated, or with a provider's prefix) is the catalog's `id`: `id` followed
    /// by neither a digit nor a one-digit minor version, so `claude-opus-5` is not `claude-opus-5-5` but is
    /// `claude-opus-5-20260101`.
    static func names(_ model: String, _ id: String) -> Bool {
        model.range(of: NSRegularExpression.escapedPattern(for: id) + #"(?!\d)(?!-\d(?!\d))"#, options: .regularExpression) != nil
    }

    /// Claude Code's own: input, cache creation and cache read tokens of the latest assistant message
    /// with usage, over the window, rounded and clamped to 0...100. Nil when the tail has no such
    /// message, its counts are not whole non-negative numbers or its window is not certain; the tail's
    /// first line may be cut and is skipped.
    static func claude(tail: Data) -> Int? {
        for line in tail.split(separator: UInt8(ascii: "\n")).reversed() {
            guard line.range(of: Data(#""assistant""#.utf8)) != nil,
                  let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line)),
                  value["type"]?.string == "assistant", value["isSidechain"]?.bool != true,
                  let message = value["message"], let model = message["model"]?.string, model != "<synthetic>",
                  let usage = message["usage"] else { continue }
            var used = 0
            for key in ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"] {
                guard let member = usage[key], member != .null else { continue }
                guard let count = tokens(member) else { return nil }
                let (sum, overflow) = used.addingReportingOverflow(count)
                guard !overflow else { return nil }
                used = sum
            }
            guard used > 0 else { continue }
            guard let window = claudeWindow(model: model, used: used) else { return nil }
            return clamped(Double(used) / Double(window) * 100)
        }
        return nil
    }

    /// The share of the session's transcript at `url`, read from its last `tailBytes`.
    static func claude(transcript url: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(),
              (try? handle.seek(toOffset: size - min(size, UInt64(tailBytes)))) != nil,
              let tail = try? handle.readToEnd() else { return nil }
        return claude(tail: tail)
    }

    /// 100 minus codex's "% context left": `percent_of_context_window_remaining` on the last turn's
    /// tokens, both sides less the baseline codex always counts.
    static func codexPercent(lastTotal: Int, window: Int) -> Int {
        guard window > codexBaseline else { return 100 }
        let effective = Double(window - codexBaseline)
        let remaining = max(0, effective - Double(max(0, lastTotal - codexBaseline)))
        return 100 - clamped(remaining / effective * 100)
    }

    /// From a token usage's last-turn total and window, nil when either is missing or not a token count.
    static func codex(lastTotal: JSONValue?, window: JSONValue?) -> Int? {
        guard let last = tokens(lastTotal), let window = tokens(window) else { return nil }
        return codexPercent(lastTotal: last, window: window)
    }

    /// A token count: a JSON number that is a whole, non-negative `Int`. Nil for anything else, so a
    /// fraction, a negative, an infinity or a number beyond `Int` leaves the percent unknown.
    static func tokens(_ value: JSONValue?) -> Int? {
        guard case .number(let number)? = value, let count = Int(exactly: number), count >= 0 else { return nil }
        return count
    }

    private static func clamped(_ percent: Double) -> Int {
        Int(min(100, max(0, percent)).rounded())
    }
}
