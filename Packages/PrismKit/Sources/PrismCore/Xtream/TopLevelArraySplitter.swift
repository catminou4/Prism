import Foundation

/// Structural byte-scan splitter for large top-level JSON arrays (`get_vod_streams` & co.).
///
/// `JSONSerialization` parses a 50 MB array on a single core; the scan here finds the
/// byte ranges of every depth-1 element in one O(bytes) pass so the array can be decoded
/// as independent fragments in parallel. The scanner never validates content — it only
/// recognizes structure: strings (with `\` escapes), matched `{`/`[`/`]`/`}` pairs, and
/// commas at depth 1. Anything unusual (not an array, unbalanced or mismatched brackets,
/// trailing garbage) returns `nil` and the caller falls back to the exact single-parse path.
///
/// Correctness notes:
/// - Inside a string only `"` (end) and `\` (escape, skips one byte) matter; `{}`/`[]`/`,`
///   inside strings are content. `\uXXXX` needs no special handling: after `\` skips `u`,
///   the hex digits are ordinary content bytes.
/// - A depth-1 comma count of N implies N+1 element slots. Empty slots (`[1,,2]`, `[1,]`)
///   are malformed JSON; they are NOT rejected here but detected by the caller, because the
///   fragments then decode fewer elements than slots. Valid arrays always decode exactly
///   one element per slot, so a count mismatch is a perfect malformed-input detector.
enum TopLevelArraySplitter {
    struct Split {
        /// Zero-based contiguous bytes the element ranges index into. Usually the input
        /// itself (value type, shared storage); a copy only when the input was a slice.
        let payload: Data
        /// Byte range of each element, excluding the separating commas. Leading/trailing
        /// whitespace of an element stays inside its range (legal JSON whitespace).
        let elements: [Range<Int>]
    }

    private static let space: UInt8 = 0x20, tab: UInt8 = 0x09, lf: UInt8 = 0x0A, cr: UInt8 = 0x0D
    private static let quote: UInt8 = 0x22, backslash: UInt8 = 0x5C
    private static let openBrace: UInt8 = 0x7B, closeBrace: UInt8 = 0x7D
    private static let openBracket: UInt8 = 0x5B, closeBracket: UInt8 = 0x5D
    private static let comma: UInt8 = 0x2C

    /// Scans `payload` and returns the per-element byte ranges when it is a structurally
    /// clean top-level array: optional BOM, whitespace, `[`, balanced matched brackets,
    /// whitespace only after the closing `]`. Returns `nil` otherwise (caller falls back).
    static func split(_ payload: Data) -> Split? {
        // Element ranges must be plain zero-based offsets so fragments can be copied with
        // plain integer math. Data slices share indices with their parent, so rebase those
        // (only reachable through the whitespace-then-BOM preprocessing path — vanishingly rare).
        let zeroBased = payload.startIndex == 0 ? payload : Data(payload)
        guard let scan = zeroBased.withUnsafeBytes(scanStructure) else { return nil }
        var elements: [Range<Int>] = []
        elements.reserveCapacity(scan.commas.count + 1)
        var start = scan.contentStart
        for position in scan.commas {
            elements.append(start..<position)
            start = position + 1
        }
        elements.append(start..<scan.arrayEnd)
        return Split(payload: zeroBased, elements: elements)
    }

    /// Groups contiguous elements into at most `workers` byte-balanced chunk ranges. Each
    /// chunk spans whole elements from the start of its first element to the end of its
    /// last; the bytes in between include the interior separating commas, so wrapping a
    /// chunk in `[`…`]` yields a valid JSON array fragment iff the source array is valid.
    static func chunks(_ split: Split, workers: Int) -> [Range<Int>] {
        let elements = split.elements
        guard let first = elements.first, let last = elements.last, workers > 1 else {
            return elements.isEmpty ? [] : [elements[0].lowerBound..<elements[elements.count - 1].upperBound]
        }
        let span = last.upperBound - first.lowerBound
        let target = max((span + workers - 1) / workers, 1)
        var result: [Range<Int>] = []
        var chunkStart = first.lowerBound
        var index = 0
        while index < elements.count {
            // Close the chunk once it reaches the target size — but never before including
            // at least one element, so a single oversized element still makes progress.
            if elements[index].lowerBound - chunkStart >= target, result.count < workers - 1 {
                result.append(chunkStart..<elements[index - 1].upperBound)
                chunkStart = elements[index].lowerBound
            }
            index += 1
        }
        result.append(chunkStart..<last.upperBound)
        return result
    }

    /// The structural scan itself. Returns the positions of every depth-1 comma, the index
    /// just past the opening `[`, and the index of the closing `]` — or `nil` when the
    /// payload is not a cleanly terminated top-level array.
    ///
    /// String content dominates these payloads, so inside strings the scan hops with libc
    /// `memchr` (vectorized, multi-GB/s) instead of classifying every byte: the next `"` is
    /// the string end unless escaped, and escapedness is the parity of the backslash run
    /// immediately before it (`\\` pairs cancel). The run can never cross the opening quote
    /// — it is not a backslash — so backward counting needs no lower bound beyond zero.
    private static func scanStructure(_ bytes: UnsafeRawBufferPointer) -> (commas: [Int], contentStart: Int, arrayEnd: Int)? {
        guard let base = bytes.baseAddress else { return nil }
        let count = bytes.count
        var index = 0
        // UTF-8 BOM (LenientValue.parse strips it too) then JSON whitespace.
        if count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { index = 3 }
        while index < count, isWhitespace(bytes[index]) { index += 1 }
        guard index < count, bytes[index] == openBracket else { return nil }
        let contentStart = index + 1
        index += 1

        var commas: [Int] = []
        // Opener stack: byte is `{` or `[`. Depth 1 = only the outer array bracket.
        var stack: [UInt8] = [openBracket]
        var inString = false
        var arrayEnd = -1

        scan: while index < count {
            let byte = bytes[index]
            if inString {
                if byte == quote {
                    inString = false
                    index += 1
                    continue
                }
                if byte == backslash {
                    // The escaped byte cannot end the string whatever it is. A trailing
                    // lone backslash overshoots the loop → arrayEnd unset → nil. Correct.
                    index += 2
                    continue
                }
                // Ordinary content: hop to the next quote candidate at memchr speed.
                guard let found = memchr(base + index, Int32(quote), count - index) else {
                    return nil // unterminated string → malformed input
                }
                let quoteIndex = UnsafeRawPointer(found) - base
                var backslashes = 0
                var probe = quoteIndex - 1
                // The run can extend before the memchr start (e.g. an escaped byte that was
                // itself a backslash); only a non-backslash stops it — the opening quote
                // qualifies, so zero is the only bound needed.
                while probe >= 0, bytes[probe] == backslash {
                    backslashes += 1
                    probe -= 1
                }
                if backslashes % 2 == 0 { inString = false }
                index = quoteIndex + 1
                continue
            }
            switch byte {
            case quote:
                inString = true
                index += 1
            case openBrace, openBracket:
                stack.append(byte)
                index += 1
            case closeBrace:
                guard stack.last == openBrace else { return nil }
                stack.removeLast()
                index += 1
            case closeBracket:
                guard stack.last == openBracket else { return nil }
                stack.removeLast()
                if stack.isEmpty {
                    arrayEnd = index
                    break scan
                }
                index += 1
            case comma:
                if stack.count == 1 { commas.append(index) }
                index += 1
            default:
                index += 1
            }
        }

        guard arrayEnd >= 0 else { return nil }
        var trailing = arrayEnd + 1
        while trailing < count {
            guard isWhitespace(bytes[trailing]) else { return nil }
            trailing += 1
        }
        return (commas, contentStart, arrayEnd)
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == space || byte == tab || byte == lf || byte == cr
    }
}
