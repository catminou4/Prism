import Foundation
import PrismCore

/// Fast, allocation-light case/diacritic folding used by the search index and a few heuristics.
enum TextFolding {
    /// Lowercased, diacritic-free form of `text` ("Amélie" → "amelie", "Œuvre" → "oeuvre").
    /// ASCII strings take a byte-level fast path; everything else goes through Foundation folding.
    static func fold(_ text: String) -> String {
        var isASCII = true
        var hasUpper = false
        for byte in text.utf8 {
            if byte >= 0x80 { isASCII = false; break }
            if byte >= 0x41 && byte <= 0x5A { hasUpper = true }
        }
        if isASCII {
            guard hasUpper else { return text }
            return String(decoding: text.utf8.map { ($0 >= 0x41 && $0 <= 0x5A) ? $0 &+ 0x20 : $0 }, as: UTF8.self)
        }
        var folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        if folded.contains(where: { equivalents[$0] != nil }) {
            folded = String(folded.flatMap { equivalents[$0] ?? String($0) })
        }
        return folded.lowercased()
    }

    private static let equivalents: [Character: String] = [
        "œ": "oe", "Œ": "oe", "æ": "ae", "Æ": "ae", "ß": "ss", "ø": "o", "Ø": "o", "ł": "l", "Ł": "l", "đ": "d", "Đ": "d",
        "’": "'", "‘": "'", "ʼ": "'", "‐": "-", "‑": "-", "‒": "-", "–": "-", "—": "-", "−": "-", "…": "...",
    ]

    /// Splits folded text into words: letters, combining marks and numbers in any script are
    /// word characters; punctuation and symbols (guillemets, CJK punctuation, emoji) are not.
    static func words(ofFolded folded: String) -> [[UInt8]] {
        var result: [[UInt8]] = []
        var current: [UInt8] = []
        current.reserveCapacity(16)
        for scalar in folded.unicodeScalars {
            if isWordScalar(scalar) {
                current.append(contentsOf: scalar.utf8)
            } else if !current.isEmpty {
                result.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Visits normalized words using a caller-owned buffer. ASCII names are split and lowercased
    /// together, without allocating a folded String or an array of words for each name.
    /// Non-ASCII names go through scalar classification so punctuation never glues to words.
    static func forEachWord(in text: String, buffer: inout [UInt8], _ visit: ([UInt8]) -> Void) {
        let bytes = text.utf8
        if bytes.allSatisfy({ $0 < 0x80 }) {
            for byte in bytes {
                if isWordByte(byte) {
                    buffer.append((0x41...0x5A).contains(byte) ? byte &+ 0x20 : byte)
                } else if !buffer.isEmpty {
                    visit(buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
        } else {
            // `fold` already lowercases; only word scalars are appended, as UTF-8.
            for scalar in fold(text).unicodeScalars {
                if isWordScalar(scalar) {
                    buffer.append(contentsOf: scalar.utf8)
                } else if !buffer.isEmpty {
                    visit(buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
        }
        if !buffer.isEmpty {
            visit(buffer)
            buffer.removeAll(keepingCapacity: true)
        }
    }

    /// Letters (all cases), combining marks and numbers count as word characters; punctuation,
    /// symbols and separators do not. UTF-8 bytes alone cannot tell them apart, so non-ASCII
    /// text is classified one scalar at a time.
    @inline(__always)
    static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    @inline(__always)
    static func isWordByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x41 && byte <= 0x5A) || byte >= 0x80
    }

    /// Heuristic used to pick the display title among variants: natural casing (not ALL CAPS) and
    /// diacritics are preferred ("Amélie" over "AMELIE").
    static func naturalnessScore(_ text: String) -> Int {
        var hasLower = false
        var hasUpper = false
        var hasNonASCIILetter = false
        for scalar in text.unicodeScalars {
            let props = scalar.properties
            if props.isLowercase { hasLower = true } else if props.isUppercase { hasUpper = true }
            if scalar.value >= 0x80 && props.isAlphabetic { hasNonASCIILetter = true }
        }
        var score = 0
        if hasLower { score += 2 }
        if hasLower && hasUpper { score += 1 }
        if hasNonASCIILetter { score += 1 }
        return score
    }
}

/// Filesystem-safe name for a source identifier.
enum SafeFileName {
    static func make(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        var name = String(raw.map { allowed.contains($0) ? $0 : "_" })
        if name.isEmpty || name.hasPrefix(".") { name = "_" + name }
        if name != raw || name.count > 100 {
            // Keep distinct raw IDs distinct after sanitizing / truncating.
            name = String(name.prefix(100)) + "-" + String(stableHash(raw), radix: 36)
        }
        return name
    }

    /// FNV-1a 64-bit, stable across launches (unlike `Hasher`).
    static func stableHash(_ text: String) -> UInt64 {
        StableHash.fnv1a64(text)
    }
}
