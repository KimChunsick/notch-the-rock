import Foundation
import HookBridge

/// How full a session's context window is, in percent, counted the way each agent counts it itself.
enum ContextUsage {
    static let claudeWindow = 200_000
    static let claudeLongWindow = 1_000_000
    /// Models whose window is 1M without the `[1m]` opt-in: `native_1m` in Claude Code 2.1.287's
    /// bundled model list. A transcript's model id may carry a date after these.
    static let claudeLongModels = ["claude-opus-4-7", "claude-opus-4-8", "claude-opus-5", "claude-sonnet-5", "claude-fable-5", "claude-mythos-5"]
    /// How much of a transcript's end is read; the latest assistant message is near it.
    static let tailBytes = 512 << 10
    /// Tokens codex counts as always in the window (`BASELINE_TOKENS` in codex's protocol).
    static let codexBaseline = 12_000

    /// The window Claude Code sizes a session's model with. The transcript does not say whether the
    /// session opted into 1M, so a 200k model past 200k is taken as running with 1M.
    static func claudeWindow(model: String, used: Int) -> Int {
        let long = model.lowercased().hasSuffix("[1m]") || claudeLongModels.contains { model.hasPrefix($0) } || used > claudeWindow
        return long ? claudeLongWindow : claudeWindow
    }

    /// Claude Code's own: input, cache creation and cache read tokens of the latest assistant message
    /// with usage, over the window, rounded and clamped to 0...100. Nil when the tail has no such
    /// message; the tail's first line may be cut and is skipped.
    static func claude(tail: Data) -> Int? {
        for line in tail.split(separator: UInt8(ascii: "\n")).reversed() {
            guard line.range(of: Data(#""assistant""#.utf8)) != nil,
                  let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line)),
                  value["type"]?.string == "assistant", value["isSidechain"]?.bool != true,
                  let message = value["message"], let model = message["model"]?.string, model != "<synthetic>",
                  let usage = message["usage"] else { continue }
            let used = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].reduce(0) { $0 + count(usage[$1]) }
            guard used > 0 else { continue }
            return clamped(Double(used) / Double(claudeWindow(model: model, used: used)) * 100)
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

    /// From a token usage's last-turn total and window, nil when either is missing.
    static func codex(lastTotal: JSONValue?, window: JSONValue?) -> Int? {
        guard case .number(let last)? = lastTotal, case .number(let window)? = window else { return nil }
        return codexPercent(lastTotal: Int(last), window: Int(window))
    }

    private static func count(_ value: JSONValue?) -> Int {
        guard case .number(let number)? = value else { return 0 }
        return Int(number)
    }

    private static func clamped(_ percent: Double) -> Int {
        Int(min(100, max(0, percent)).rounded())
    }
}
