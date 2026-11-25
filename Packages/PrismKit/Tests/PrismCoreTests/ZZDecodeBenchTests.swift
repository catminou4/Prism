import Foundation
import Testing
@testable import PrismCore

/// Decode benchmark — measures JSONSerialization vs per-item mapping split.
/// Run: ZZAUDIT=1 swift test --filter ZZDecodeBench
@Suite("ZZ decode bench", .disabled(if: ProcessInfo.processInfo.environment["ZZAUDIT"] == nil))
struct ZZDecodeBenchTests {

    /// Builds a synthetic get_vod_streams payload (~`count` items) resembling a real panel.
    static func vodPayload(count: Int) -> Data {
        var out = Data("[".utf8)
        var first = true
        for i in 0..<count {
            if !first { out.append(0x2C) }
            first = false
            let name = "Film Test \(i) 2024 1080p WEB-DL FR VF+"
            let json = """
            {"num":\(i),"name":"\(name) \(i)","title":"\(name)","cover":"https://img.example.com/p\(i).jpg","stream_icon":"https://img.example.com/p\(i).jpg","backdrop_path":["https://img.example.com/b\(i).jpg"],"movie_image":"","plot":"Un film de test avec une description un peu longue pour approcher les vraies données de panel IPTV, environ 200 caractères.","cast":"Acteur Un, Acteur Deux","director":"Réalisateur","genre":"Action, Drame / Thriller","releaseDate":"2024-05-0\(i % 9 + 1)","rating":"7.\(i % 10)","rating_5based":"3.7","duration_secs":\(5400 + i % 3000),"episode_run_time":"95","container_extension":"mkv","stream_id":\(100000 + i),"stream_type":"movie","category_id":"\(i % 40)","category_ids":[\(i % 40)],"added":"17\(i % 10)-0\(i % 9 + 1)-1\(i % 9)","tmdb":\(i % 500000),"imdb_id":"tt\(i)","is_adult":"0","trailer":"https://youtube.com/watch?v=abc\(i)"}
            """
            out.append(contentsOf: json.utf8)
        }
        out.append(0x5D)
        return Data(out)
    }

    @Test func vodDecodeProfile() throws {
        let count = 30_000
        let data = Self.vodPayload(count: count)
        print("ZZBENCH payload bytes=\(data.count) items=\(count)")

        var t0 = ContinuousClock.now
        let items = try XtreamDecoder.elements(data)
        print("ZZBENCH elements (JSONSerialization): \(String(format: "%.0f", ms(since: t0))) ms")

        // C0: JSONObject construction + one key lookup (the per-item object access floor)
        t0 = ContinuousClock.now
        var sink = 0
        for element in items {
            if let obj = JSONObject(element) { sink += obj.storedValue("stream_id") == nil ? 0 : 1 }
        }
        print("ZZBENCH C0 object+lookup: \(String(format: "%.0f", ms(since: t0))) ms (sink=\(sink))")

        // C1: string fields only
        t0 = ContinuousClock.now
        sink = 0
        for element in items {
            guard let obj = JSONObject(element) else { continue }
            sink += (obj.string("name", "title") ?? "").count
            sink += (obj.string("container_extension") ?? "").count
            sink += (obj.string("plot", "description") ?? "").count
            sink += (obj.string("director") ?? "").count
            sink += obj.string("stream_id", "id")?.count ?? 0
        }
        print("ZZBENCH C1 string-fields: \(String(format: "%.0f", ms(since: t0))) ms (sink=\(sink))")

        // C2: URL fields
        t0 = ContinuousClock.now
        sink = 0
        for element in items {
            guard let obj = JSONObject(element) else { continue }
            sink += (obj.url("stream_icon", "cover", "cover_big") != nil ? 1 : 0)
            sink += obj.urls("backdrop_path").count
            sink += (XtreamDecoder.youtubeURL(obj.string("trailer", "youtube_trailer")) != nil ? 1 : 0)
        }
        print("ZZBENCH C2 url-fields: \(String(format: "%.0f", ms(since: t0))) ms (sink=\(sink))")

        // C3: numeric/date fields
        t0 = ContinuousClock.now
        sink = 0
        for element in items {
            guard let obj = JSONObject(element) else { continue }
            sink += obj.int("duration_secs") ?? 0
            sink += obj.int("duration_secs") ?? 0
            sink += obj.year("year") ?? 0
            sink += obj.year("releaseDate", "releasedate", "release_date") ?? 0
            sink += obj.int("tmdb", "tmdb_id") ?? 0
            sink += obj.date("added")?.timeIntervalSince1970.description.count ?? 0
            sink += obj.double("rating") ?? 0 > 0 ? 1 : 0
        }
        print("ZZBENCH C3 num-date-fields: \(String(format: "%.0f", ms(since: t0))) ms (sink=\(sink))")

        // C4: list/category fields
        t0 = ContinuousClock.now
        sink = 0
        for element in items {
            guard let obj = JSONObject(element) else { continue }
            sink += obj.list("genre", "genres", separators: XtreamDecoder.genreSeparators).count
            sink += obj.list("cast", "actors").count
            sink += XtreamDecoder.categoryNativeID(obj)?.count ?? 0
            sink += (obj.bool("is_adult") == true ? 1 : 0)
        }
        print("ZZBENCH C4 list-cat-fields: \(String(format: "%.0f", ms(since: t0))) ms (sink=\(sink))")

        // E: normalize alone
        t0 = ContinuousClock.now
        sink = 0
        for element in items {
            guard let obj = JSONObject(element) else { continue }
            let n = TitleNormalizer.normalize(obj.string("name", "title") ?? "x")
            sink += n.title.count
        }
        print("ZZBENCH E normalize: \(String(format: "%.0f", ms(since: t0))) ms (sink=\(sink))")

        // F: full decode (sequential decoder entry point), compared with the oracle in-process.
        let credentials = XtreamCredentials(server: URL(string: "http://panel.example.com")!, username: "u", password: "p")
        var bestProduction = Double.infinity
        var movies: [Movie] = []
        for _ in 0..<2 {
            t0 = ContinuousClock.now
            movies = try XtreamDecoder.vodStreams(data, sourceID: SourceID("bench"), credentials: credentials)
            bestProduction = min(bestProduction, ms(since: t0))
        }
        print("ZZBENCH F vodStreams-sequential: \(String(format: "%.0f", bestProduction)) ms → \(movies.count)")

        var bestReference = Double.infinity
        var reference: [Movie] = []
        for _ in 0..<2 {
            t0 = ContinuousClock.now
            reference = try LenientOracle.referenceVODStreams(data, sourceID: "bench", credentials: credentials)
            bestReference = min(bestReference, ms(since: t0))
        }
        print("ZZBENCH F2 oracle-vodStreams: \(String(format: "%.0f", bestReference)) ms → \(reference.count)")
        print("ZZBENCH F saving vs oracle: \(String(format: "%.1f", (bestReference - bestProduction) / bestReference * 100))%")

        #expect(movies.count == count)
        #expect(movies == reference)
    }

    /// Dirty 20k-object payload: measures the LenientJSON object/array access layer against the
    /// pre-optimization oracle in the same process, then the full sequential VOD decode.
    @Test func dirtyBridgingProfile() throws {
        let count = 20_000
        let data = LenientDirtyFixture.payload(count: count)
        let parsed = try LenientValue.parse(data)
        print("ZZBENCH-D dirty payload bytes=\(data.count) items=\(count)")

        var bestProduction = Double.infinity
        var sink = 0
        for _ in 0..<3 {
            let t0 = ContinuousClock.now
            sink = 0
            let productionElements = LenientArray(parsed) ?? .empty
            for element in productionElements {
                guard let obj = JSONObject(element) else { continue }
                sink += Self.productionAccess(obj)
            }
            bestProduction = min(bestProduction, ms(since: t0))
        }
        print("ZZBENCH-D A production-access: \(String(format: "%.1f", bestProduction)) ms → \(String(format: "%.2f", bestProduction * 1000 / Double(count))) µs/item (sink=\(sink))")

        var bestReference = Double.infinity
        for _ in 0..<3 {
            let t0 = ContinuousClock.now
            sink = 0
            let referenceElements = LenientOracle.array(parsed)
            for element in referenceElements {
                guard let obj = LenientReferenceJSONObject(element) else { continue }
                sink += Self.referenceAccess(obj)
            }
            bestReference = min(bestReference, ms(since: t0))
        }
        print("ZZBENCH-D B oracle-access: \(String(format: "%.1f", bestReference)) ms → \(String(format: "%.2f", bestReference * 1000 / Double(count))) µs/item (sink=\(sink))")
        print("ZZBENCH-D access saving: \(String(format: "%.1f", (bestReference - bestProduction) / bestReference * 100))%")

        let credentials = XtreamCredentials(server: URL(string: "http://panel.example.com")!, username: "bench", password: "secret")
        var bestProductionMap = Double.infinity
        var productionMapped: [Movie] = []
        for _ in 0..<3 {
            let t0 = ContinuousClock.now
            let productionElements = LenientArray(parsed) ?? .empty
            productionMapped = XtreamDecoder.vodStreams(productionElements[...], sourceID: "bench", credentials: credentials)
            bestProductionMap = min(bestProductionMap, ms(since: t0))
        }
        print("ZZBENCH-D M1 production-map-only: \(String(format: "%.1f", bestProductionMap)) ms → \(String(format: "%.2f", bestProductionMap * 1000 / Double(count))) µs/item → \(productionMapped.count)")

        var bestReferenceMap = Double.infinity
        var referenceMapped: [Movie] = []
        for _ in 0..<3 {
            let t0 = ContinuousClock.now
            let referenceElements = LenientOracle.array(parsed)
            referenceMapped = LenientOracle.referenceVODStreams(referenceElements, sourceID: "bench", credentials: credentials)
            bestReferenceMap = min(bestReferenceMap, ms(since: t0))
        }
        print("ZZBENCH-D M2 oracle-map-only: \(String(format: "%.1f", bestReferenceMap)) ms → \(String(format: "%.2f", bestReferenceMap * 1000 / Double(count))) µs/item → \(referenceMapped.count)")
        print("ZZBENCH-D map-only saving: \(String(format: "%.1f", (bestReferenceMap - bestProductionMap) / bestReferenceMap * 100))%")
        #expect(productionMapped == referenceMapped)

        var bestProductionFull = Double.infinity
        var production: [Movie] = []
        for _ in 0..<3 {
            let t0 = ContinuousClock.now
            production = try XtreamDecoder.vodStreams(data, sourceID: "bench", credentials: credentials)
            bestProductionFull = min(bestProductionFull, ms(since: t0))
        }
        print("ZZBENCH-D C production-vodStreams: \(String(format: "%.1f", bestProductionFull)) ms → \(String(format: "%.2f", bestProductionFull * 1000 / Double(count))) µs/item → \(production.count)")

        var bestReferenceFull = Double.infinity
        var reference: [Movie] = []
        for _ in 0..<3 {
            let t0 = ContinuousClock.now
            reference = try LenientOracle.referenceVODStreams(data, sourceID: "bench", credentials: credentials)
            bestReferenceFull = min(bestReferenceFull, ms(since: t0))
        }
        print("ZZBENCH-D D oracle-vodStreams: \(String(format: "%.1f", bestReferenceFull)) ms → \(String(format: "%.2f", bestReferenceFull * 1000 / Double(count))) µs/item → \(reference.count)")
        print("ZZBENCH-D full-decode saving: \(String(format: "%.1f", (bestReferenceFull - bestProductionFull) / bestReferenceFull * 100))%")
        #expect(production == reference)
    }

    /// End-to-end through XtreamClient + StubURLProtocol: measures the chunked decodeList path.
    @Test func clientDecodeProfile() async throws {
        let count = 30_000
        let payload = Self.vodPayload(count: count)
        let host = "vodbench.example.com"
        StubURLProtocol.register(host: host, action: "get_vod_streams", body: payload)
        StubURLProtocol.register(host: host, action: "get_vod_categories", body: Data("[]".utf8))
        let credentials = XtreamCredentials(server: URL(string: "http://\(host)")!, username: "u", password: "p")
        let client = XtreamClient(credentials: credentials, sourceID: "bench", session: StubURLProtocol.session())

        let t0 = ContinuousClock.now
        let movies = try await client.vodStreams()
        print("ZZBENCH G client.vodStreams (chunked decodeList): \(String(format: "%.0f", ms(since: t0))) ms → \(movies.count)")
        #expect(movies.count == count)

        // Equivalence: chunked output must equal the sequential decoder output byte-for-byte.
        let reference = try XtreamDecoder.vodStreams(payload, sourceID: SourceID("bench"), credentials: credentials)
        #expect(movies == reference)
    }

    /// Single-parse vs chunked parallel parse on a ~50 MB / 100k-element payload: scan cost,
    /// fragment parse scaling, end-to-end wall time, output equality.
    @Test func parallelParseBenchmark() async throws {
        let count = 100_000
        let data = Self.vodPayload(count: count)
        print("ZZBENCH-P payload bytes=\(data.count) items=\(count)")

        // A: single JSONSerialization parse (the old serial bottleneck).
        var t0 = ContinuousClock.now
        let reference = try XtreamDecoder.elements(data)
        let singleMs = ms(since: t0)
        print("ZZBENCH-P A single-parse: \(String(format: "%.0f", singleMs)) ms → \(reference.count)")

        // B: byte-scan splitter alone (serial, on the critical path).
        let payload = try #require(XtreamDecoder.payloadForParsing(data))
        t0 = ContinuousClock.now
        let split = try #require(TopLevelArraySplitter.split(payload))
        let scanMs = ms(since: t0)
        print("ZZBENCH-P B scan: \(String(format: "%.0f", scanMs)) ms → \(split.elements.count) slots")
        #expect(split.elements.count == count)

        // C: chunked parallel fragment parse (what decodeList does before mapping).
        t0 = ContinuousClock.now
        let workers = min(6, ProcessInfo.processInfo.activeProcessorCount)
        let chunks = TopLevelArraySplitter.chunks(split, workers: workers)
        let payloadData = split.payload
        let parsedChunks: [(Int, Int)] = await withTaskGroup(of: (Int, Int).self) { group in
            for (index, range) in chunks.enumerated() {
                group.addTask {
                    var fragment = Data()
                    fragment.reserveCapacity(range.count + 2)
                    fragment.append(0x5B)
                    fragment.append(payloadData[range])
                    fragment.append(0x5D)
                    let parsed = try? LenientValue.parse(fragment)
                    return (index, LenientArray(parsed)?.count ?? -1)
                }
            }
            var collected: [(Int, Int)] = []
            for await chunk in group { collected.append(chunk) }
            return collected
        }
        let chunkedMs = ms(since: t0)
        let total = parsedChunks.reduce(0) { $0 + $1.1 }
        print("ZZBENCH-P C chunked-parse (\(workers) workers): \(String(format: "%.0f", chunkedMs)) ms → \(total)")
        print("ZZBENCH-P scan+chunked: \(String(format: "%.0f", scanMs + chunkedMs)) ms vs single \(String(format: "%.0f", singleMs)) ms → speedup ×\(String(format: "%.1f", singleMs / max(scanMs + chunkedMs, 0.01)))")
        #expect(total == count)
    }

    private static func productionAccess(_ obj: JSONObject) -> Int {
        var score = 0
        score += obj.string("stream_id", "id")?.count ?? 0
        score += obj.string("name", "title")?.count ?? 0
        score += obj.string("plot", "description")?.count ?? 0
        score += obj.string("container_extension")?.count ?? 0
        score += obj.string("director")?.count ?? 0
        score += obj.url("stream_icon", "cover", "cover_big") != nil ? 1 : 0
        score += obj.urls("backdrop_path").count
        score += obj.list("genre", "genres", separators: XtreamDecoder.genreSeparators).count
        score += obj.list("cast", "actors").count
        score += obj.int("duration_secs") ?? 0
        score += obj.int("tmdb", "tmdb_id") ?? 0
        score += obj.year("year", "releaseDate", "releasedate", "release_date") ?? 0
        score += obj.date("added").map { Int($0.timeIntervalSince1970) } ?? 0
        score += obj.double("rating").map { Int($0 * 100) } ?? 0
        score += obj.bool("is_adult") == true ? 1 : 0
        score += obj.object("nested")?.string("nombre")?.count ?? 0
        score += obj.array("category_ids").count
        score += obj.array("array_value").count
        return score
    }

    private static func referenceAccess(_ obj: LenientReferenceJSONObject) -> Int {
        var score = 0
        score += obj.string("stream_id", "id")?.count ?? 0
        score += obj.string("name", "title")?.count ?? 0
        score += obj.string("plot", "description")?.count ?? 0
        score += obj.string("container_extension")?.count ?? 0
        score += obj.string("director")?.count ?? 0
        score += obj.url("stream_icon", "cover", "cover_big") != nil ? 1 : 0
        score += obj.urls("backdrop_path").count
        score += obj.list("genre", "genres", separators: XtreamDecoder.genreSeparators).count
        score += obj.list("cast", "actors").count
        score += obj.int("duration_secs") ?? 0
        score += obj.int("tmdb", "tmdb_id") ?? 0
        score += obj.year("year", "releaseDate", "releasedate", "release_date") ?? 0
        score += obj.date("added").map { Int($0.timeIntervalSince1970) } ?? 0
        score += obj.double("rating").map { Int($0 * 100) } ?? 0
        score += obj.bool("is_adult") == true ? 1 : 0
        score += obj.object("nested")?.string("nombre")?.count ?? 0
        score += obj.array("category_ids").count
        score += obj.array("array_value").count
        return score
    }

    private func ms(since start: ContinuousClock.Instant) -> Double {
        let e = ContinuousClock.now - start
        return Double(e.components.seconds) * 1000 + Double(e.components.attoseconds) / 1e15
    }
}
