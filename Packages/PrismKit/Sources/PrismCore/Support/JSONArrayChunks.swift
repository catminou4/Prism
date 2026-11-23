import Foundation

/// Parallel parser for top-level JSON arrays — built for the huge Xtream list responses
/// (`get_vod_streams` / `get_live_streams` / `get_series`: 100k+ elements, tens of MB).
///
/// Strategy: one byte-level scan finds the commas separating top-level elements, then
/// `DispatchQueue.concurrentPerform` hands each byte range to `JSONSerialization` — the
/// *same* parser as the sequential path, wrapped in `[…]` so every slice is an ordinary
/// array. Values are therefore bit-identical to whole-document parsing.
///
/// Correctness contract: `parse` returns `nil` on ANY structural doubt or slice failure,
/// and the caller falls back to `JSONSerialization` on the whole payload — which reproduces
/// the original error and leniency semantics exactly. A slice can only fail when the whole
/// document would fail too (JSON values carry no cross-element state), so the fast path can
/// never accept input the sequential path rejects, nor produce different values.
enum JSONArrayChunks {
    /// Below this payload size the scan + slice copies cost more than the parallel win.
    static let minPayloadBytes = 320 * 1024
    /// Rough target bytes per slice; combined with the worker floor this bounds slice count.
    static let sliceTargetBytes = 2 * 1024 * 1024
    /// Hard cap on slices (and therefore on `JSONSerialization` calls).
    static let maxSlices = 64
    /// Hard cap on concurrent parses — the lists decode while other work may run too.
    static let maxWorkers = 8

    /// Structural layout of a top-level JSON array, found by the byte scan.
    struct Layout {
        /// Index of the opening `[`.
        let openPos: Int
        /// Index of the matching `]`.
        let closePos: Int
        /// Positions of the depth-1 `,` separators (empty for `[…]` with ≤1 element).
        let commas: [Int]
        /// True for `[]` / `[<whitespace>]`.
        let isEmpty: Bool
    }

    /// Byte-level scan locating a clean top-level `[…]` array: the opening bracket, every
    /// depth-1 comma, and the matching close. Returns nil for any other shape (objects,
    /// fragments, unbalanced brackets, trailing garbage) so the caller can fall back.
    /// `bytes` must already be BOM-stripped (see `parse`).
    ///
    /// Strings are skipped wholesale with `memchr` (a `"` inside a string is a delimiter
    /// only when preceded by an even run of `\`), which is ~10× faster than a per-byte
    /// loop over the string-heavy payload; structural bytes outside strings stay scalar.
    static func scan(_ bytes: Data) -> Layout? {
        bytes.withUnsafeBytes { raw -> Layout? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let count = raw.count
            let rawBase = UnsafeRawPointer(base)

            var i = 0
            while i < count, isJSONSpace(base[i]) { i += 1 }
            guard i < count, base[i] == 0x5B else { return nil } // '['
            let openPos = i
            i += 1

            var commas: [Int] = []
            commas.reserveCapacity(4096)
            var depth = 1
            var closePos = -1
            scan: while i < count {
                switch base[i] {
                case 0x22: // '"' — skip the entire string literal
                    var q = i + 1
                    var closed = false
                    stringLoop: while q < count {
                        guard let found = memchr(rawBase.advanced(by: q), 0x22, count - q) else {
                            return nil // unterminated string → malformed → fallback
                        }
                        let candidate = found.assumingMemoryBound(to: UInt8.self)
                        let quoteIndex = base.distance(to: candidate)
                        // A '"' closes the string only when preceded by an EVEN number of
                        // consecutive backslashes (0, 2, 4…): odd runs mean it is escaped.
                        var backslashes = 0
                        var k = quoteIndex
                        while k > i + 1, base[k - 1] == 0x5C { backslashes += 1; k -= 1 }
                        if backslashes % 2 == 0 {
                            i = quoteIndex + 1
                            closed = true
                            break stringLoop
                        }
                        q = quoteIndex + 1
                    }
                    // Bytes ran out inside the string (e.g. trailing escaped quote) →
                    // malformed; the sequential path reports the error.
                    guard closed else { return nil }
                case 0x7B, 0x5B: // '{' '['
                    depth += 1
                    i += 1
                case 0x7D, 0x5D: // '}' ']'
                    depth -= 1
                    if depth == 0 {
                        // Only ']' may close the top-level array; '}' is malformed
                        // and falls back so the sequential path reports the error.
                        guard base[i] == 0x5D else { return nil }
                        closePos = i
                        break scan
                    }
                    i += 1
                case 0x2C where depth == 1: // ','
                    // Symmetric empty-element guards: a comma directly after the opening
                    // '[' (ignoring whitespace) means an empty FIRST element — its slice
                    // would parse as `[]` and silently drop it, diverging from the
                    // sequential path. Same for the trailing case checked below.
                    var back = i - 1
                    while back > openPos, isJSONSpace(base[back]) { back -= 1 }
                    guard base[back] != 0x5B else { return nil }
                    commas.append(i)
                    // A depth-1 comma followed by ',' or ']' is a malformed empty
                    // element: bail so the sequential path reports the same error —
                    // a lone trailing empty element could otherwise slice to `[]`.
                    var k = i + 1
                    while k < count, isJSONSpace(base[k]) { k += 1 }
                    guard k < count, base[k] != 0x2C, base[k] != 0x5D else { return nil }
                    i += 1
                default:
                    i += 1
                }
            }
            guard closePos >= 0 else { return nil }

            // Only whitespace may follow the closing bracket.
            var j = closePos + 1
            while j < count {
                guard isJSONSpace(base[j]) else { return nil }
                j += 1
            }

            // `[]` / `[   ]` — no elements at all.
            if commas.isEmpty {
                var k = openPos + 1
                var onlySpace = true
                while k < closePos {
                    if !isJSONSpace(base[k]) { onlySpace = false; break }
                    k += 1
                }
                return Layout(openPos: openPos, closePos: closePos, commas: [], isEmpty: onlySpace)
            }
            return Layout(openPos: openPos, closePos: closePos, commas: commas, isEmpty: false)
        }
    }

    /// Parses `payload` (already BOM/gzip-normalized like `LenientValue.parse` input) as a
    /// top-level JSON array. Returns nil unless the payload is a clean `[…]` document and
    /// every slice parses successfully.
    static func parse(_ payload: Data) -> [Any]? {
        var bytes = payload
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        guard bytes.count >= minPayloadBytes, let layout = scan(bytes) else { return nil }
        if layout.isEmpty { return [] }

        // Element boundaries: bounds[k] is the separator (',' or bracket) just before
        // element k; bounds[numElements] is the closing ']'. Element k's raw bytes are
        // (bounds[k] + 1 ..< bounds[k + 1]).
        let numElements = layout.commas.count + 1
        guard numElements >= 2 else { return nil } // single element: nothing to parallelize
        var bounds = [Int]()
        bounds.reserveCapacity(numElements + 1)
        bounds.append(layout.openPos)
        bounds.append(contentsOf: layout.commas)
        bounds.append(layout.closePos)

        // --- Partition elements into byte-balanced slices.
        let span = layout.closePos - layout.openPos - 1
        let workers = min(maxWorkers, ProcessInfo.processInfo.activeProcessorCount)
        let bySize = max(1, (span + sliceTargetBytes - 1) / sliceTargetBytes)
        let sliceCount = min(maxSlices, max(bySize, workers), numElements)
        guard sliceCount > 1 else { return nil }

        var ranges: [(Int, Int)] = [] // element-index ranges [start, end)
        ranges.reserveCapacity(sliceCount)
        var start = 0
        for s in 0..<sliceCount {
            let remainingSlices = sliceCount - s
            let remainingElements = numElements - start
            guard remainingElements > 0 else { break }
            if remainingSlices == 1 {
                ranges.append((start, numElements))
                break
            }
            let remainingBytes = layout.closePos - (bounds[start] + 1)
            let targetBytes = remainingBytes / remainingSlices
            var end = start + 1
            while end < numElements, bounds[end] - bounds[start] <= targetBytes {
                end += 1
            }
            ranges.append((start, end))
            start = end
        }
        guard !ranges.isEmpty else { return nil }

        // --- Parse slices concurrently. Each slice is `[` + raw bytes + `]`, i.e. an
        // ordinary JSON array for JSONSerialization; concatenating preserves order.
        return bytes.withUnsafeBytes { raw -> [Any]? in
            let boxes = ranges.map { _ in SliceResult() }
            let buffer = UnsafeBuffer(raw)
            let sliceRanges = ranges
            let sliceBounds = bounds
            DispatchQueue.concurrentPerform(iterations: sliceRanges.count) { slice in
                let (first, last) = sliceRanges[slice]
                let byteStart = sliceBounds[first] + 1
                let byteEnd = sliceBounds[last]
                let length = byteEnd - byteStart
                var chunk = Data(count: length + 2)
                var parsed: [Any]?
                chunk.withUnsafeMutableBytes { dst in
                    guard let dstBase = dst.baseAddress else { return }
                    dstBase.storeBytes(of: 0x5B, toByteOffset: 0, as: UInt8.self)
                    if length > 0, let srcBase = buffer.base {
                        memcpy(dstBase.advanced(by: 1), srcBase.advanced(by: byteStart), length)
                    }
                    dstBase.storeBytes(of: 0x5D, toByteOffset: length + 1, as: UInt8.self)
                }
                if let object = try? JSONSerialization.jsonObject(with: chunk),
                   let elements = object as? [Any] {
                    parsed = elements
                }
                boxes[slice].finish(elements: parsed)
            }

            var result: [Any] = []
            result.reserveCapacity(numElements)
            for box in boxes {
                guard let elements = box.elements else { return nil }
                result.append(contentsOf: elements)
            }
            return result
        }
    }

    private static func isJSONSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// Sendable box around the payload's raw bytes so `concurrentPerform` closures can copy
    /// slice ranges without re-deriving pointers. The backing `Data` outlives the call.
    private struct UnsafeBuffer: @unchecked Sendable {
        let base: UnsafePointer<UInt8>?
        init(_ raw: UnsafeRawBufferPointer) {
            base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
        }
    }

    /// Per-slice outcome; each worker writes only its own slot, read after the join.
    private final class SliceResult: @unchecked Sendable {
        private(set) var elements: [Any]?
        func finish(elements: [Any]?) { self.elements = elements }
    }
}
