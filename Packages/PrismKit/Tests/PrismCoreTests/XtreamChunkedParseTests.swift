import Foundation
import Testing
import zlib
@testable import PrismCore

/// Deterministic pseudo-random generator for reproducible fuzz tests.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Proper gzip encoding (1F 8B magic) for feed tests — `NSData.compressed(using: .zlib)`
/// emits raw deflate without a header, which panels never do.
func gzipEncode(_ data: Data) -> Data? {
    var stream = z_stream()
    guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
    defer { deflateEnd(&stream) }
    var output = Data()
    let chunk = UnsafeMutablePointer<Bytef>.allocate(capacity: 65_536)
    defer { chunk.deallocate() }
    data.withUnsafeBytes { raw in
        stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
        stream.avail_in = uInt(raw.count)
        repeat {
            stream.next_out = chunk
            stream.avail_out = 65_536
            deflate(&stream, Z_FINISH)
            output.append(chunk, count: 65_536 - Int(stream.avail_out))
        } while stream.avail_out == 0
    }
    return output
}

/// Scanner/splitter correctness: the byte scan must find exact depth-1 element boundaries
/// in dirty-but-valid JSON, and must bail out (nil → single-parse fallback) on anything
/// structurally uncertifiable.
@Suite("TopLevelArraySplitter")
struct TopLevelArraySplitterTests {
    func split(_ string: String) -> TopLevelArraySplitter.Split? {
        TopLevelArraySplitter.split(Data(string.utf8))
    }

    /// Fragment-decodes every element range and returns the parsed values, mirroring what
    /// the chunked decode workers do (wrap bytes in `[`…`]`, JSONSerialization).
    func fragmentElements(_ split: TopLevelArraySplitter.Split) throws -> [Any] {
        var result: [Any] = []
        for range in split.elements {
            var fragment = Data()
            fragment.append(0x5B)
            fragment.append(split.payload[range])
            fragment.append(0x5D)
            let parsed = try LenientValue.parse(fragment)
            let array = try #require(parsed as? [Any])
            #expect(array.count == 1, "each element range must hold exactly one JSON value")
            result.append(array[0])
        }
        return result
    }

    @Test func simpleObjectElements() throws {
        let split = try #require(split(#"[{"a":1},{"b":2},{"c":3}]"#))
        #expect(split.elements.count == 3)
        let elements = try fragmentElements(split)
        #expect((elements[0] as? [String: Any])?["a"] as? Int == 1)
        #expect((elements[2] as? [String: Any])?["c"] as? Int == 3)
    }

    @Test func nestedContainersDoNotSplit() throws {
        let split = try #require(split(#"[{"a":{"x":[1,2,{"y":","}]},"b":[[1],{}]},[3,4],{"z":0}]"#))
        #expect(split.elements.count == 3)
        let elements = try fragmentElements(split)
        #expect((elements[0] as? [String: Any])?["b"] != nil)
        #expect((elements[1] as? [Any])?.count == 2)
    }

    @Test func structuralCharactersInsideStringsAreContent() throws {
        let split = try #require(split(#"[{"a":"x,y"},{"b":"[]{}"},{"c":"a]b{c"},5]"#))
        #expect(split.elements.count == 4)
        let elements = try fragmentElements(split)
        #expect((elements[1] as? [String: Any])?["b"] as? String == "[]{}")
        #expect((elements[2] as? [String: Any])?["c"] as? String == "a]b{c")
    }

    @Test func escapedQuoteDoesNotEndString() throws {
        // {"a":"he said \"hi\", really"} — the inner quotes are escaped, the comma is content.
        let json = #"{"a":"he said \"hi\", really"}"#
        let split = try #require(split("[\(json),\(json)]"))
        #expect(split.elements.count == 2)
        let elements = try fragmentElements(split)
        #expect((elements[0] as? [String: Any])?["a"] as? String == #"he said "hi", really"#)
    }

    @Test func escapedBackslashThenQuoteEndsString() throws {
        // "ab\\" is the string ab\ — the quote after \\ is NOT escaped and terminates it.
        let split = try #require(split(#"[{"a":"ab\\"},7]"#))
        #expect(split.elements.count == 2)
        let elements = try fragmentElements(split)
        #expect((elements[0] as? [String: Any])?["a"] as? String == "ab\\")
        #expect(elements[1] as? Int == 7)
    }

    @Test func unicodeEscapesAndRawUTF8() throws {
        let split = try #require(split("[{\"a\":\"caf\\u00e9 \\u00e0\"},{\"b\":\"héllo wörld ☃ é\"},{\"c\":\"\\u007d\\u005d\"}]"))
        #expect(split.elements.count == 3)
        let elements = try fragmentElements(split)
        #expect((elements[0] as? [String: Any])?["a"] as? String == "café à")
        #expect((elements[1] as? [String: Any])?["b"] as? String == "héllo wörld ☃ é")
        // } and ] as unicode escapes are just characters — no structural meaning anywhere.
        #expect((elements[2] as? [String: Any])?["c"] as? String == "}]")
    }

    @Test func whitespaceVariantsPreserveElements() throws {
        let split = try #require(split("  \n\t[  {\"a\":1}  ,\n\t{\"b\":2}\t,\n null ,\t true \n]  \n\t"))
        #expect(split.elements.count == 4)
        let elements = try fragmentElements(split)
        #expect(elements[2] is NSNull)
        #expect(elements[3] as? Bool == true)
    }

    @Test func scalarElements() throws {
        let split = try #require(split(#"[1,"two",null,false,3.5]"#))
        #expect(split.elements.count == 5)
        let elements = try fragmentElements(split)
        #expect(elements[0] as? Int == 1)
        #expect(elements[1] as? String == "two")
        #expect(elements[2] is NSNull)
        #expect(elements[4] as? Double == 3.5)
    }

    @Test func singleElementArray() throws {
        let split = try #require(split(#"[{"a":1}]"#))
        #expect(split.elements.count == 1)
    }

    @Test func emptyArraysScanAsOneWhitespaceSlot() throws {
        // Structurally clean, so the scan succeeds with a single slot; the slot decodes to
        // zero elements, which the count check downstream flags (fallback). Both arrays are
        // far below the size threshold in practice — this only documents the contract.
        for json in ["[]", "[   \n\t ]"] {
            let split = try #require(split(json))
            #expect(split.elements.count == 1)
            let range = split.elements[0]
            #expect(split.payload[range].allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D })
        }
    }

    @Test func bomPrefixedArray() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(#"[{"a":1},{"b":2}]"#.utf8))
        let split = try #require(TopLevelArraySplitter.split(data))
        #expect(split.elements.count == 2)
    }

    @Test func malformedStructuresReturnNil() {
        let cases = [
            #"[{"a":1}"#,                    // unclosed array
            #"[{"a":1}"#,                    // unclosed object inside
            #"[1,2}"#,                       // mismatched closer
            #"[{"a":1]]"#,                   // extra closer after array end
            #"[1]]"#,                        // closer right after end
            #"[1] trailing"#,                // garbage after the array
            #"[1],[2]"#,                     // second array after the first
            #"{"a":1}"#,                     // object root
            #"null"#,                        // scalar root
            #"false"#,                       // boolean root
            #"42"#,                          // number root
            #"\"hello\""#,                   // string root
            #"<html>502</html>"#,            // not JSON at all
            #"[{"a":"unterminated"#,         // truncated inside a string
            #"[{"a":"escaping\"#,            // truncated escape overshoots
            "",
            "   \n\t  ",
        ]
        for json in cases {
            #expect(split(json) == nil, "must bail to the single-parse fallback: \(json.debugDescription)")
        }
    }

    @Test func emptySlotCasesStillScanStructurally() {
        // Leading/trailing/double commas are malformed JSON but structurally clean for the
        // scanner: the count check in the client is what rejects them. Pinned down here so
        // nobody "fixes" the scanner into accepting them silently.
        for json in ["[1,2,]", "[,1]", "[1,,2]", "[1 , , 2]"] {
            #expect(split(json) != nil, "scanner is structural only: \(json)")
        }
    }

    @Test func chunksAreOrderedCoveringAndBounded() throws {
        var payload = "["
        for i in 0..<100 {
            if i > 0 { payload += "," }
            payload += "{\"id\":\(i),\"pad\":\"\(String(repeating: "x", count: i % 37))\"}"
        }
        payload += "]"
        let split = try #require(split(payload))
        #expect(split.elements.count == 100)
        for workers in [2, 3, 6, 7, 200] {
            let chunks = TopLevelArraySplitter.chunks(split, workers: workers)
            #expect(chunks.count <= workers)
            #expect(chunks.count >= 1)
            // Ordered, contiguous, jointly covering every element exactly once.
            #expect(chunks.first?.lowerBound == split.elements.first?.lowerBound)
            #expect(chunks.last?.upperBound == split.elements.last?.upperBound)
            for pair in zip(chunks, chunks.dropFirst()) {
                #expect(pair.0.upperBound <= pair.1.lowerBound)
            }
            // Every element lies inside exactly one chunk.
            for element in split.elements {
                let containing = chunks.filter { $0.lowerBound <= element.lowerBound && element.upperBound <= $0.upperBound }
                #expect(containing.count == 1)
            }
        }
    }

    /// Deterministic pseudo-random differential test: for every generated array that
    /// JSONSerialization accepts, the scanner must find exactly one slot per element and every
    /// slot must fragment-decode back to the same value; for every input it must never disagree
    /// with a fresh scan of itself (idempotence is trivially guaranteed by determinism, so this
    /// pins the harder invariant: slots == parsed elements on valid input).
    @Test func differentialFuzzAgainstJSONSerialization() throws {
        var checked = 0
        for round in 0..<4_000 {
            var rng = SplitMix64(seed: UInt64(round) &* 7_919 &+ 13)
            var elements: [String] = []
            for _ in 0..<(rng.next() % 6 + 1) { elements.append(Self.randomElement(depth: 0, rng: &rng)) }
            var json = "[" + elements.joined(separator: ",") + "]"
            if rng.next() % 3 == 0 { json = "  " + json + " \n\t" }
            let data = Data(json.utf8)
            guard let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [Any] else {
                // Malformed or unusual input: the scanner may say nil (fallback) or not —
                // either is safe because the count check downstream is what guards validity.
                continue
            }
            checked += 1
            let split = try #require(TopLevelArraySplitter.split(data), "valid array must scan: \(json.prefix(120))")
            #expect(split.elements.count == parsed.count, "slot count must equal element count: \(json.prefix(120))")
        }
        #expect(checked > 3_000, "the generator should mostly produce valid arrays")
    }

    /// Fragment-decoded values must deep-equal the whole-parse values on valid input.
    @Test func fragmentContentMatchesWholeParse() throws {
        var rng = SplitMix64(seed: 99_991)
        for _ in 0..<200 {
            var elements: [String] = []
            for _ in 0..<(rng.next() % 5 + 1) { elements.append(Self.randomElement(depth: 0, rng: &rng)) }
            let json = "[" + elements.joined(separator: ",") + "]"
            let data = Data(json.utf8)
            guard let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [Any] else { continue }
            let split = try #require(TopLevelArraySplitter.split(data))
            var fragmentParsed: [Any] = []
            for range in split.elements {
                var fragment = Data()
                fragment.append(0x5B)
                fragment.append(split.payload[range])
                fragment.append(0x5D)
                let array = try #require(try LenientValue.parse(fragment) as? [Any])
                fragmentParsed.append(contentsOf: array)
            }
            #expect(fragmentParsed.count == parsed.count)
            // NSDictionary/NSArray compare by content with isEqual — deep equality check.
            for (lhs, rhs) in zip(fragmentParsed, parsed) {
                #expect(Self.deepEqual(lhs, rhs), "element mismatch in \(json.prefix(120))")
            }
        }
    }

    static func deepEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        if let l = lhs as? NSObject, let r = rhs as? NSObject { return l.isEqual(r) }
        if lhs is NSNull, rhs is NSNull { return true }
        return false
    }

    static func randomElement(depth: Int, rng: inout SplitMix64) -> String {
        let r = rng.next() % 10
        if depth > 3 || r < 4 {
            switch rng.next() % 6 {
            case 0: return "\(rng.next() % 1000)"
            case 1: return "true"
            case 2: return "null"
            case 3: return "3.14"
            default:
                let pieces = ["a", ",", "{", "}", "[", "]", "\\\"", "\\\\", "é", "\\u00e9", "x,y", "  ", "\\n"]
                var s = "\""
                for _ in 0..<(rng.next() % 8 + 1) { s += pieces[Int(rng.next() % UInt64(pieces.count))] }
                s += "\""
                return s
            }
        } else if r < 7 {
            var items: [String] = []
            for _ in 0..<(rng.next() % 4 + 1) { items.append(randomElement(depth: depth + 1, rng: &rng)) }
            return "[" + items.joined(separator: ",") + "]"
        } else {
            var items: [String] = []
            for _ in 0..<(rng.next() % 4 + 1) {
                items.append("\"k\(rng.next() % 100)\":\(randomElement(depth: depth + 1, rng: &rng))")
            }
            return "{" + items.joined(separator: ",") + "}"
        }
    }

    @Test func chunksNeverSplitAnElementEvenWhenOversized() throws {
        // One element vastly larger than the rest: byte-balancing must not cut through it.
        let big = String(repeating: "y", count: 4096)
        let json = "[{\"a\":1},{\"big\":\"" + big + "\"},{\"c\":3}]"
        let split = try #require(split(json))
        #expect(split.elements.count == 3)
        for workers in [2, 4, 6] {
            for chunk in TopLevelArraySplitter.chunks(split, workers: workers) {
                var fragment = Data()
                fragment.append(0x5B)
                fragment.append(split.payload[chunk])
                fragment.append(0x5D)
                let parsed = try LenientValue.parse(fragment)
                // Every chunk is a valid array of whole elements — never a cut-in-half element.
                #expect(parsed is [Any])
            }
        }
        // And the union of chunk-decoded elements preserves order and content.
        var decoded: [[String: Any]] = []
        for chunk in TopLevelArraySplitter.chunks(split, workers: 2) {
            var fragment = Data()
            fragment.append(0x5B)
            fragment.append(split.payload[chunk])
            fragment.append(0x5D)
            for element in try #require(try LenientValue.parse(fragment) as? [Any]) {
                if let obj = element as? [String: Any] { decoded.append(obj) }
            }
        }
        #expect(decoded.count == 3)
        #expect(decoded[1]["big"] as? String == big)
    }
}

/// End-to-end chunked decode through XtreamClient + StubURLProtocol: byte-for-byte equality
/// with the sequential decoder, order preservation, identical failure behavior.
@Suite("XtreamClient chunked parse")
struct XtreamChunkedParseTests {
    let sourceID: SourceID = "xt1"

    func client(host: String) -> XtreamClient {
        let credentials = XtreamCredentials(server: URL(string: "http://\(host):8080")!, username: "demo", password: "secret")
        return XtreamClient(credentials: credentials, sourceID: sourceID, userAgent: "PrismTests/1.0", session: StubURLProtocol.session())
    }

    func credentials(host: String) -> XtreamCredentials {
        XtreamCredentials(server: URL(string: "http://\(host):8080")!, username: "demo", password: "secret")
    }

    /// Above the 256 KB chunked-parse threshold. Nasty-but-valid content: braces, commas and
    /// quotes inside strings, escapes, unicode, nested arrays — anything that would corrupt
    /// output if the scanner misjudged a boundary.
    static func nastyVodPayload(count: Int) -> Data {
        var payload = Data("[".utf8)
        for i in 0..<count {
            if i > 0 { payload.append(0x2C) }
            // In the JSON text: \\\" is an escaped quote, \\u00e9 a unicode escape — both are
            // string content the scanner must skip correctly; braces/brackets/commas inside
            // strings must not count as structure.
            payload.append(contentsOf: """
            {"stream_id":\(300000 + i),"name":"Film \(i) \\\"quoted\\\" { braces } [brackets] ,comma, é☃ \\u00e9 2024","cover":"https://img.example.com/p\(i).jpg","genre":"Action, Drame","rating":"7.5","container_extension":"mkv","category_id":"\(i % 25)","category_ids":[\(i % 25), 99],"added":"2024-01-15","is_adult":"0","plot":"a]b{c}\\"d\\" ,,, é"}
            """.utf8)
        }
        payload.append(0x5D)
        return payload
    }

    @Test func largeNastyPayloadDecodesIdenticallyToSequential() async throws {
        let count = 6_000 // ~3 MB of nasty content → several parse workers
        let payload = Self.nastyVodPayload(count: count)
        #expect(payload.count > 256 * 1024, "payload must engage the chunked path")
        let host = "nasty.test"
        StubURLProtocol.register(host: host, action: "get_vod_streams", body: payload)
        StubURLProtocol.register(host: host, action: "get_vod_categories", body: Data("[]".utf8))
        let movies = try await client(host: host).vodStreams()
        #expect(movies.count == count)
        #expect(movies.first?.nativeID == "300000")
        #expect(movies.last?.nativeID == "\(300000 + count - 1)")
        let reference = try XtreamDecoder.vodStreams(payload, sourceID: sourceID, credentials: credentials(host: host))
        #expect(movies == reference)
        // Spot-check the nasty content survived exactly.
        #expect(movies[0].rawName.contains("\"quoted\" { braces } [brackets] ,comma, é☃"))
        #expect(movies[0].plot == "a]b{c}\"d\" ,,, é")
    }

    @Test func seriesChunkedDecodeMatchesSequential() async throws {
        var payload = Data("[".utf8)
        let count = 5_000
        for i in 0..<count {
            if i > 0 { payload.append(0x2C) }
            payload.append(contentsOf: """
            {"series_id":\(400000 + i),"name":"Série é\(i) [2024]","cover":"https://img.example.com/s\(i).jpg","category_id":"\(i % 7)","rating":"8.1","last_modified":"1704067200"}
            """.utf8)
        }
        payload.append(0x5D)
        #expect(payload.count > 256 * 1024)
        let host = "series-chunked.test"
        StubURLProtocol.register(host: host, action: "get_series", body: payload)
        StubURLProtocol.register(host: host, action: "get_series_categories", body: Data("[]".utf8))
        let series = try await client(host: host).series()
        #expect(series.count == count)
        let reference = try XtreamDecoder.series(payload, sourceID: sourceID)
        #expect(series == reference)
    }

    @Test func liveChunkedDecodeMatchesSequential() async throws {
        var payload = Data("[".utf8)
        let count = 5_000
        for i in 0..<count {
            if i > 0 { payload.append(0x2C) }
            payload.append(contentsOf: """
            {"stream_id":\(500000 + i),"name":"Chaîne \(i) HD","stream_icon":"https://img.example.com/c\(i).png","category_id":"\(i % 9)","num":\(i + 1),"epg_channel_id":"c\(i).fr","tv_archive":"0"}
            """.utf8)
        }
        payload.append(0x5D)
        #expect(payload.count > 256 * 1024)
        let host = "live-chunked.test"
        StubURLProtocol.register(host: host, action: "get_live_streams", body: payload)
        StubURLProtocol.register(host: host, action: "get_live_categories", body: Data("[]".utf8))
        let channels = try await client(host: host).liveStreams(preferHLS: true, account: nil)
        #expect(channels.count == count)
        let reference = try XtreamDecoder.liveStreams(payload, sourceID: sourceID, credentials: credentials(host: host), preferHLS: true)
        #expect(channels == reference)
    }

    /// Whitespace interleaved at every legal position, still large enough to chunk.
    @Test func whitespaceHeavyLargePayload() async throws {
        var payload = Data("  \n[".utf8)
        let count = 5_000
        for i in 0..<count {
            if i > 0 { payload.append(contentsOf: " \n\t , \t".utf8) }
            payload.append(contentsOf: """

              {  "stream_id" : \(300000 + i) , "name" : "Film \(i)" , "category_id" : "3" }
            """.utf8)
        }
        payload.append(contentsOf: "\n ]  \n".utf8)
        #expect(payload.count > 256 * 1024)
        let host = "ws-heavy.test"
        StubURLProtocol.register(host: host, action: "get_vod_streams", body: payload)
        StubURLProtocol.register(host: host, action: "get_vod_categories", body: Data("[]".utf8))
        let movies = try await client(host: host).vodStreams()
        #expect(movies.count == count)
        let reference = try XtreamDecoder.vodStreams(payload, sourceID: sourceID, credentials: credentials(host: host))
        #expect(movies == reference)
    }

    /// Non-array roots must reproduce the exact single-parse behavior even when large:
    /// keyed-element dictionaries decode through LenientValue.array's numeric key ordering.
    @Test func largeKeyedDictionaryFallsBackIdentically() async throws {
        var payload = Data("{".utf8)
        let count = 5_000
        for i in 0..<count {
            if i > 0 { payload.append(0x2C) }
            payload.append(contentsOf: """
            "\(count - i)":{"stream_id":\(300000 + i),"name":"Film \(i)","category_id":"3"}
            """.utf8)
        }
        payload.append(0x7D)
        #expect(payload.count > 256 * 1024)
        let host = "keyed-large.test"
        StubURLProtocol.register(host: host, action: "get_vod_streams", body: payload)
        StubURLProtocol.register(host: host, action: "get_vod_categories", body: Data("[]".utf8))
        let movies = try await client(host: host).vodStreams()
        let reference = try XtreamDecoder.vodStreams(payload, sourceID: sourceID, credentials: credentials(host: host))
        #expect(movies == reference)
        #expect(!movies.isEmpty)
    }

    /// Large `null` / scalar roots: LenientValue.array yields [], both paths agree.
    @Test func largeScalarRootsDecodeEmpty() async throws {
        for (name, root) in [("null-large", "null"), ("false-large", "false")] {
            var payload = Data(root.utf8)
            payload.append(Data(repeating: 0x20, count: 300 * 1024))
            let host = "\(name).test"
            StubURLProtocol.register(host: host, action: "get_vod_streams", body: payload)
            StubURLProtocol.register(host: host, action: "get_vod_categories", body: Data("[]".utf8))
            let movies = try await client(host: host).vodStreams()
            #expect(movies.isEmpty)
            #expect(try XtreamDecoder.vodStreams(payload, sourceID: sourceID, credentials: credentials(host: host)).isEmpty)
        }
    }

    /// user_info-shaped large error responses keep the auth/decoding error behavior.
    @Test func largeUserInfoResponseKeepsErrorBehavior() async throws {
        let padding = String(repeating: "x", count: 300 * 1024)
        let payload = Data("""
        {"user_info":{"auth":0,"pad":"\(padding)"}}
        """.utf8)
        let host = "userinfo-large.test"
        StubURLProtocol.register(host: host, action: "get_series", body: payload)
        StubURLProtocol.register(host: host, action: "get_series_categories", body: Data("[]".utf8))
        await #expect(throws: XtreamError.unauthorized) { try await client(host: host).series() }
    }

    /// Leading/double commas are rejected by JSONSerialization: both paths must throw.
    /// The empty slots are what the decoded-count check (and fragment parse failures) exist for.
    @Test(arguments: ["double comma", "leading comma"])
    func malformedLargeArrayFailsLikeSequential(_ defect: String) async throws {
        var payload = Data(defect == "leading comma" ? "[,".utf8 : "[".utf8)
        let count = 5_000
        for i in 0..<count {
            if i > 0 { payload.append(0x2C) }
            if defect == "double comma", i == 1500 { payload.append(0x2C) } // empty slot at depth 1
            payload.append(contentsOf: """
            {"stream_id":\(300000 + i),"name":"Film \(i)","category_id":"3"}
            """.utf8)
        }
        payload.append(0x5D)
        #expect(payload.count > 256 * 1024)
        let host = "malformed-\(defect.replacingOccurrences(of: " ", with: "-")).test"
        StubURLProtocol.register(host: host, action: "get_vod_streams", body: payload)
        StubURLProtocol.register(host: host, action: "get_vod_categories", body: Data("[]".utf8))
        await #expect(throws: XtreamError.self) { try await client(host: host).vodStreams() }
        #expect(throws: XtreamError.self) {
            try XtreamDecoder.vodStreams(payload, sourceID: sourceID, credentials: credentials(host: host))
        }
    }

    /// JSONSerialization tolerates trailing commas (`[1,2,]` parses as `[1,2]`). The empty
    /// final slot decodes as zero elements, so the count check falls back to the single parse —
    /// slower, but the output must be exactly what the sequential decoder produces.
    @Test func trailingCommaLargeArrayMatchesSequential() async throws {
        var payload = Data("[".utf8)
        let count = 5_000
        for i in 0..<count {
            if i > 0 { payload.append(0x2C) }
            payload.append(contentsOf: """
            {"stream_id":\(300000 + i),"name":"Film \(i)","category_id":"3"}
            """.utf8)
        }
        payload.append(contentsOf: ",]".utf8)
        #expect(payload.count > 256 * 1024)
        let host = "trailing-comma-large.test"
        StubURLProtocol.register(host: host, action: "get_vod_streams", body: payload)
        StubURLProtocol.register(host: host, action: "get_vod_categories", body: Data("[]".utf8))
        let reference = try XtreamDecoder.vodStreams(payload, sourceID: sourceID, credentials: credentials(host: host))
        #expect(reference.count == count, "trailing commas are tolerated by the platform parser")
        let movies = try await client(host: host).vodStreams()
        #expect(movies == reference)
    }

    /// Truncated / structurally broken large arrays must throw as well.
    @Test func truncatedLargeArrayThrows() async throws {
        var payload = Data("[".utf8)
        for i in 0..<5_000 {
            if i > 0 { payload.append(0x2C) }
            payload.append(contentsOf: """
            {"stream_id":\(300000 + i),"name":"Film \(i)","category_id":"3"}
            """.utf8)
        }
        // No closing bracket at all.
        #expect(payload.count > 256 * 1024)
        let host = "truncated-large.test"
        StubURLProtocol.register(host: host, action: "get_vod_streams", body: payload)
        StubURLProtocol.register(host: host, action: "get_vod_categories", body: Data("[]".utf8))
        await #expect(throws: XtreamError.self) { try await client(host: host).vodStreams() }
    }

    /// Small payloads (below the chunking threshold) still decode correctly — regression net
    /// for the preserved single-parse path.
    @Test func smallPayloadBelowThreshold() async throws {
        var payload = Data("[".utf8)
        for i in 0..<200 {
            if i > 0 { payload.append(0x2C) }
            payload.append(contentsOf: """
            {"stream_id":\(300000 + i),"name":"Film \(i)","category_id":"3"}
            """.utf8)
        }
        payload.append(0x5D)
        #expect(payload.count < 256 * 1024)
        let host = "small-vod.test"
        StubURLProtocol.register(host: host, action: "get_vod_streams", body: payload)
        StubURLProtocol.register(host: host, action: "get_vod_categories", body: Data("[]".utf8))
        let movies = try await client(host: host).vodStreams()
        #expect(movies.count == 200)
        let reference = try XtreamDecoder.vodStreams(payload, sourceID: sourceID, credentials: credentials(host: host))
        #expect(movies == reference)
    }

    /// Large gzipped bodies inflate first, then decode exactly like the plain payload.
    /// (The chunking gate uses wire size, so the padding below is pseudo-random hex —
    /// incompressible enough for the compressed body to clear the 256 KB gate.)
    @Test func largeGzippedPayloadDecodesIdentically() async throws {
        let count = 6_000
        var payload = Data("[".utf8)
        for i in 0..<count {
            if i > 0 { payload.append(0x2C) }
            var pad = ""
            var v = UInt64(i &+ 1) &* 2_654_435_761
            for _ in 0..<6 {
                v = v &* 6_364_136_223_846_793_005 &+ 1
                pad += String(v >> 32, radix: 16)
            }
            payload.append(contentsOf: """
            {"stream_id":\(300000 + i),"name":"Film \(i) 2024","category_id":"\(i % 25)","plot":"\(pad)"}
            """.utf8)
        }
        payload.append(0x5D)
        let plain = payload
        #expect(plain.count > 256 * 1024)
        let compressed = try #require(gzipEncode(plain))
        #expect(Gzip.isCompressed(compressed))
        let host = "gzip-large.test"
        StubURLProtocol.register(host: host, action: "get_vod_streams", body: compressed)
        StubURLProtocol.register(host: host, action: "get_vod_categories", body: Data("[]".utf8))
        let movies = try await client(host: host).vodStreams()
        #expect(movies.count == count)
        let reference = try XtreamDecoder.vodStreams(plain, sourceID: sourceID, credentials: credentials(host: host))
        #expect(movies == reference)
    }

    /// Elements that are not objects are skipped by the mapper but must not break the count
    /// check — interleave scalars in a large array.
    @Test func scalarElementsInterleavedInLargeArray() async throws {
        var payload = Data("[".utf8)
        var objectCount = 0
        let count = 5_000
        for i in 0..<count {
            if i > 0 { payload.append(0x2C) }
            if i % 10 == 5 {
                payload.append(contentsOf: (i % 20 == 5 ? "null" : "\"just a string , with commas\"").utf8)
            } else {
                objectCount += 1
                payload.append(contentsOf: """
                {"stream_id":\(300000 + i),"name":"Film \(i)","category_id":"3"}
                """.utf8)
            }
        }
        payload.append(0x5D)
        #expect(payload.count > 256 * 1024)
        let host = "scalars-interleaved.test"
        StubURLProtocol.register(host: host, action: "get_vod_streams", body: payload)
        StubURLProtocol.register(host: host, action: "get_vod_categories", body: Data("[]".utf8))
        let movies = try await client(host: host).vodStreams()
        let reference = try XtreamDecoder.vodStreams(payload, sourceID: sourceID, credentials: credentials(host: host))
        #expect(movies == reference)
        #expect(movies.count == objectCount)
    }

    /// Interning must not change values: many items sharing few categories still decode with
    /// exactly the right categoryID each.
    @Test func internedCategoryIDsStayCorrect() async throws {
        let count = 5_000
        var payload = Data("[".utf8)
        for i in 0..<count {
            if i > 0 { payload.append(0x2C) }
            payload.append(contentsOf: """
            {"stream_id":\(300000 + i),"name":"Film \(i)","category_id":"\(i % 25)"}
            """.utf8)
        }
        payload.append(0x5D)
        let host = "interning.test"
        StubURLProtocol.register(host: host, action: "get_vod_streams", body: payload)
        StubURLProtocol.register(host: host, action: "get_vod_categories", body: Data("[]".utf8))
        let movies = try await client(host: host).vodStreams()
        #expect(movies.count == count)
        for (index, movie) in movies.enumerated() {
            #expect(movie.categoryID == "xt1:movie:\(index % 25)")
        }
    }
}
