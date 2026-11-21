import Foundation
import Testing
@testable import PrismCore

@Suite("Xtream credentials & URLs")
struct XtreamURLTests {
    @Test(arguments: [
        ("panel.example.com:8080", "http://panel.example.com:8080"),
        ("http://panel.example.com:8080/", "http://panel.example.com:8080"),
        ("https://panel.example.com/player_api.php?username=a&password=b", "https://panel.example.com"),
        ("http://panel.example.com:8080/c/", "http://panel.example.com:8080"),
        ("http://panel.example.com:8080/c", "http://panel.example.com:8080"),
        ("  HTTP://Panel.Example.com:80  ", "http://panel.example.com:80"),
        ("http://panel.example.com/iptv/player_api.php", "http://panel.example.com/iptv"),
        ("http://panel.example.com:8080/get.php?username=u&password=p&type=m3u_plus", "http://panel.example.com:8080"),
        ("http://panel.example.com:8080/live/u/p/123.ts", "http://panel.example.com:8080"),
        ("192.168.1.10:25461", "http://192.168.1.10:25461"),
        ("http://user:pw@panel.example.com:8080", "http://panel.example.com:8080"),
        ("//panel.example.com", "http://panel.example.com"),
        ("http://[2001:db8::1]:8080/", "http://[2001:db8::1]:8080"),
    ])
    func normalizeServer(_ input: String, _ expected: String) {
        #expect(XtreamCredentials.normalizeServer(input)?.absoluteString == expected)
    }

    @Test(arguments: ["", "   ", "not a url", "ftp://panel.example.com", "http://", "http://:8080", "http://exa mple.com", "http://panel..com", "http://panel.example.com:99999"])
    func normalizeServerRejects(_ input: String) {
        #expect(XtreamCredentials.normalizeServer(input) == nil)
    }

    @Test func fromM3UURL() throws {
        let url = try #require(URL(string: "http://panel.example.com:8080/get.php?username=john&password=p%2Bss&type=m3u_plus&output=ts"))
        let credentials = try #require(XtreamCredentials.fromM3UURL(url))
        #expect(credentials.server.absoluteString == "http://panel.example.com:8080")
        #expect(credentials.username == "john")
        #expect(credentials.password == "p+ss")
        #expect(XtreamCredentials.fromM3UURL(URL(string: "http://h.example.com/list.m3u?username=a&password=b")!) == nil)
        #expect(XtreamCredentials.fromM3UURL(URL(string: "http://h.example.com/get.php?username=a")!) == nil)
    }

    @Test func providerMessageWithFrenchLabels() throws {
        let message = """
        Vos accès IPTV
        - **Serveur :** Panel.Example.com:8080/iptv/
        - Nom d’utilisateur : Alice@Exemple
        - Mot de passe : S+crèt:=# ?!
        """
        let credentials = try #require(XtreamCredentials.fromProviderMessage(message))
        #expect(credentials.server.absoluteString == "http://panel.example.com:8080/iptv")
        #expect(credentials.username == "Alice@Exemple")
        #expect(credentials.password == "S+crèt:=# ?!")
    }

    @Test func providerMessageWithEmbeddedURL() throws {
        let message = "Votre lien [playlist](https://panel.example.com:8443/iptv/get.php?password=A%2B%23%26%29&username=Alice%40Example)."
        let credentials = try #require(XtreamCredentials.fromProviderMessage(message))
        #expect(credentials.server.absoluteString == "https://panel.example.com:8443/iptv")
        #expect(credentials.username == "Alice@Example")
        #expect(credentials.password == "A+#&)")
    }

    @Test func providerMessageWithCompatibleLabelsAndURL() throws {
        let message = """
        Host = <panel.example.com:8080/>
        Username: Alice
        API: https://example.com/docs
        Lien : <http://panel.example.com:8080/player_api.php?username=Alice&password=p+ss%2Fw>
        """
        let credentials = try #require(XtreamCredentials.fromProviderMessage(message))
        #expect(credentials.server.absoluteString == "http://panel.example.com:8080")
        #expect(credentials.password == "p+ss/w")
    }

    @Test(arguments: [
        "Username: Alice\nPassword: p",
        "Je vous donne un nom d’utilisateur Alice et un mot de passe secret https://panel.example.com.",
        "Host: panel.example.com\nUsername: Alice\nMot de passe: p\nPassword: autre",
        "Host: panel.example.com\nhttps://other.example/get.php?username=Alice&password=p",
        "https://panel.example.com/get.php?username=Alice&username=alice&password=p",
        "https://panel.example.com/get.php?username=Alice&password=p%00",
        "https://panel.example.com/playlist.m3u?username=Alice&password=p",
        "https://nom:motdepasse@panel.example.com/get.php?username=Alice&password=p"
    ])
    func rejectsAmbiguousOrIncompleteProviderMessage(_ message: String) {
        #expect(XtreamCredentials.fromProviderMessage(message) == nil)
    }

    @Test func rejectsOversizedProviderMessage() {
        let message = "Server: panel.example.com\nUsername: Alice\nPassword: p\n" + String(repeating: "x", count: 16_384)
        #expect(XtreamCredentials.fromProviderMessage(message) == nil)
    }

    let credentials = XtreamCredentials(server: URL(string: "http://panel.example.com:8080")!, username: "user@mail", password: "p+ss/w")

    @Test func streamURLs() {
        #expect(XtreamURLBuilder.live(credentials, streamID: "101", format: .ts).absoluteString == "http://panel.example.com:8080/live/user@mail/p+ss%2Fw/101.ts")
        #expect(XtreamURLBuilder.live(credentials, streamID: "101", format: .m3u8).absoluteString.hasSuffix("/101.m3u8"))
        #expect(XtreamURLBuilder.movie(credentials, streamID: "5001", ext: "mkv").absoluteString == "http://panel.example.com:8080/movie/user@mail/p+ss%2Fw/5001.mkv")
        #expect(XtreamURLBuilder.movie(credentials, streamID: "5001", ext: nil).absoluteString.hasSuffix("/5001.mp4"))
        #expect(XtreamURLBuilder.movie(credentials, streamID: "5001", ext: ".MKV").absoluteString.hasSuffix("/5001.mkv"))
        #expect(XtreamURLBuilder.episode(credentials, episodeID: "9001", ext: "").absoluteString == "http://panel.example.com:8080/series/user@mail/p+ss%2Fw/9001.mp4")
    }

    @Test func timeshiftURL() throws {
        let start = Date(timeIntervalSince1970: 1_735_758_000) // 2025-01-01 19:00 UTC
        let paris = try #require(TimeZone(identifier: "Europe/Paris"))
        let url = XtreamURLBuilder.timeshift(credentials, streamID: "101", start: start, durationMinutes: 45, timeZone: paris)
        #expect(url.absoluteString == "http://panel.example.com:8080/timeshift/user@mail/p+ss%2Fw/45/2025-01-01:20-00/101.ts")
        let utc = XtreamURLBuilder.timeshift(credentials, streamID: "101", start: start, durationMinutes: 45, timeZone: .gmt)
        #expect(utc.absoluteString.contains("/2025-01-01:19-00/"))
    }

    @Test func apiAndXMLTVURLs() {
        #expect(XtreamURLBuilder.api(credentials, action: nil).absoluteString == "http://panel.example.com:8080/player_api.php?username=user%40mail&password=p%2Bss%2Fw")
        #expect(XtreamURLBuilder.api(credentials, action: "get_vod_info", extra: [URLQueryItem(name: "vod_id", value: "5001")]).absoluteString
            == "http://panel.example.com:8080/player_api.php?username=user%40mail&password=p%2Bss%2Fw&action=get_vod_info&vod_id=5001")
        #expect(XtreamURLBuilder.xmltv(credentials).absoluteString == "http://panel.example.com:8080/xmltv.php?username=user%40mail&password=p%2Bss%2Fw")
        let sub = XtreamCredentials(server: URL(string: "https://panel.example.com/iptv/")!, username: "u", password: "p")
        #expect(XtreamURLBuilder.api(sub, action: "get_series").absoluteString == "https://panel.example.com/iptv/player_api.php?username=u&password=p&action=get_series")
    }

    @Test func frenchErrorDescriptions() {
        #expect(XtreamError.unauthorized.errorDescription == "Identifiants refusés par le serveur.")
        #expect(XtreamError.http(502).errorDescription?.contains("502") == true)
        #expect(XtreamError.accountExpired(nil).errorDescription == "Abonnement expiré.")
        #expect(XtreamError.accountExpired(Date(timeIntervalSince1970: 1_704_067_200)).errorDescription?.contains("2024") == true)
    }
}

@Suite("Xtream decoding")
struct XtreamDecodingTests {
    let sourceID: SourceID = "xt1"
    let credentials = XtreamCredentials(server: URL(string: "http://panel.example.com:8080")!, username: "demo", password: "secret")

    @Test func authentication() throws {
        let account = try XtreamDecoder.account(try Fixture.data("xtream_auth", "json"), credentials: credentials)
        #expect(account.username == "demo")
        #expect(account.status == "Active")
        #expect(account.isActive)
        #expect(!account.isTrial)
        #expect(account.expiresAt == Date(timeIntervalSince1970: 1_767_225_600))
        #expect(account.createdAt == Date(timeIntervalSince1970: 1_704_067_200))
        #expect(account.maxConnections == 2)
        #expect(account.activeConnections == 1)
        #expect(account.allowedOutputFormats == ["m3u8", "ts", "rtmp"])
        #expect(account.serverTimeZone == "Europe/Paris")
        #expect(account.serverURL?.absoluteString == "http://panel.example.com:8080")
    }

    @Test func authenticationFailures() throws {
        #expect(throws: XtreamError.accountExpired(Date(timeIntervalSince1970: 1_704_067_200))) {
            try XtreamDecoder.account(try Fixture.data("xtream_auth_expired", "json"), credentials: credentials)
        }
        #expect(throws: XtreamError.unauthorized) {
            try XtreamDecoder.account(Data(#"{"user_info":{"auth":0}}"#.utf8), credentials: credentials)
        }
        #expect(throws: XtreamError.unauthorized) {
            try XtreamDecoder.account(Data("[]".utf8), credentials: credentials)
        }
        #expect(throws: XtreamError.accountDisabled("Banned")) {
            try XtreamDecoder.account(Data(#"{"user_info":{"auth":"1","status":"Banned"}}"#.utf8), credentials: credentials)
        }
        #expect(throws: XtreamError.self) {
            try XtreamDecoder.account(Data("<html>502</html>".utf8), credentials: credentials)
        }
    }

    @Test func categories() throws {
        let categories = try XtreamDecoder.categories(try Fixture.data("xtream_live_categories", "json"), kind: .live, sourceID: sourceID)
        #expect(categories.map(\.nativeID) == ["1", "2", "3", "4"])
        #expect(categories.map(\.name) == ["Généralistes", "Sport", "XXX | Adults", "Sans nom"])
        #expect(categories.map(\.isAdult) == [false, false, true, false])
        #expect(categories.map(\.sortIndex) == [0, 1, 2, 3])
        #expect(categories[0].id == "xt1:live:1")
        #expect(categories[0].rawName == "FR | GÉNÉRALISTES")
    }

    @Test func liveStreams() throws {
        let channels = try XtreamDecoder.liveStreams(
            try Fixture.data("xtream_live_streams", "json"), sourceID: sourceID, credentials: credentials,
            preferHLS: true, allowedFormats: ["m3u8", "ts"], adultCategoryIDs: ["3"]
        )
        #expect(channels.map(\.nativeID) == ["101", "102", "103", "104", "105"])
        let tf1 = channels[0]
        #expect(tf1.name == "TF1")
        #expect(tf1.rawName == "FR: TF1 HD")
        #expect(tf1.quality == .hd)
        #expect(tf1.tags == ["FR"])
        #expect(tf1.number == 1)
        #expect(tf1.epgID == "tf1.fr")
        #expect(tf1.logoURL?.absoluteString == "http://logos.example.com/tf1.png")
        #expect(tf1.categoryID == "xt1:live:1")
        #expect(tf1.catchup == Catchup(mode: .xtream, days: 7))
        #expect(tf1.streamURL.absoluteString == "http://panel.example.com:8080/live/demo/secret/101.m3u8")
        #expect(tf1.alternateStreamURL?.absoluteString == "http://panel.example.com:8080/live/demo/secret/101.ts")
        #expect(tf1.id.rawValue == "xt1:live:101")

        let f2 = channels[1]
        #expect(f2.number == 2)
        #expect(f2.logoURL == nil)
        #expect(f2.epgID == nil)
        #expect(f2.catchup == nil)
        #expect(f2.categoryID == "xt1:live:1")
        #expect(f2.quality == .fhd)

        let bein = channels[2]
        #expect(bein.name == "beIN SPORTS 1")
        #expect(bein.logoURL == nil)
        #expect(bein.categoryID == "xt1:live:2")
        #expect(bein.catchup?.days == 3)

        #expect(channels[3].isAdult)
        #expect(!channels[0].isAdult)
        #expect(channels[4].name == "Chaîne 105")
        #expect(channels[4].categoryID == nil)
    }

    @Test func liveStreamFormats() throws {
        let data = try Fixture.data("xtream_live_streams", "json")
        let tsOnly = try XtreamDecoder.liveStreams(data, sourceID: sourceID, credentials: credentials, preferHLS: true, allowedFormats: ["ts"])
        #expect(tsOnly[0].streamURL.pathExtension == "ts")
        #expect(tsOnly[0].alternateStreamURL == nil)
        let any = try XtreamDecoder.liveStreams(data, sourceID: sourceID, credentials: credentials, preferHLS: true, allowedFormats: [])
        #expect(any[0].streamURL.pathExtension == "m3u8")
        let noHLS = try XtreamDecoder.liveStreams(data, sourceID: sourceID, credentials: credentials, preferHLS: false, allowedFormats: ["m3u8", "ts"])
        #expect(noHLS[0].streamURL.pathExtension == "ts")
        #expect(noHLS[0].alternateStreamURL?.pathExtension == "m3u8")
        let hlsOnly = try XtreamDecoder.liveStreams(data, sourceID: sourceID, credentials: credentials, preferHLS: false, allowedFormats: ["m3u8"])
        #expect(hlsOnly[0].streamURL.pathExtension == "m3u8")
    }

    @Test func vodStreams() throws {
        let movies = try XtreamDecoder.vodStreams(try Fixture.data("xtream_vod_streams", "json"), sourceID: sourceID, credentials: credentials)
        #expect(movies.map(\.nativeID) == ["5001", "5002", "5003", "5005"])
        let avatar = movies[0]
        #expect(avatar.title == "Avatar")
        #expect(avatar.year == 2009)
        #expect(avatar.quality == .uhd)
        #expect(avatar.tags == ["FR"])
        #expect(avatar.rating == 7.4)
        #expect(avatar.tmdbID == 19995)
        #expect(avatar.trailerURL?.absoluteString == "https://www.youtube.com/watch?v=5PSNL1qE6VY")
        #expect(avatar.addedAt == Date(timeIntervalSince1970: 1_704_067_200))
        #expect(avatar.containerExtension == "mkv")
        #expect(avatar.streamURL.absoluteString == "http://panel.example.com:8080/movie/demo/secret/5001.mkv")
        #expect(avatar.categoryID == "xt1:movie:10")
        #expect(avatar.posterURL?.absoluteString == "http://img.example.com/avatar.jpg")

        let inception = movies[1]
        #expect(inception.title == "Inception")
        #expect(inception.year == 2010)
        #expect(inception.quality == .fhd)
        #expect(inception.tags == ["MULTI"])
        #expect(inception.rating == 8.8)
        #expect(inception.genres == ["Action", "Science-Fiction", "Thriller"])
        #expect(inception.cast == ["Leonardo DiCaprio", "Joseph Gordon-Levitt"])
        #expect(inception.director == "Christopher Nolan")
        #expect(inception.durationSeconds == 148 * 60)
        #expect(inception.posterURL == nil)

        let war = movies[2]
        #expect(war.title == "1917")
        #expect(war.year == 2019)
        #expect(war.rating == 8.2)
        #expect(war.addedAt == nil)
        #expect(war.streamURL.pathExtension == "mp4")
        #expect(war.containerExtension == nil)

        let old = movies[3]
        #expect(old.year == 1950)
        #expect(old.categoryID == "xt1:movie:11")
    }

    @Test func seriesList() throws {
        let series = try XtreamDecoder.series(try Fixture.data("xtream_series", "json"), sourceID: sourceID, adultCategoryIDs: ["21"])
        #expect(series.map(\.nativeID) == ["301", "302", "303"])
        let bear = series[0]
        #expect(bear.title == "The Bear")
        #expect(bear.year == 2022)
        #expect(bear.cast == ["Jeremy Allen White", "Ayo Edebiri"])
        #expect(bear.genres == ["Comédie", "Drame"])
        #expect(bear.backdropURL?.absoluteString == "http://img.example.com/bear_bd.jpg")
        #expect(bear.addedAt == Date(timeIntervalSince1970: 1_704_067_200))
        #expect(bear.tmdbID == 136315)
        #expect(bear.rating == 8.6)
        #expect(bear.seasons == nil)
        #expect(bear.categoryID == "xt1:series:20")
        let bb = series[1]
        #expect(bb.year == 2008)
        #expect(bb.posterURL == nil)
        #expect(bb.backdropURL?.absoluteString == "http://img.example.com/bb_bd.jpg")
        #expect(bb.plot == nil)
        #expect(bb.cast.isEmpty)
        #expect(series[2].isAdult)
    }

    @Test func movieDetail() throws {
        let movie = Movie(sourceID: sourceID, nativeID: "5001", title: "Avatar", streamURL: URL(string: "http://x.example.com/1.mkv")!)
        let detail = try XtreamDecoder.movieDetail(try Fixture.data("xtream_vod_info", "json"), movie: movie)
        #expect(detail.movieID == movie.id)
        #expect(detail.plot == "Sur la lointaine planète de Pandora…")
        #expect(detail.cast == ["Sam Worthington", "Zoe Saldana", "Sigourney Weaver"])
        #expect(detail.director == "James Cameron")
        #expect(detail.genres == ["Action", "Aventure", "Science-Fiction"])
        #expect(detail.backdropURLs.count == 2)
        #expect(detail.durationSeconds == 9722)
        #expect(detail.releaseDate == Date(timeIntervalSince1970: 1_260_921_600))
        #expect(detail.rating == 7.5)
        #expect(detail.country == "United States of America")
        #expect(detail.trailerURL?.absoluteString == "https://www.youtube.com/watch?v=5PSNL1qE6VY")
        #expect(detail.tmdbID == 19995)
        let tech = try #require(detail.tech)
        #expect(tech.videoCodec == "hevc")
        #expect(tech.width == 3840)
        #expect(tech.height == 2160)
        #expect(tech.quality == .uhd)
        #expect(tech.frameRate == 23.98)
        #expect(tech.isHDR)
        #expect(tech.audioCodec == "eac3")
        #expect(tech.audioChannels == 6)
        #expect(tech.bitrateKbps == 15832)
    }

    @Test func movieDetailWithEmptyInfo() throws {
        let movie = Movie(sourceID: sourceID, nativeID: "5003", title: "1917", streamURL: URL(string: "http://x.example.com/1.mp4")!)
        let detail = try XtreamDecoder.movieDetail(try Fixture.data("xtream_vod_info_empty", "json"), movie: movie)
        #expect(detail.plot == nil)
        #expect(detail.cast.isEmpty)
        #expect(detail.tech == nil)
        #expect(detail.durationSeconds == nil)
    }

    @Test func seriesDetailWithEpisodeDictionary() throws {
        let series = Series(sourceID: sourceID, nativeID: "301", title: "The Bear")
        let detail = try XtreamDecoder.seriesDetail(try Fixture.data("xtream_series_info", "json"), series: series, credentials: credentials)
        #expect(detail.seriesID == series.id)
        #expect(detail.seasons.map(\.number) == [1, 2])
        let s1 = detail.seasons[0]
        #expect(s1.name == "Saison 1")
        #expect(s1.posterURL?.absoluteString == "http://img.example.com/s1_big.jpg")
        #expect(s1.overview == "Première saison.")
        #expect(s1.episodes.map(\.number) == [1, 2])
        #expect(s1.episodes.map(\.title) == ["Épisode 1", "Hands"])
        #expect(s1.episodes[0].streamURL.absoluteString == "http://panel.example.com:8080/series/demo/secret/9001.mkv")
        #expect(s1.episodes[0].seriesID == series.id)
        #expect(s1.episodes[0].id.rawValue == "xt1:episode:9001")
        #expect(s1.episodes[1].durationSeconds == 1690)
        #expect(s1.episodes[1].plot == "Episode two.")
        let s2 = detail.seasons[1]
        #expect(s2.name == "Season 2")
        #expect(s2.episodes[0].title == "Beef")
        #expect(s2.episodes[0].durationSeconds == 1800)
        #expect(s2.episodes[0].stillURL?.absoluteString == "http://img.example.com/e201.jpg")
        #expect(s2.episodes[0].rating == 8.1)
        #expect(s2.episodes[0].airDate == Date(timeIntervalSince1970: 1_687_392_000))
        #expect(detail.genres == ["Comédie", "Drame"])
        #expect(detail.trailerURL?.absoluteString == "https://www.youtube.com/watch?v=y-cqqAJIXhs")
        #expect(detail.tmdbID == 136315)
        #expect(detail.backdropURLs.map(\.absoluteString) == ["http://img.example.com/bear_bd.jpg"])
    }

    @Test func seriesDetailWithEpisodeArray() throws {
        let series = Series(sourceID: sourceID, nativeID: "302", title: "Breaking Bad")
        let detail = try XtreamDecoder.seriesDetail(try Fixture.data("xtream_series_info_array", "json"), series: series, credentials: credentials)
        #expect(detail.seasons.map(\.number) == [1, 2])
        #expect(detail.seasons[0].episodes.map(\.title) == ["Pilot", "Épisode 2"])
        #expect(detail.seasons[0].episodes[0].durationSeconds == 3480)
        #expect(detail.seasons[1].episodes.first?.title == "Seven Thirty-Seven")
        #expect(detail.seasons[1].episodes.first?.containerExtension == "mkv")
        #expect(detail.plot == nil)
    }

    @Test func shortEPG() throws {
        let programs = try XtreamDecoder.shortEPG(try Fixture.data("xtream_short_epg", "json"), streamID: "101", epgChannelID: "tf1.fr")
        #expect(programs.count == 3)
        #expect(programs[0].title == "Le Journal de 20h")
        #expect(programs[0].summary == "Toute l'actualité du jour.")
        #expect(programs[0].start == Date(timeIntervalSince1970: 1_735_758_000))
        #expect(programs[0].end == Date(timeIntervalSince1970: 1_735_760_700))
        #expect(programs[0].channelID == "tf1.fr")
        #expect(programs[1].title == "Météo")
        #expect(programs[1].summary == nil)
        #expect(programs[2].title == "not base64 !!")
        let fallback = try XtreamDecoder.shortEPG(try Fixture.data("xtream_short_epg", "json"), streamID: "101", epgChannelID: nil)
        #expect(fallback[0].channelID == "tf1.fr")
    }

    @Test func emptyAndHostileBodies() throws {
        #expect(try XtreamDecoder.liveStreams(Data(), sourceID: sourceID, credentials: credentials, preferHLS: true).isEmpty)
        #expect(try XtreamDecoder.vodStreams(Data("[]".utf8), sourceID: sourceID, credentials: credentials).isEmpty)
        #expect(try XtreamDecoder.series(Data(#"{"user_info":{"auth":0}}"#.utf8), sourceID: sourceID).isEmpty)
        #expect(try XtreamDecoder.categories(Data(#"{"0":{"category_id":"9","category_name":"A"}}"#.utf8), kind: .movie, sourceID: sourceID).map(\.nativeID) == ["9"])
        #expect(throws: XtreamError.self) { try XtreamDecoder.vodStreams(Data("<html>".utf8), sourceID: sourceID, credentials: credentials) }
    }

    @Test(arguments: [
        ("1", true), ("0", false), ("true", true), ("", nil), ("yes", true),
    ] as [(String, Bool?)])
    func lenientBooleans(_ raw: String, _ expected: Bool?) {
        #expect(LenientValue.bool(raw) == expected)
    }

    @Test func lenientScalars() {
        #expect(LenientValue.int("12") == 12)
        #expect(LenientValue.int(" 12.7 ") == 12)
        #expect(LenientValue.int(NSNumber(value: 3.0)) == 3)
        #expect(LenientValue.int("") == nil)
        #expect(LenientValue.int(NSNull()) == nil)
        #expect(LenientValue.double("7,4") == 7.4)
        #expect(LenientValue.string(NSNumber(value: 101)) == "101")
        #expect(LenientValue.string("  ") == nil)
        #expect(LenientValue.url("http://a.example.com/x y.png")?.absoluteString == "http://a.example.com/x%20y.png")
        #expect(LenientValue.url("nope") == nil)
        #expect(LenientValue.date("1704067200") == Date(timeIntervalSince1970: 1_704_067_200))
        #expect(LenientValue.date("0") == nil)
        #expect(LenientValue.day("2019-05-02") == Date(timeIntervalSince1970: 1_556_755_200))
        #expect(LenientValue.day("02/05/2019") == Date(timeIntervalSince1970: 1_556_755_200))
        #expect(LenientValue.hms("01:52:33") == 6753)
        #expect(LenientValue.list("a, b,, a") == ["a", "b"])
    }
}

@Suite("XtreamClient (stubbed network)")
struct XtreamClientTests {
    func client(host: String) -> XtreamClient {
        let credentials = XtreamCredentials(server: URL(string: "http://\(host):8080")!, username: "demo", password: "secret")
        return XtreamClient(credentials: credentials, sourceID: "xt1", userAgent: "PrismTests/1.0", session: StubURLProtocol.session())
    }

    @Test func authenticateSuccess() async throws {
        let host = "auth-ok.test"
        StubURLProtocol.register(host: host, action: nil, body: try Fixture.data("xtream_auth", "json"))
        let account = try await client(host: host).authenticate()
        #expect(account.isActive)
        #expect(account.maxConnections == 2)
        let request = try #require(StubURLProtocol.recordedRequests(host: host).first)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "PrismTests/1.0")
        #expect(request.url?.path() == "/player_api.php")
    }

    @Test func authenticateHTTPUnauthorized() async {
        let host = "auth-401.test"
        StubURLProtocol.register(host: host, action: nil, status: 401, body: Data())
        await #expect(throws: XtreamError.unauthorized) { try await client(host: host).authenticate() }
    }

    @Test func authenticateExpired() async throws {
        let host = "auth-expired.test"
        StubURLProtocol.register(host: host, action: nil, body: try Fixture.data("xtream_auth_expired", "json"))
        await #expect(throws: XtreamError.accountExpired(Date(timeIntervalSince1970: 1_704_067_200))) { try await client(host: host).authenticate() }
    }

    @Test func serverErrorIsRetriedThenReported() async {
        let host = "auth-503.test"
        StubURLProtocol.register(host: host, action: nil, status: 503, body: Data())
        await #expect(throws: XtreamError.http(503)) { try await client(host: host).authenticate() }
        #expect(StubURLProtocol.recordedRequests(host: host).count == 3)
    }

    @Test func networkFailure() async {
        await #expect(throws: XtreamError.self) { try await client(host: "unrouted.test").categories(.live) }
    }

    @Test func authenticationExplainsTransportSecurityFailures() async {
        let httpHost = "cleartext.test"
        StubURLProtocol.registerTransportError(host: httpHost, code: .appTransportSecurityRequiresSecureConnection)
        await #expect(throws: XtreamError.secureConnectionRequired) { try await client(host: httpHost).authenticate() }

        let tlsHost = "untrusted.test"
        StubURLProtocol.registerTransportError(host: tlsHost, code: .serverCertificateUntrusted)
        await #expect(throws: XtreamError.untrustedSecureConnection) { try await client(host: tlsHost).authenticate() }
    }

    @Test func liveStreamsUseCategoryAdultFlags() async throws {
        let host = "live.test"
        StubURLProtocol.register(host: host, action: "get_live_categories", body: try Fixture.data("xtream_live_categories", "json"))
        StubURLProtocol.register(host: host, action: "get_live_streams", body: try Fixture.data("xtream_live_streams", "json"))
        let client = client(host: host)
        let categories = try await client.categories(.live)
        #expect(categories.count == 4)
        let channels = try await client.liveStreams(preferHLS: true, account: nil)
        #expect(channels.count == 5)
        #expect(channels.first { $0.nativeID == "104" }?.isAdult == true)
    }

    @Test func detailsAndEPG() async throws {
        let host = "details.test"
        StubURLProtocol.register(host: host, action: "get_vod_info", body: try Fixture.data("xtream_vod_info", "json"))
        StubURLProtocol.register(host: host, action: "get_series_info", body: try Fixture.data("xtream_series_info", "json"))
        StubURLProtocol.register(host: host, action: "get_short_epg", body: try Fixture.data("xtream_short_epg", "json"))
        let client = client(host: host)
        let movie = Movie(sourceID: "xt1", nativeID: "5001", title: "Avatar", streamURL: URL(string: "http://x.example.com/1.mkv")!)
        #expect(try await client.movieDetail(movie).durationSeconds == 9722)
        let series = Series(sourceID: "xt1", nativeID: "301", title: "The Bear")
        #expect(try await client.seriesDetail(series).seasons.count == 2)
        #expect(try await client.shortEPG(streamID: "101", epgChannelID: nil, limit: 4).count == 3)
        let urls = StubURLProtocol.recordedRequests(host: host).compactMap(\.url?.absoluteString)
        #expect(urls.contains { $0.contains("action=get_vod_info&vod_id=5001") })
        #expect(urls.contains { $0.contains("action=get_series_info&series_id=301") })
        #expect(urls.contains { $0.contains("action=get_short_epg&stream_id=101&limit=4") })
    }
}
