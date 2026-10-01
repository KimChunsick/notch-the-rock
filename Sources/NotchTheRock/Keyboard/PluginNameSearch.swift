import Foundation

/// Matching a plugin name against what is typed in the quick search: anywhere in the name, ignoring
/// case. Korean is matched as it is typed: an initial consonant alone (ㄴㅆ) matches a syllable
/// starting with it (날씨), and the last syllable may still be in composition (나 matches 날).
enum PluginNameSearch {
    static func matches(name: String, query: String) -> Bool {
        let needle = scalars(query.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty else { return true }
        let haystack = scalars(name)
        guard haystack.count >= needle.count else { return false }
        return (0...(haystack.count - needle.count)).contains { start in
            needle.indices.allSatisfy { index in
                matches(haystack[start + index], typed: needle[index], isLast: index == needle.count - 1)
            }
        }
    }

    private static func scalars(_ text: String) -> [Unicode.Scalar] {
        Array(text.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars)
    }

    private static func matches(_ character: Unicode.Scalar, typed: Unicode.Scalar, isLast: Bool) -> Bool {
        if character == typed { return true }
        guard let syllable = Syllable(character) else { return false }
        if let initial = initials.firstIndex(of: typed) { return syllable.initial == initial }
        // A syllable without a final consonant may still get one while it is being typed.
        if isLast, let partial = Syllable(typed), partial.final == 0 {
            return partial.initial == syllable.initial && partial.medial == syllable.medial
        }
        return false
    }

    /// The compatibility jamo a keyboard types for each initial consonant, in Unicode's order.
    private static let initials = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ".unicodeScalars)

    /// A precomposed Hangul syllable split into its initial, medial and final indices.
    private struct Syllable {
        let initial: Int
        let medial: Int
        let final: Int

        init?(_ scalar: Unicode.Scalar) {
            let index = Int(scalar.value) - 0xAC00
            guard (0..<11172).contains(index) else { return nil }
            initial = index / 588
            medial = index % 588 / 28
            final = index % 28
        }
    }
}
