import Foundation
import Testing
@testable import PrismCore

/// `JSONArrayChunks` must produce values bit-identical to whole-document
/// `JSONSerialization` — and must never accept input the sequential path rejects.
@Suite("JSONArrayChunks")
struct JSONArrayChunksTests {

    /// ~500 KB payload: enough slices to exercise the parallel path, with dirty
    /// IPTV-ish values (numbers as strings, nulls, nested objects, escapes,
    /// unicode, brackets inside strings).
    private static func bigPayload(elementCount: Int = 24, trailingComma: Bool = false,
                                   doubleComma: Bool = false) -> Data {
        var out = "[".data(using: .utf8)!
        for index in 0..<elementCount {
            if index > 0 { out.append(",".data(using: .utf8)!) }
            if doubleComma, index == elementCount / 2 { out.append(",".data(using: .utf8)!) }
            // \\\" in the literal emits \" in the JSON text — an escaped quote
            // inside the string value, plus raw [brackets] and non-ASCII scalars.
            let filler = String(repeating: "plot with [brackets] and \\\"quotes\\\" éèê ", count: 340)
            let element = """
            {"num":\(index),"name":"Film \(index) [test]","title":"Titre \(index)","rating":"7.\(index % 10)","year":null,"genres":["Action","Drame"],"plot":"\(filler)","stream_id":"\(1000 + index)","container_extension":"mkv","custom":"a\\\\b\\\"c"}
            """
            out.append(element.data(using: .utf8)!)
        }
        if trailingComma { out.append(",".data(using: .utf8)!) }
        out.append("]".data(using: .utf8)!)
        return out
    }

    private static func wholeDocumentElements(_ payload: Data) throws -> [Any] {
        let object = try JSONSerialization.jsonObject(with: payload)
        return try #require(object as? [Any])
    }

    @Test func chunkedParseIsBitIdenticalToWholeDocument() throws {
        let payload = Self.bigPayload()
        #expect(payload.count > JSONArrayChunks.minPayloadBytes)
        let chunked = try #require(JSONArrayChunks.parse(payload))
        let whole = try Self.wholeDocumentElements(payload)
        #expect(chunked.count == whole.count)
        #expect((chunked as NSArray).isEqual(to: whole as NSArray))
    }

    @Test func trailingCommaFallsBackToSequentialLeniency() throws {
        // Foundation's JSONSerialization accepts a trailing comma; the chunked
        // path must decline so `elements` reproduces that lenient result exactly.
        let payload = Self.bigPayload(trailingComma: true)
        #expect(JSONArrayChunks.parse(payload) == nil)
        let elements = try XtreamDecoder.elements(payload)
        let whole = try Self.wholeDocumentElements(payload)
        #expect(elements.count == whole.count)
        #expect((elements as NSArray).isEqual(to: whole as NSArray))
    }

    @Test func emptyMiddleElementIsRejectedLikeSequential() throws {
        // `,,` is not a value: both paths must fail identically.
        let payload = Self.bigPayload(doubleComma: true)
        #expect(JSONArrayChunks.parse(payload) == nil)
        #expect(throws: (any Error).self) { try XtreamDecoder.elements(payload) }
        #expect(throws: (any Error).self) { try JSONSerialization.jsonObject(with: payload) }
    }

    @Test func leadingCommaFallsBackToSequentialError() throws {
        // `[,elem…]` has an empty FIRST element: its slice would parse as `[]` and be
        // silently dropped, diverging from the sequential path which must error.
        // Payload needs ≥ minPayloadBytes for the chunked path to engage.
        var payload = "[ ,".data(using: .utf8)!
        payload.append(Self.bigPayload().dropFirst().dropLast())
        #expect(payload.count > JSONArrayChunks.minPayloadBytes)
        #expect(JSONArrayChunks.parse(payload) == nil)
        #expect(throws: (any Error).self) { try XtreamDecoder.elements(payload) }
    }

    @Test func smallPayloadsFallThroughToSequential() {
        let payload = #"[{"a":1},{"b":2}]"#.data(using: .utf8)!
        #expect(JSONArrayChunks.parse(payload) == nil)
    }
}
