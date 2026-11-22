import Foundation

/// Last presentation pass on an already normalized film or series name. Removes leftovers the
/// token pipeline keeps because they look like words:
///
/// - credits appended by providers: `A Fistful Of Dollars CLINT EASTWOOD, SERGIO LEONE`, `The Runner NICOLAS CAGE`
/// - language notes: `The Fall Of El Mayo (SPANISH MULTI SUB)`, `Anna (Svenskt Tal)`
/// - translations appended in another script: `Tulsa King پادشاه تالسا`
/// - run spans on series: `The Killing (2011-2014)`
/// - collection brands and marketing prefixes: `… Hallmark`, `Une Présentation Spéciale Marvel Television : …`
/// - file-name punctuation: `Alparslan_ Büyük Selçuklu`, `Cry_Wolf`, `Taylor Swift | The Eras Tour`
/// - shouting: `THREE HOUSEWIVES AND A BODY` → `Three Housewives and a Body`
///
/// Pure and idempotent. Names that contain none of the trigger characters return immediately.
public enum TitleRefinement {
    public static func refine(_ title: String) -> String {
        guard needsWork(title) else { return title }
        var text = stripMarketingPrefix(title)
        if text.contains("_") { text = replaceUnderscores(text) }
        // Trailing notes stack: "Il Conformista (ITALIAN ENG-SUB) BERNARDO BERTOLUCCI".
        for _ in 0..<4 {
            let before = text
            text = stripTrailingScript(text)
            text = stripTrailingNote(text)
            text = stripTrailingCredits(text)
            text = stripTrailingBrand(text)
            text = tidy(text)
            if text == before { break }
        }
        if text.contains("|") { text = replacePipes(text) }
        text = recaseShouting(text)
        text = tidy(text)
        return text.contains(where: \.isLetter) || !title.contains(where: \.isLetter) ? text : title
    }

    // MARK: Fast path

    /// Shortest marketing prefix in UTF-8 bytes: titles shorter than it can't match, so the
    /// seven anchored range searches below are skipped for nearly every catalog title.
    private static let shortestMarketingPrefix = marketingPrefixes.map(\.utf8.count).min() ?? .max

    private static func needsWork(_ title: String) -> Bool {
        let bytes = title.utf8
        guard let last = bytes.last else { return false }
        if last == UInt8(ascii: ")") || last == UInt8(ascii: "]") { return true }
        var upperRun = 0
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "|"), UInt8(ascii: ","), UInt8(ascii: "_"): return true
            // Lead bytes of U+0600…U+06FF (Arabic and Persian).
            case 0xD8...0xDB: return true
            case UInt8(ascii: "A")...UInt8(ascii: "Z"):
                upperRun += 1
                if upperRun >= 6 { return true }
            case UInt8(ascii: " "), UInt8(ascii: "'"), UInt8(ascii: "."): break
            default: upperRun = 0
            }
        }
        if title.utf8.count >= shortestMarketingPrefix,
           let first = bytes.first, first == UInt8(ascii: "U") || first == UInt8(ascii: "A") || first == UInt8(ascii: "M"),
           marketingPrefixes.contains(where: { title.range(of: $0, options: [.caseInsensitive, .anchored, .diacriticInsensitive]) != nil }) {
            return true
        }
        if let space = title.lastIndex(of: " "), releaseCodes.contains(String(title[title.index(after: space)...])) { return true }
        return title.range(of: "hallmark", options: [.caseInsensitive, .backwards, .anchored]) != nil
    }

    // MARK: Prefixes and punctuation

    private static let marketingPrefixes = [
        "Une présentation spéciale Marvel Television", "Une présentation spéciale de Marvel Television",
        "Une présentation spéciale Marvel Studios", "A Marvel Television Special Presentation",
        "Marvel Television Special Presentation", "Marvel Studios Special Presentation",
        "A Marvel Studios Special Presentation",
    ]

    private static func stripMarketingPrefix(_ text: String) -> String {
        for prefix in marketingPrefixes {
            guard let range = text.range(of: prefix, options: [.caseInsensitive, .anchored, .diacriticInsensitive]) else { continue }
            let rest = text[range.upperBound...].drop { $0 == " " || $0 == ":" || $0 == "-" || $0 == "–" || $0 == "|" }
            return rest.count >= 2 ? String(rest) : text
        }
        return text
    }

    /// File names cannot hold a colon: `Alparslan_ Büyük Selçuklu` is `Alparslan: Büyük Selçuklu`.
    /// `Cry_Wolf` joins two words; `JUNG_E` and `SAC_2045` are spelled that way and stay.
    private static func replaceUnderscores(_ text: String) -> String {
        var result = text.replacingOccurrences(of: " _ ", with: " – ").replacingOccurrences(of: "_ ", with: ": ")
        guard result.contains("_") else { return result }
        let characters = Array(result)
        var output = ""
        output.reserveCapacity(result.utf8.count)
        for (index, character) in characters.enumerated() {
            guard character == "_" else {
                output.append(character)
                continue
            }
            let before = characters[..<index].reversed().prefix { $0.isLetter }
            let after = characters[(index + 1)...].prefix { $0.isLetter }
            let joinsWords = before.count >= 3 && after.count >= 3
                && (before.contains(where: \.isLowercase) || after.contains(where: \.isLowercase))
            output.append(joinsWords ? " " : "_")
        }
        result = output
        return result
    }

    private static func replacePipes(_ text: String) -> String {
        text.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: " – ")
    }

    // MARK: Trailing notes

    /// Words that only ever describe a release: languages, subtitles, dubbing, generation.
    static let noteWords: Set<String> = [
        "SPANISH", "ENGLISH", "FRENCH", "ITALIAN", "GERMAN", "KOREAN", "JAPANESE", "TURKISH", "ARABIC", "HINDI",
        "PORTUGUESE", "BRAZILIAN", "DUTCH", "FLEMISH", "POLISH", "RUSSIAN", "CHINESE", "MANDARIN", "CANTONESE",
        "THAI", "TAMIL", "TELUGU", "SWEDISH", "DANISH", "NORWEGIAN", "FINNISH", "GREEK", "HEBREW", "PERSIAN",
        "PERSIANN", "FARSI", "LATINO", "CASTELLANO", "QUEBEC", "QUEBECOIS", "SVENSKT", "TAL", "NORSK", "DANSK",
        "БГ", "АУДИО", "СУБТИТРИ", "MULTI", "MULTISUB", "SUB", "SUBS", "SUBBED", "SUBTITLED", "SUBTITLES", "SUBSON",
        "DUB", "DUBBED", "DUAL", "AUDIO", "VOSTFR", "VOST", "VOSTA", "VO", "VF", "VFF", "VFQ", "TRUEFRENCH",
        "ENG", "ESP", "ITA", "GER", "FRE", "FR", "EN", "NL", "VERSION", "ORIGINAL", "VERSIÓN", "HALLMARK", "AI",
        "GENERATED", "CORREGIDA", "SVENSK", "TEXT", "NO", "HDTC", "HDTS", "HDCAM",
    ]

    static let releaseCodes: Set<String> = ["VOSTFR", "VSFR", "VOSTA", "TRUEFRENCH", "SUBFRENCH", "MULTISUB", "MULTI-SUB", "VFF", "VFQ", "VFI"]

    private static func noteParts(_ text: Substring) -> [Substring] {
        text.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "," || $0 == "/" || $0 == "+" || $0 == "&" })
    }

    private static func isNote(_ text: Substring) -> Bool {
        let parts = noteParts(text)
        return !parts.isEmpty && parts.allSatisfy { noteWords.contains($0.uppercased()) }
    }

    /// `(2011-2014)`, `(1975–1979)`, `(2014- )`: a series' run, already shown as metadata.
    private static func isYearSpan(_ text: Substring) -> Bool {
        let digits = text.filter(\.isNumber)
        guard digits.count == 4 || digits.count == 8,
              text.allSatisfy({ $0.isNumber || $0 == "-" || $0 == "–" || $0 == " " }),
              text.contains(where: { $0 == "-" || $0 == "–" }) else { return false }
        let first = Int(digits.prefix(4)) ?? 0
        return (1900...2100).contains(first)
    }

    /// `Title (SPANISH MULTI SUB)`, `Title [ENG SUB]`, `Show (2011-2014)` and the bare `Title SPANISH MULTI SUB`.
    private static func stripTrailingNote(_ text: String) -> String {
        if let last = text.last, last == ")" || last == "]" {
            let open: Character = last == ")" ? "(" : "["
            guard let start = text.lastIndex(of: open) else { return text }
            let inner = text[text.index(after: start)..<text.index(before: text.endIndex)]
            let head = text[..<start]
            guard isNote(inner) || isYearSpan(inner), head.contains(where: \.isLetter) else { return text }
            return String(head)
        }
        var tokens = text.split(separator: " ", omittingEmptySubsequences: true)
        // Release codes that are never words: one is enough.
        if tokens.count > 1, let last = tokens.last, releaseCodes.contains(String(last)),
           tokens.dropLast().contains(where: { $0.contains(where: \.isLowercase) }) {
            return tokens.dropLast().joined(separator: " ")
        }
        // Other bare notes must be capitalised and at least two words long.
        var removed = 0
        while tokens.count > 1, let last = tokens.last, last.count >= 2, last == last.uppercased(),
              last.contains(where: \.isLetter), noteParts(last).allSatisfy({ noteWords.contains(String($0)) }) {
            tokens.removeLast()
            removed += 1
        }
        guard removed >= 2, tokens.contains(where: { $0.contains(where: \.isLowercase) }) else { return text }
        return tokens.joined(separator: " ")
    }

    /// Persian and Arabic translations written next to a Latin-script title, at the end or before
    /// a sequel number: `Tulsa King پادشاه تالسا`, `Enola Holmes انولا هولمز 3`.
    private static func stripTrailingScript(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isArabicScript) else { return text }
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true)
        func isForeign(_ token: Substring) -> Bool {
            let letters = token.unicodeScalars.filter { $0.properties.isAlphabetic }
            return !letters.isEmpty && letters.allSatisfy(isArabicScript)
        }
        func isFiller(_ token: Substring) -> Bool { !token.unicodeScalars.contains { $0.properties.isAlphabetic || $0.properties.numericType != nil } }
        guard let first = tokens.firstIndex(where: isForeign), let last = tokens.lastIndex(where: isForeign),
              tokens[first...last].allSatisfy({ isForeign($0) || isFiller($0) }) else { return text }
        let head = tokens[..<first]
        let tail = tokens[(last + 1)...]
        // Only a sequel number or a year may follow the translation.
        guard head.contains(where: { $0.unicodeScalars.contains(where: isLatinLetter) }),
              tail.allSatisfy({ $0.allSatisfy { $0.isNumber || $0 == "(" || $0 == ")" } }) else { return text }
        return (head + tail).joined(separator: " ")
    }

    private static func isArabicScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: true
        default: false
        }
    }

    private static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: true
        default: false
        }
    }

    /// `A Fistful Of Dollars CLINT EASTWOOD, SERGIO LEONE`, `The Runner NICOLAS CAGE`: capitalised
    /// names after a title written in mixed case.
    private static func stripTrailingCredits(_ text: String) -> String {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true)
        var index = tokens.count
        var sawComma = false
        var allNameLike = true
        while index > 0 {
            let token = tokens[index - 1]
            let letters = token.filter(\.isLetter)
            guard letters.count >= 2, letters.allSatisfy(\.isUppercase),
                  token.allSatisfy({ $0.isLetter || $0 == "," || $0 == "." || $0 == "'" || $0 == "’" || $0 == "-" })
            else { break }
            if token.contains(",") { sawComma = true }
            // Names have vowels and some length: acronyms ("FBI", "NYC") and numerals ("II") are titles.
            let hasVowel = letters.contains { "AEIOUYÀÁÂÄÉÈÊËÍÎÏÓÔÖÚÙÛÜ".contains($0) }
            if letters.count < 3 || !hasVowel || NameCasing.keepUpper.contains(String(letters)) { allNameLike = false }
            index -= 1
        }
        let run = tokens.count - index
        let head = tokens[..<index]
        let mixedHead = head.count >= (allNameLike && run == 2 ? 1 : 2) && head.contains(where: { $0.contains(where: \.isLowercase) })
        // "Mission: Impossible – DEAD RECKONING": a subtitle in capitals, not credits.
        guard mixedHead, let previous = head.last?.last, previous != ":", previous != "–", previous != "-" else { return text }
        if sawComma, run >= 3 { return head.joined(separator: " ") }
        if allNameLike, (2...3).contains(run) { return head.joined(separator: " ") }
        return text
    }

    private static func stripTrailingBrand(_ text: String) -> String {
        guard let range = text.range(of: "hallmark", options: [.caseInsensitive, .backwards, .anchored]),
              range.lowerBound > text.startIndex, text[text.index(before: range.lowerBound)] == " " else { return text }
        let head = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        return head.split(separator: " ").count >= 2 ? head : text
    }

    // MARK: Casing

    /// Whole names in capitals read as shouting next to properly cased neighbours. One-word names
    /// stay: they are often stylised on purpose (`FUBAR`, `RIPLEY`, `M3GAN`).
    private static func recaseShouting(_ text: String) -> String {
        guard !text.contains(where: \.isLowercase) else { return text }
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard words.count >= 2, text.filter(\.isLetter).count >= 6,
              text.unicodeScalars.contains(where: isLatinLetter) else { return text }
        return NameCasing.smartTitleCaseIfAllCaps(text)
    }

    private static func tidy(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespaces)
        while let last = result.last, last == "-" || last == "–" || last == ":" || last == "," || last == "|" || last == "/" {
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespaces)
        }
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        return result
    }
}
