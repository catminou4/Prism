import Foundation
import Testing
@testable import PrismCore

@Suite("M3UCatalogMapper")
struct M3UCatalogMapperTests {
    let sourceID: SourceID = "src1"

    func catalog(_ name: String) throws -> SourceCatalog {
        let playlist = M3UParser.parse(try Fixture.data(name, "m3u"))
        return M3UCatalogMapper.makeCatalog(from: playlist, sourceID: sourceID, now: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func classifiesStandardPlaylist() throws {
        let catalog = try catalog("standard")
        #expect(catalog.channels.map(\.name) == ["TF1", "France 2", "M6", "BBC One", "Hot Channel"])
        #expect(catalog.movies.map(\.title) == ["Avatar", "Inception"])
        #expect(catalog.series.map(\.title) == ["The Bear"])
        #expect(catalog.fetchedAt == Date(timeIntervalSince1970: 1_700_000_000))

        let tf1 = catalog.channels[0]
        #expect(tf1.number == 1)
        #expect(tf1.epgID == "tf1.fr")
        #expect(tf1.logoURL?.absoluteString == "http://logos.example.com/tf1.png")
        #expect(tf1.quality == .hd)
        #expect(tf1.tags == ["FR"])
        #expect(tf1.rawName == "FR: TF1 HD")
        #expect(tf1.id.kind == .live)
        #expect(catalog.channels[1].quality == .fhd)

        let m6 = catalog.channels[2]
        #expect(m6.number == 6)
        #expect(m6.catchup == Catchup(mode: .default, days: 7, template: "?utc={utc}&lutc={lutc}"))

        let hot = catalog.channels[4]
        #expect(hot.isAdult)
        #expect(hot.epgID == nil)
        #expect(hot.logoURL == nil)

        let avatar = catalog.movies[0]
        #expect(avatar.year == 2009)
        #expect(avatar.quality == .uhd)
        #expect(avatar.tags.contains("MULTI"))
        #expect(avatar.containerExtension == "mkv")
        #expect(avatar.posterURL?.absoluteString == "http://img.example.com/avatar.jpg")
        #expect(catalog.movies[1].durationSeconds == 7620)
        #expect(catalog.movies[1].tags == ["VF"])
    }

    @Test func groupsSeriesIntoSeasons() throws {
        let catalog = try catalog("standard")
        let bear = try #require(catalog.series.first)
        let seasons = try #require(bear.seasons)
        #expect(seasons.map(\.number) == [1, 2])
        #expect(seasons[0].episodes.map(\.number) == [1, 2])
        #expect(seasons[1].episodes.map(\.number) == [1])
        #expect(seasons[0].episodes[0].title == "Épisode 1")
        #expect(seasons[0].episodes[0].seriesID == bear.id)
        #expect(seasons[0].episodes[0].containerExtension == "mkv")
        #expect(bear.posterURL?.absoluteString == "http://img.example.com/bear.jpg")
        #expect(bear.tags == ["VOSTFR"])
        #expect(seasons[0].episodes[1].stillURL?.absoluteString == "http://img.example.com/bear2.jpg")
    }

    @Test func versionsInOneSeriesCategoryStayPlayableIndependently() throws {
        let playlist = M3UParser.parse("""
            #EXTM3U
            #EXTINF:-1 group-title="Séries",The Bear (2022) S01E01 VF
            https://example.com/series/bear-fr-1.mkv
            #EXTINF:-1 group-title="Séries",The Bear S01E02 VF
            https://example.com/series/bear-fr-2.mkv
            #EXTINF:-1 group-title="Séries",The Bear (2022) S01E01 VOSTFR
            https://example.com/series/bear-vo-1.mkv
            #EXTINF:-1 group-title="Séries",The Bear S01E02 VOSTFR
            https://example.com/series/bear-vo-2.mkv
            #EXTINF:-1 group-title="Séries" audio-language="en-US",The Bear S01E01
            https://example.com/series/bear-en-1.mkv
            #EXTINF:-1 group-title="Films" tvg-language="French,English",Arrival
            https://example.com/movie/arrival.mkv
            """)
        let catalog = M3UCatalogMapper.makeCatalog(from: playlist, sourceID: sourceID)
        #expect(catalog.series.map(\.title) == ["The Bear", "The Bear", "The Bear"])
        #expect(catalog.series.map(\.year) == [2022, 2022, 2022])
        #expect(catalog.series.map(\.tags) == [["VF"], ["VOSTFR"], ["ENG"]])
        let french = try #require(catalog.series.first)
        let vostfr = try #require(catalog.series.dropFirst().first)
        let legacyID = StableHash.hex("the bear|Séries")
        #expect(french.nativeID == legacyID)
        #expect(vostfr.nativeID != legacyID)
        #expect(french.seasons?.first?.episodes.map(\.number) == [1, 2])
        #expect(vostfr.seasons?.first?.episodes.map(\.number) == [1, 2])
        #expect(french.seasons?.first?.episodes.first?.streamURL.lastPathComponent == "bear-fr-1.mkv")
        #expect(vostfr.seasons?.first?.episodes.first?.streamURL.lastPathComponent == "bear-vo-1.mkv")
        #expect(catalog.movies.first?.tags == ["ENG", "FRA"])
    }

    @Test func categoriesKeepOrderAndAdultFlag() throws {
        let catalog = try catalog("standard")
        let live = catalog.categories.filter { $0.kind == .live }
        #expect(live.map(\.name) == ["Généralistes", "Entertainment", "XXX | Adults"])
        #expect(live.map(\.sortIndex) == [0, 1, 2])
        #expect(live.map(\.isAdult) == [false, false, true])
        #expect(live[0].rawName == "FR | GÉNÉRALISTES")
        #expect(catalog.channels[0].categoryID == live[0].id)
        let movies = catalog.categories.filter { $0.kind == .movie }
        #expect(movies.map(\.name) == ["Films 4K", "Films Action"])
        let series = catalog.categories.filter { $0.kind == .series }
        #expect(series.map(\.name) == ["Séries VOSTFR"])
        #expect(catalog.series.first?.categoryID == series.first?.id)
    }

    @Test func identifiersAreStableAcrossParses() throws {
        let first = try catalog("standard")
        let second = try catalog("standard")
        #expect(first.channels.map(\.id) == second.channels.map(\.id))
        #expect(first.movies.map(\.id) == second.movies.map(\.id))
        #expect(first.series.map(\.id) == second.series.map(\.id))
        #expect(first.categories.map(\.id) == second.categories.map(\.id))
        #expect(first.series.first?.seasons?.first?.episodes.map(\.id) == second.series.first?.seasons?.first?.episodes.map(\.id))
        // Known value: FNV-1a of the URL (never `hashValue`).
        #expect(first.channels[0].nativeID == StableHash.hex("http://live.example.com/live/user/pass/1001.ts"))
        #expect(Set(first.channels.map(\.id)).count == first.channels.count)
    }

    @Test func messyPlaylist() throws {
        let catalog = try catalog("messy")
        #expect(catalog.channels.map(\.name) == ["TF1, la une", "Canal+", "Arte", "LCI", "RTMP Channel"])
        let canal = catalog.channels[1]
        #expect(canal.quality == .hd)
        #expect(canal.httpHeaders["User-Agent"] == "Mozilla/5.0")
        // Separator line defines the group of following entries without group-title.
        let arte = catalog.channels[2]
        let arteCategory = try #require(catalog.categories.first { $0.id == arte.categoryID })
        #expect(arteCategory.name == "France")
        #expect(arte.quality == .fhd)
        #expect(catalog.channels[3].catchup == Catchup(mode: .shift, days: 3, template: nil))

        #expect(catalog.series.map(\.title) == ["Breaking Bad"])
        #expect(catalog.series.first?.year == 2008)
        #expect(catalog.series.first?.seasons?.map(\.number) == [1, 2])
        #expect(catalog.movies.map(\.title) == ["Amélie"])
        #expect(catalog.movies.first?.year == 2001)
        #expect(catalog.movies.first?.durationSeconds == 5400)
    }

    @Test func duplicateURLsGetDistinctIDs() {
        let text = "#EXTINF:-1 group-title=\"A\",TF1\nhttp://x.example.com/1.ts\n#EXTINF:-1 group-title=\"B\",TF1\nhttp://x.example.com/1.ts\n"
        let catalog = M3UCatalogMapper.makeCatalog(from: M3UParser.parse(text), sourceID: sourceID)
        #expect(catalog.channels.count == 2)
        #expect(catalog.channels[0].id != catalog.channels[1].id)
        #expect(catalog.channels[1].nativeID.hasSuffix("-2"))
    }

    @Test func invalidCatchupDurationsUseDefaultWhenModeIsExplicit() {
        for invalid in ["nan", "inf", "1e100"] {
            let catchup = M3UCatalogMapper.catchup(from: ["catchup": "shift", "catchup-days": invalid])
            #expect(catchup == Catchup(mode: .shift, days: M3UCatalogMapper.defaultCatchupDays))
        }
    }

    @Test func classificationRules() {
        func kind(_ name: String, _ url: String, duration: Int = -1, attributes: [String: String] = [:]) -> MediaKind {
            let entry = M3UEntry(name: name, url: URL(string: url)!, duration: duration, attributes: attributes)
            return M3UCatalogMapper.classify(entry, TitleNormalizer.normalize(name))
        }
        #expect(kind("TF1", "http://h/live/u/p/1.ts") == .live)
        #expect(kind("TF1", "http://h/1.m3u8") == .live)
        #expect(kind("TF1", "http://h/stream") == .live)
        #expect(kind("Avatar", "http://h/movie/u/p/1.mkv") == .movie)
        #expect(kind("Avatar", "http://h/files/avatar.mp4") == .movie)
        #expect(kind("Avatar", "http://h/files/avatar", duration: 7200) == .movie)
        #expect(kind("Show S01E02", "http://h/files/show.mp4") == .series)
        #expect(kind("Show", "http://h/series/u/p/9.mkv") == .series)
        #expect(kind("Replay", "http://h/replay.mp4", attributes: ["catchup": "default"]) == .live)
        #expect(kind("X", "http://h/x.ts", attributes: ["tvg-type": "movie"]) == .movie)
    }

    @Test func pathMarkerScansURLBytes() {
        func marker(_ url: String) -> MediaKind? {
            M3UCatalogMapper.pathMarker(URL(string: url)!)
        }
        #expect(marker("http://h:8080/live/u/p/1.ts") == .live)
        #expect(marker("http://user:pass@h/movie/x.mkv") == .movie)
        #expect(marker("HTTP://H/SERIES/X") == .series)
        #expect(marker("file:///live/x.ts") == .live)
        #expect(marker("http://h//live/x") == .live)
        #expect(marker("http://h/a/b?next=/live/") == nil) // markers in the query don't count
        #expect(marker("http://h/x.ts?next=/series/") == nil)
        #expect(marker("http://h/files/show.S01E01.mp4") == nil) // last segment is the file name
        #expect(marker("http://h") == nil)
        #expect(marker("http://h/") == nil)
        #expect(marker("http://h/live") == nil) // a marker needs a following segment
    }

    @Test func largePlaylistMapping() {
        let data = M3UParserTests.generatePlaylist(count: 30_000)
        let playlist = M3UParser.parse(data)
        let clock = ContinuousClock()
        var catalog = SourceCatalog(sourceID: sourceID)
        let elapsed = clock.measure { catalog = M3UCatalogMapper.makeCatalog(from: playlist, sourceID: sourceID) }
        print("M3UCatalogMapper: 30 000 entries mapped in \(elapsed)")
        #expect(catalog.channels.count == 10_000)
        #expect(catalog.movies.count == 10_000)
        #expect(catalog.series.reduce(0) { $0 + ($1.seasons?.reduce(0) { $0 + $1.episodes.count } ?? 0) } == 10_000)

        // The parallel pre-pass must concatenate chunks in input order: channels/movies keep
        // the exact playlist sequence, and every id is the FNV-1a of its own URL.
        #expect(catalog.channels.map(\.number) == stride(from: 0, to: 30_000, by: 3).map { Optional($0) })
        #expect(catalog.channels.prefix(3).map(\.name) == ["Channel 0", "Channel 3", "Channel 6"])
        #expect(catalog.channels.last?.name == "Channel 29997")
        #expect(catalog.movies.prefix(2).map(\.title) == ["Movie 1", "Movie 4"])
        #expect(catalog.movies.last?.title == "Movie 29998")
        #expect(catalog.movies.first?.year == 2019)
        #expect(catalog.channels.first?.nativeID == StableHash.hex("http://live.example.com:8080/live/username/password/100000.ts"))
        #expect(catalog.movies.first?.nativeID == StableHash.hex("http://vod.example.com:8080/movie/username/password/200001.mkv"))
        #expect(Set(catalog.channels.map(\.id)).count == catalog.channels.count)
        #expect(Set(catalog.movies.map(\.id)).count == catalog.movies.count)
    }
}
