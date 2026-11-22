import Foundation
import Testing
@testable import PrismCore

@Suite("M3UParser")
struct M3UParserTests {
    @Test func standardPlaylist() throws {
        let playlist = M3UParser.parse(try Fixture.data("standard", "m3u"))
        #expect(playlist.entries.count == 10)
        #expect(playlist.epgURLs.map(\.absoluteString) == ["http://epg.example.com/guide.xml.gz", "http://epg2.example.com/epg.xml"])
        #expect(playlist.headerAttributes["tvg-shift"] == "1")

        let tf1 = try #require(playlist.entries.first)
        #expect(tf1.name == "FR: TF1 HD")
        #expect(tf1.duration == -1)
        #expect(tf1.url.absoluteString == "http://live.example.com/live/user/pass/1001.ts")
        #expect(tf1.attributes["tvg-id"] == "tf1.fr")
        #expect(tf1.attributes["tvg-chno"] == "1")
        #expect(tf1.attributes["tvg-logo"] == "http://logos.example.com/tf1.png")
        #expect(tf1.group == "FR | GÉNÉRALISTES")

        let m6 = playlist.entries[2]
        #expect(m6.attributes["catchup-source"] == "?utc={utc}&lutc={lutc}")
        #expect(m6.attributes["catchup-days"] == "7")
        #expect(playlist.entries[6].duration == 7620)
    }

    @Test func messyPlaylist() throws {
        let playlist = M3UParser.parse(try Fixture.data("messy", "m3u"))
        #expect(playlist.epgURLs.map(\.absoluteString) == ["http://epg.example.com/a.xml"])
        let names = playlist.entries.map(\.name)
        #expect(names == [
            "TF1, la une", "Canal+ ᴴᴰ", "##### FRANCE #####", "|FR| Arte FHD", "LCI",
            "Breaking Bad (2008) S01E01", "Breaking Bad (2008) S01E02", "Breaking Bad (2008) S02E01",
            "Amélie (2001)", "RTMP Channel",
        ])

        let tf1 = playlist.entries[0]
        #expect(tf1.attributes["tvg-id"] == "tf1.fr")
        #expect(tf1.group == "News")
        #expect(tf1.attributes["tvg-logo"] == "http://logos.example.com/tf1.png")
        #expect(tf1.headers["User-Agent"] == "VLC/3.0.20 LibVLC/3.0.20")
        #expect(tf1.headers["Referer"] == "http://referer.example.com/")
        #expect(tf1.url.absoluteString == "http://live.example.com/tf1.m3u8")

        let canal = playlist.entries[1]
        #expect(canal.attributes["tvg-name"] == "Canal+")
        #expect(canal.group == "Cinéma, Séries")
        #expect(canal.url.absoluteString == "http://live.example.com/canal.ts")
        #expect(canal.headers == ["User-Agent": "Mozilla/5.0", "Referer": "http://site.example.com/"])

        let arte = playlist.entries[3]
        #expect(arte.headers["User-Agent"] == "Prism-Test")
        #expect(arte.headers["Cookie"] == "a=b")

        #expect(playlist.entries[4].attributes["timeshift"] == "3")
        #expect(playlist.entries[4].headers.isEmpty)

        let amelie = playlist.entries[8]
        #expect(amelie.group == "Films")
        #expect(amelie.duration == 5400)

        let rtmp = playlist.entries[9]
        #expect(rtmp.url.scheme == "rtmp")
        #expect(rtmp.headers["User-Agent"] == "Kodi/20")
        #expect(rtmp.headers["Origin"] == "http://origin.example.com")
    }

    @Test func lineEndingsAndMissingHeader() {
        let text = "#EXTINF:-1,One\rhttp://a.example.com/1.ts\r#EXTINF:-1,Two\nhttp://a.example.com/2.ts\r\n#EXTINF:-1 ,Three\r\n\r\nhttp://a.example.com/3.ts"
        let playlist = M3UParser.parse(text)
        #expect(playlist.entries.map(\.name) == ["One", "Two", "Three"])
        #expect(playlist.epgURLs.isEmpty)
    }

    @Test func latin1Fallback() {
        var bytes = Array("#EXTM3U\n#EXTINF:-1 group-title=\"Ciné\",Am".utf8)
        bytes.removeLast(0)
        // "Ciné" and "Amélie" encoded in ISO-8859-1 (é = 0xE9).
        let latin1: [UInt8] = Array("#EXTM3U\n#EXTINF:-1 group-title=\"Cin".utf8) + [0xE9] + Array("\",Am".utf8) + [0xE9] + Array("lie\nhttp://v.example.com/a.mp4\n".utf8)
        let playlist = M3UParser.parse(Data(latin1))
        #expect(playlist.entries.first?.name == "Amélie")
        #expect(playlist.entries.first?.group == "Ciné")
    }

    @Test(.timeLimit(.minutes(1)))
    func strayEqualsSignsDoNotStallTheScan() {
        let text = """
        #EXTM3U foo=
        #EXTINF:-1 tvg-id="a"="b",Nom
        http://h.example.com/a.ts
        #EXTINF:-1 =x tvg-name="B",Autre
        http://h.example.com/b.ts
        """
        let playlist = M3UParser.parse(text)
        #expect(playlist.entries.map(\.name) == ["Nom", "Autre"])
        #expect(playlist.entries[0].attributes["tvg-id"] == "a")
        #expect(playlist.entries[1].attributes["tvg-name"] == "B")
    }

    @Test func quotingAndAttributes() {
        let text = """
        #EXTM3U
        #EXTINF:-1 tvg-ID="X.fr" TVG-NAME="A, B" group-title="G1",Name, with, commas
        http://h.example.com/x.ts
        #EXTINF:0 tvg-logo=http://l.example.com/a.png catchup=shift,Unquoted
        https://h.example.com/y.m3u8?token=1|user-agent=UA%201
        #EXTINF:-1 group-title="Broken,Name
        http://h.example.com/z.ts
        """
        let playlist = M3UParser.parse(text)
        #expect(playlist.entries.count == 3)
        let first = playlist.entries[0]
        #expect(first.attributes["tvg-id"] == "X.fr")
        #expect(first.attributes["tvg-name"] == "A, B")
        #expect(first.name == "Name, with, commas")
        let second = playlist.entries[1]
        #expect(second.duration == 0)
        #expect(second.attributes["tvg-logo"] == "http://l.example.com/a.png")
        #expect(second.attributes["catchup"] == "shift")
        #expect(second.name == "Unquoted")
        #expect(second.url.absoluteString == "https://h.example.com/y.m3u8?token=1")
        #expect(second.headers["User-Agent"] == "UA 1")
        #expect(playlist.entries[2].name == "Name")
    }

    @Test func plainURLListAndUnsupportedLines() {
        let text = "http://h.example.com/movies/My%20Movie.mp4\nftp://x/y\nrelative/path.ts\nudp://@239.0.0.1:1234\n"
        let playlist = M3UParser.parse(text)
        #expect(playlist.entries.count == 2)
        #expect(playlist.entries[0].name == "My Movie")
        #expect(playlist.entries[1].url.scheme == "udp")
    }

    static func generatePlaylist(count: Int) -> Data {
        var text = "#EXTM3U url-tvg=\"http://epg.example.com/epg.xml.gz\"\n"
        text.reserveCapacity(count * 230)
        let groups = ["FR | GÉNÉRALISTES", "FR | SPORT", "UK | NEWS", "FILMS ACTION", "SÉRIES VOSTFR", "XXX | ADULTS"]
        for i in 0..<count {
            let group = groups[i % groups.count]
            switch i % 3 {
            case 0:
                text += "#EXTINF:-1 tvg-id=\"channel\(i).fr\" tvg-name=\"Channel \(i)\" tvg-logo=\"http://logos.example.com/logos/channel_\(i).png\" tvg-chno=\"\(i)\" group-title=\"\(group)\",FR: Channel \(i) HD\n"
                text += "http://live.example.com:8080/live/username/password/\(100000 + i).ts\n"
            case 1:
                text += "#EXTINF:-1 tvg-id=\"\" tvg-name=\"Movie \(i) (2019)\" tvg-logo=\"http://img.example.com/t/p/w600_and_h900_bestv2/poster\(i).jpg\" group-title=\"\(group)\",FR - Movie \(i) (2019) MULTI 1080p\n"
                text += "http://vod.example.com:8080/movie/username/password/\(200000 + i).mkv\n"
            default:
                text += "#EXTINF:-1 tvg-id=\"\" tvg-name=\"Show \(i / 30) S0\(i % 9 + 1)E\(i % 20 + 10)\" tvg-logo=\"http://img.example.com/t/p/w600_and_h900_bestv2/still\(i).jpg\" group-title=\"\(group)\",Show \(i / 30) S0\(i % 9 + 1)E\(i % 20 + 10)\n"
                text += "http://vod.example.com:8080/series/username/password/\(300000 + i).mp4\n"
            }
        }
        return Data(text.utf8)
    }

    @Test func performance150k() {
        let data = Self.generatePlaylist(count: 150_000)
        let clock = ContinuousClock()
        var playlist = M3UPlaylist()
        let elapsed = clock.measure { playlist = M3UParser.parse(data) }
        print("M3UParser: 150 000 entries, \(data.count / 1_000_000) MB parsed in \(elapsed)")
        #expect(playlist.entries.count == 150_000)
        #expect(elapsed < .seconds(4))
    }
}

@Suite("Valeurs partagées du catalogue")
struct CatalogSharingTests {
    @Test func sharingKeepsEveryValueAndCompactURLsKeepTheirJSON() throws {
        let source: SourceID = "c0ffee00-1111-2222-3333-444455556666"
        func movie(_ id: String, source: SourceID) -> Movie {
            Movie(sourceID: source, nativeID: id, title: "Film \(id)", posterURL: URL(string: "https://image.tmdb.org/t/p/w500/\(id).jpg"),
                  categoryID: "\(source.rawValue):movie:42", streamURL: URL(string: "http://example.com/movie/u/p/\(id).mkv")!,
                  containerExtension: "mkv", tags: ["FR", "HEVC"])
        }
        var catalog = SourceCatalog(sourceID: source, movies: [movie("1", source: source), movie("2", source: "other-source")])
        let before = catalog.movies
        catalog.shareRepeatedValues()
        #expect(catalog.movies == before)

        // The wrapped URLs encode exactly like plain `URL` properties: strings, omitted when nil.
        let json = try JSONEncoder().encode(catalog.movies[0])
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(object["posterURL"] as? String == "https://image.tmdb.org/t/p/w500/1.jpg")
        #expect(object["streamURL"] as? String == "http://example.com/movie/u/p/1.mkv")
        #expect(object["backdropURL"] == nil)
        let decoded = try JSONDecoder().decode(Movie.self, from: json)
        #expect(decoded == catalog.movies[0])
        #expect(decoded.posterURL?.host() == "image.tmdb.org")
        #expect(decoded.$backdropURL == nil)
    }
}
