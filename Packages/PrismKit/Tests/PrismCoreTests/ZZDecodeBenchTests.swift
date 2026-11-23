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

        // C0: JSONObject cast only
        t0 = ContinuousClock.now
        var sink = 0
        for element in items {
            if let obj = JSONObject(element) { sink += obj.raw.count }
        }
        print("ZZBENCH C0 cast-only: \(String(format: "%.0f", ms(since: t0))) ms (sink=\(sink))")

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

        // F: full decode (sequential decoder entry point)
        let credentials = XtreamCredentials(server: URL(string: "http://panel.example.com")!, username: "u", password: "p")
        t0 = ContinuousClock.now
        let movies = try XtreamDecoder.vodStreams(data, sourceID: SourceID("bench"), credentials: credentials)
        print("ZZBENCH F vodStreams-sequential: \(String(format: "%.0f", ms(since: t0))) ms → \(movies.count)")

        #expect(movies.count == count)
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

    private func ms(since start: ContinuousClock.Instant) -> Double {
        let e = ContinuousClock.now - start
        return Double(e.components.seconds) * 1000 + Double(e.components.attoseconds) / 1e15
    }
}
