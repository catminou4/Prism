import Foundation
import NaturalLanguage
import Synchronization

/// IPTV panels sometimes concatenate several translations in one synopsis field.
public enum ProviderSynopsis {
    /// Bounded memoization: `cleaned` runs regex + language recognition and the same provider
    /// plot repeats across variants. `Mutex` keeps `@concurrent` callers safe.
    private static let cache = CleanedCache()

    /// Editorial cards prefer a French synopsis, then an English one, across available editions.
    /// Unknown Latin-language text is a last resort. Another writing system stays off the card.
    public static func preferredFrenchOrEnglish(from values: [String?]) -> String? {
        let recognizer = NLLanguageRecognizer()
        var visited: Set<String> = []
        var english: String?
        var unknown: String?
        for value in values {
            guard let text = cleaned(value), visited.insert(text).inserted, isMostlyLatin(text) == true else { continue }
            switch language(of: text, with: recognizer) {
            case .french: return text
            case .english: english = english ?? text
            case nil: unknown = unknown ?? text
            default: continue
            }
        }
        return english ?? unknown
    }

    public static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        if let hit = cache.value(for: value) { return hit }
        let result = cleanedUncached(value)
        cache.store(result, for: value)
        return result
    }

    private static func cleanedUncached(_ value: String) -> String? {
        guard let first = value.unicodeScalars.first, let last = value.unicodeScalars.last else { return nil }
        let whitespace = CharacterSet.whitespacesAndNewlines
        let text = whitespace.contains(first) || whitespace.contains(last)
            ? value.trimmingCharacters(in: whitespace) : value
        guard !text.isEmpty else { return nil }
        guard needsNormalization(text) else { return text }

        let paragraphs = fragments(in: text)
        guard paragraphs.count > 1, paragraphs.count <= 12 else { return joined(paragraphs) }

        let recognizer = NLLanguageRecognizer()
        let languages = paragraphs.map { language(of: $0.text, with: recognizer) }
        let scripts = paragraphs.map { isMostlyLatin($0.text) }
        guard Set(languages.compactMap { $0 }).count > 1 || Set(scripts.compactMap { $0 }).count > 1 else {
            return joined(paragraphs)
        }

        let preferred = languages.firstIndex(of: .french) ?? languages.firstIndex(of: .english)
            ?? scripts.firstIndex(of: true) ?? paragraphs.startIndex
        let language = languages[preferred]
        let script = scripts[preferred]
        let retained = paragraphs.indices.filter { index in
            if let candidate = languages[index], let language { return candidate == language }
            return scripts[index] == script
        }
        return joined(retained.map { paragraphs[$0] })
    }

    private static func needsNormalization(_ text: String) -> Bool {
        var previousWasSpace = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x20:
                if previousWasSpace { return true }
                previousWasSpace = true
            case 0x09...0x0D, 0x85, 0x2028, 0x2029:
                return true
            default:
                previousWasSpace = false
            }
        }
        return false
    }

    private struct Fragment {
        let text: String
        let separator: String
    }

    private static let boundary = try? NSRegularExpression(pattern: #"(?:\R\h*){2,}|\h{4,}"#)
    private static let latin = try? NSRegularExpression(pattern: #"\p{Latin}"#)

    private static func fragments(in text: String) -> [Fragment] {
        let matches = boundary?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
        var parts: [Fragment] = []
        var start = text.startIndex
        var separator = ""
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            let chunk = normalized(text[start..<range.lowerBound])
            if !chunk.isEmpty { parts.append(Fragment(text: chunk, separator: separator)) }
            separator = text[range].contains(where: \.isNewline) ? "\n\n" : " "
            start = range.upperBound
        }
        let tail = normalized(text[start...])
        if !tail.isEmpty { parts.append(Fragment(text: tail, separator: separator)) }
        return parts
    }

    private static func normalized(_ text: Substring) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func joined(_ parts: [Fragment]) -> String? {
        guard let first = parts.first else { return nil }
        return first.text + parts.dropFirst().map { $0.separator + $0.text }.joined()
    }

    private static func language(of text: String, with recognizer: NLLanguageRecognizer) -> NLLanguage? {
        guard text.utf8.count >= 60, text.split(separator: " ", maxSplits: 6).count >= 6 else { return nil }
        recognizer.reset()
        recognizer.processString(String(text.prefix(500)))
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence >= 0.75 else {
            return nil
        }
        return language
    }

    private static func isMostlyLatin(_ text: String) -> Bool? {
        let letters = text.unicodeScalars.lazy.filter { $0.properties.isAlphabetic }.count
        guard letters > 0, let latin else { return nil }
        let latinLetters = latin.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        return latinLetters * 2 > letters
    }
}

/// Thread-safe bounded memo for `ProviderSynopsis.cleaned` — plots are long, so the cap is
/// smaller than the title cache's. `nil` results are cached too (`.some(nil)`).
private final class CleanedCache: Sendable {
    private let storage = Mutex<[String: String?]>([:])
    private let limit = 10_000

    func value(for key: String) -> String?? {
        storage.withLock { $0[key] }
    }

    func store(_ value: String?, for key: String) {
        storage.withLock { map in
            if map.count >= limit { map.removeAll(keepingCapacity: true) }
            map[key] = .some(value)
        }
    }
}
