import Foundation
import PrismCore
import Testing
@testable import PrismData

@Suite("Repositories")
struct RepositoryTests {
    typealias F = Fixture

    static let playlist: String = {
        var lines = ["#EXTM3U url-tvg=\"https://guide.example/epg.xml.gz\""]
        lines.append("#EXTINF:-1 tvg-id=\"TF1.fr\" tvg-name=\"TF1\" tvg-logo=\"https://logo.example/tf1.png\" group-title=\"FR | GÉNÉRALISTES\",FR: TF1 HD")
        lines.append("http://stream.example/live/tf1.m3u8")
        lines.append("#EXTINF:-1 tvg-id=\"France2.fr\" group-title=\"FR | GÉNÉRALISTES\",FR: France 2 FHD")
        lines.append("http://stream.example/live/france2.m3u8")
        lines.append("#EXTINF:-1 group-title=\"VOD | Action\",Heat (1995) MULTI")
        lines.append("http://stream.example/movie/heat.mkv")
        lines.append("#EXTINF:-1 group-title=\"Séries | Drame\",Dark S01E01")
        lines.append("http://stream.example/series/dark-s01e01.mkv")
        lines.append("#EXTINF:-1 group-title=\"Séries | Drame\",Dark S01E02")
        lines.append("http://stream.example/series/dark-s01e02.mkv")
        // Padding entries so that the body is streamed in several chunks.
        for index in 0..<400 {
            lines.append("#EXTINF:-1 tvg-id=\"pad\(index)\" group-title=\"Divers\",Chaîne Divers \(index)")
            lines.append("http://stream.example/live/pad\(index).ts")
        }
        return lines.joined(separator: "\n")
    }()

    func makeRepository(session: URLSession, credentials: any CredentialStoring = InMemoryCredentialStore()) -> (CatalogRepository, AppDirectories) {
        let directories = AppDirectories.temporary()
        return (CatalogRepository(directories: directories, credentials: credentials, cache: CatalogCache(directories: directories), session: session), directories)
    }

    @Test func m3uURLRefreshReportsStagesAndCaches() async throws {
        let host = StubURLProtocol.uniqueHost("m3u")
        StubURLProtocol.register(host: host) { request in
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "VLC/3.0.20")
            return .text(Self.playlist, chunks: 8)
        }
        defer { StubURLProtocol.unregister(host: host) }
        let (repository, directories) = makeRepository(session: StubURLProtocol.session())
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        let source = Source(id: "m3u-src", name: "Nova", kind: .m3uURL, serverURL: URL(string: "https://\(host)/list.m3u"), userAgent: "VLC/3.0.20")

        var stages: [ImportStage] = []
        var last: ImportProgress?
        var fractions: [Double] = []
        for try await progress in repository.refresh(source) {
            stages.append(progress.stage)
            fractions.append(progress.fraction)
            last = progress
        }
        #expect(stages.first == .connecting)
        #expect(stages.contains { if case .downloading = $0 { true } else { false } })
        #expect(stages.contains(.parsing))
        #expect(stages.last == .finished)
        #expect(fractions == fractions.sorted(), "progress never goes backwards")
        let finished = try #require(last)
        let catalog = try #require(finished.catalog)
        #expect(catalog.channels.count == 402)
        #expect(catalog.movies.count == 1)
        #expect(catalog.series.count == 1)
        #expect(finished.counts.channels == 402)
        #expect(finished.epgURLs.map(\.absoluteString) == ["https://guide.example/epg.xml.gz"])
        #expect(repository.playlistEPGURLs(for: source.id).map(\.absoluteString) == ["https://guide.example/epg.xml.gz"])
        #expect(await repository.cache.load(source.id)?.channels.count == 402)
        #expect(await repository.lastRefreshed(source.id)?.movies.count == 1)
        let cached = await repository.cachedCatalogs(for: [source, Fixture.source("unknown")])
        #expect(cached.map(\.sourceID) == [source.id])
    }

    @Test func m3uErrors() async throws {
        let host = StubURLProtocol.uniqueHost("m3u-err")
        StubURLProtocol.register(host: host) { request in
            switch request.url?.path {
            case "/missing.m3u": .text("not found", status: 404)
            case "/login.m3u": .text("<html><body>Login</body></html>")
            case "/empty.m3u": .text("#EXTM3U\n")
            default: .text("", status: 401)
            }
        }
        defer { StubURLProtocol.unregister(host: host) }
        let (repository, directories) = makeRepository(session: StubURLProtocol.session())
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }

        func run(_ path: String) async -> (any Error)? {
            let source = Source(name: "X", kind: .m3uURL, serverURL: URL(string: "https://\(host)\(path)"))
            do {
                for try await _ in repository.refresh(source) {}
                return nil
            } catch {
                return error
            }
        }
        #expect(await run("/missing.m3u") as? SourceError == .http(404))
        #expect(await run("/login.m3u") as? SourceError == .notAPlaylist)
        #expect(await run("/empty.m3u") as? SourceError == .emptyPlaylist)
        #expect(await run("/private.m3u") as? SourceError == .unauthorized)
        let noURL = Source(name: "X", kind: .m3uURL)
        await #expect(throws: SourceError.missingURL) { for try await _ in repository.refresh(noURL) {} }
    }

    @Test func validateM3UAndFile() async throws {
        let host = StubURLProtocol.uniqueHost("validate")
        StubURLProtocol.register(host: host) { request in
            request.url?.path == "/ok.m3u" ? .text(Self.playlist) : .text("<html></html>")
        }
        defer { StubURLProtocol.unregister(host: host) }
        let (repository, directories) = makeRepository(session: StubURLProtocol.session())
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }

        let ok = Source(name: "ok", kind: .m3uURL, serverURL: URL(string: "https://\(host)/ok.m3u"))
        _ = try await repository.validate(ok, password: nil)
        let html = Source(name: "html", kind: .m3uURL, serverURL: URL(string: "https://\(host)/page"))
        await #expect(throws: SourceError.notAPlaylist) { try await repository.validate(html, password: nil) }

        let file = directories.root.appending(path: "local.m3u")
        try FileManager.default.createDirectory(at: directories.root, withIntermediateDirectories: true)
        try Self.playlist.write(to: file, atomically: true, encoding: .utf8)
        let bookmark = try file.bookmarkData()
        let local = Source(name: "file", kind: .m3uFile, fileBookmark: bookmark)
        let validation = try await repository.validate(local, password: nil)
        #expect(validation.sampleCounts?.channels == 402)

        var progress: [ImportStage] = []
        for try await item in repository.refresh(local) { progress.append(item.stage) }
        #expect(progress.last == .finished)

        let missing = Source(name: "missing", kind: .m3uFile, serverURL: directories.root.appending(path: "nope.m3u"))
        await #expect(throws: SourceError.missingFile) { try await repository.validate(missing, password: nil) }
    }

    @Test func demoSourceNeedsNoNetwork() async throws {
        let (repository, directories) = makeRepository(session: StubURLProtocol.session())
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        let demo = DemoContent.makeSource()
        var last: ImportProgress?
        for try await progress in repository.refresh(demo) { last = progress }
        #expect(last?.stage == .finished)
        #expect(last?.catalog?.movies.isEmpty == false)
        #expect(try await repository.validate(demo, password: nil).sampleCounts?.channels == DemoContent.makeCatalog().channels.count)
    }

    @Test func refreshIsCancellable() async throws {
        let host = StubURLProtocol.uniqueHost("slow")
        StubURLProtocol.register(host: host) { _ in
            Thread.sleep(forTimeInterval: 0.3)
            return .text(Self.playlist)
        }
        defer { StubURLProtocol.unregister(host: host) }
        let (repository, directories) = makeRepository(session: StubURLProtocol.session())
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        let source = Source(id: "slow-src", name: "Slow", kind: .m3uURL, serverURL: URL(string: "https://\(host)/list.m3u"))
        let consumer = Task {
            var finished = false
            for try await progress in repository.refresh(source) where progress.stage == .finished { finished = true }
            return finished
        }
        try await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        let finished = (try? await consumer.value) ?? false
        #expect(!finished)
        try await Task.sleep(for: .milliseconds(500))
        #expect(await repository.cache.load(source.id) == nil, "a cancelled import is not cached")
    }

    // MARK: Xtream

    static func xtreamHandler(_ request: URLRequest) -> StubURLProtocol.Response {
        guard request.url?.path == "/player_api.php" else { return .text("", status: 404) }
        guard request.queryValue("password") == "secret" else { return .json(#"{"user_info":{"auth":0}}"#) }
        switch request.queryValue("action") {
        case nil:
            return .json(#"{"user_info":{"username":"louis","auth":1,"status":"Active","exp_date":"1893456000","max_connections":"2","active_cons":"0","allowed_output_formats":["m3u8","ts"]},"server_info":{"url":"xtream.example","port":"8080","timezone":"Europe/Paris"}}"#)
        case "get_live_categories":
            return .json(#"[{"category_id":"1","category_name":"FR | GÉNÉRALISTES"},{"category_id":"2","category_name":"XXX ADULTS"}]"#)
        case "get_vod_categories":
            return .json(#"[{"category_id":"10","category_name":"FILMS ACTION"}]"#)
        case "get_series_categories":
            return .json(#"[{"category_id":"20","category_name":"SÉRIES"}]"#)
        case "get_live_streams":
            return .json(#"[{"num":1,"name":"FR: TF1 HD","stream_id":101,"stream_icon":"https://logo.example/tf1.png","epg_channel_id":"TF1.fr","category_id":"1","tv_archive":1,"tv_archive_duration":"7"},{"num":2,"name":"FR: M6 FHD","stream_id":"102","category_id":"1"}]"#)
        case "get_vod_streams":
            return .json(#"[{"name":"Heat (1995)","stream_id":201,"stream_icon":"https://img.example/heat.jpg","rating":"8.3","added":"1700000000","category_id":"10","container_extension":"mkv"}]"#)
        case "get_series":
            // A broken endpoint must not fail the whole import.
            return .text("Internal error", status: 500)
        case "get_vod_info":
            return .json(#"{"info":{"plot":"Un braqueur et un flic.","director":"Michael Mann","duration_secs":10200,"genre":"Action, Policier"},"movie_data":{"stream_id":201,"container_extension":"mkv"}}"#)
        case "get_short_epg":
            return .json(#"{"epg_listings":[{"title":"Sk9VUk5BTA==","description":"","start_timestamp":"1700000000","stop_timestamp":"1700001800","channel_id":"TF1.fr"}]}"#)
        default:
            return .text("", status: 404)
        }
    }

    @Test func xtreamRefreshAndValidation() async throws {
        let host = StubURLProtocol.uniqueHost("xtream")
        StubURLProtocol.register(host: host, handler: Self.xtreamHandler)
        defer { StubURLProtocol.unregister(host: host) }
        let credentials = InMemoryCredentialStore()
        let (repository, directories) = makeRepository(session: StubURLProtocol.session(), credentials: credentials)
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        let source = Source(id: "xt", name: "Atlas", kind: .xtream, serverURL: URL(string: "http://\(host)"), username: "louis")

        await #expect(throws: SourceError.missingCredentials) { try await repository.validate(source, password: nil) }
        await #expect(throws: XtreamError.unauthorized) { try await repository.validate(source, password: "wrong") }
        let validation = try await repository.validate(source, password: "secret")
        #expect(validation.account?.username == "louis")
        #expect(validation.account?.maxConnections == 2)

        try credentials.setPassword("secret", for: source.id)
        #expect(repository.xtreamCredentials(for: source)?.password == "secret")
        var stages: [ImportStage] = []
        var catalog: SourceCatalog?
        for try await progress in repository.refresh(source) {
            stages.append(progress.stage)
            if let value = progress.catalog { catalog = value }
        }
        #expect(stages.first == .connecting)
        #expect(stages.contains { if case .account(let account) = $0 { account.username == "louis" } else { false } })
        #expect(stages.contains(.channels(2)))
        #expect(stages.contains(.movies(1)))
        #expect(stages.last == .finished)
        let result = try #require(catalog)
        #expect(result.channels.count == 2)
        #expect(result.movies.first?.title == "Heat")
        #expect(result.series.isEmpty)
        #expect(result.categories.count == 4)
        #expect(result.account?.username == "louis")

        let built = await CatalogBuilder.build(sources: [source], catalogs: [result], options: .init(hideAdult: true))
        #expect(built.liveCategories.map(\.name) == ["Généralistes"])
        #expect(built.movieCategories.first?.itemCount == 1)

        // Details (Xtream get_vod_info) are cached in memory and on disk.
        let details = DetailRepository(directories: directories, credentials: credentials, session: StubURLProtocol.session())
        let movie = try #require(result.movies.first)
        let before = StubURLProtocol.requestCount(host: host)
        let detail = try await details.movieDetail(movie, source: source)
        #expect(detail.director == "Michael Mann")
        #expect(detail.durationSeconds == 10_200)
        #expect(StubURLProtocol.requestCount(host: host) == before + 1)
        _ = try await details.movieDetail(movie, source: source)
        let reopened = DetailRepository(directories: directories, credentials: credentials, session: StubURLProtocol.session())
        _ = try await reopened.movieDetail(movie, source: source)
        #expect(StubURLProtocol.requestCount(host: host) == before + 1, "served from memory, then disk")

        // Short EPG fallback.
        let epg = EPGRepository(directories: directories, credentials: credentials, session: StubURLProtocol.session())
        let channel = try #require(result.channels.first)
        let short = try await epg.shortEPG(for: channel, source: source)
        #expect(short.first?.title == "JOURNAL")
        let m3uSource = Source(name: "m3u", kind: .m3uURL, serverURL: URL(string: "https://\(host)/x.m3u"))
        #expect(try await epg.shortEPG(for: channel, source: m3uSource).isEmpty)
        #expect(epg.guideURLs(for: source, playlistEPGURLs: []).first?.path == "/xmltv.php")
    }

    @Test(arguments: [false, true])
    func failedXtreamEndpointKeepsThePreviousList(authError: Bool) async throws {
        let host = StubURLProtocol.uniqueHost("xtream-partial")
        StubURLProtocol.register(host: host, handler: Self.xtreamHandler)
        defer { StubURLProtocol.unregister(host: host) }
        let credentials = InMemoryCredentialStore()
        let (repository, directories) = makeRepository(session: StubURLProtocol.session(), credentials: credentials)
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        let source = Source(id: "xt-partial", name: "Atlas", kind: .xtream, serverURL: URL(string: "http://\(host)"), username: "louis")
        try credentials.setPassword("secret", for: source.id)
        for try await _ in repository.refresh(source) {}
        #expect(await repository.cache.load(source.id)?.movies.count == 1)

        // The VOD endpoints now fail: films and their categories must survive the refresh.
        StubURLProtocol.register(host: host) { request in
            switch request.queryValue("action") {
            case "get_vod_streams", "get_vod_categories":
                authError ? .json(#"{"user_info":{"auth":"0"}}"#) : .text("Internal error", status: 500)
            default: Self.xtreamHandler(request)
            }
        }
        var catalog: SourceCatalog?
        for try await progress in repository.refresh(source) {
            if let value = progress.catalog { catalog = value }
        }
        let result = try #require(catalog)
        #expect(result.movies.first?.title == "Heat")
        #expect(result.categories.contains { $0.kind == .movie })
        #expect(result.channels.count == 2)
        #expect(await repository.cache.load(source.id)?.movies.count == 1, "the cache keeps the films")
    }

    // MARK: EPG

    static let xmltv = """
    <?xml version="1.0" encoding="UTF-8"?>
    <tv>
      <channel id="TF1.fr"><display-name>TF1</display-name></channel>
      <channel id="France2.fr"><display-name>France 2</display-name></channel>
      <programme start="START" stop="MID" channel="TF1.fr"><title>Le 13h</title><desc>Journal</desc><category>Info</category></programme>
      <programme start="MID" stop="END" channel="TF1.fr"><title>Film</title></programme>
      <programme start="START" stop="END" channel="France2.fr"><title>Magazine</title></programme>
    </tv>
    """

    @Test func epgRefreshAndCache() async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        let now = Date.now
        let body = Self.xmltv
            .replacingOccurrences(of: "START", with: formatter.string(from: now.addingTimeInterval(-1_800)))
            .replacingOccurrences(of: "MID", with: formatter.string(from: now.addingTimeInterval(1_800)))
            .replacingOccurrences(of: "END", with: formatter.string(from: now.addingTimeInterval(5_400)))
        let host = StubURLProtocol.uniqueHost("epg")
        StubURLProtocol.register(host: host) { _ in .text(body) }
        defer { StubURLProtocol.unregister(host: host) }
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        let repository = EPGRepository(directories: directories, credentials: InMemoryCredentialStore(), session: StubURLProtocol.session())

        let source = Source(id: "epg-src", name: "Nova", kind: .m3uURL, serverURL: URL(string: "https://\(host)/list.m3u"), epgTimeShiftHours: 1)
        await #expect(throws: SourceError.noGuide) { try await repository.refresh(source, playlistEPGURLs: []) }
        let guide = try await repository.refresh(source, playlistEPGURLs: [URL(string: "https://\(host)/epg.xml")!])
        #expect(guide.channelCount == 2)
        #expect(guide.programCount == 3)
        // +1 h time shift: the programme that started 30 min ago now starts in 30 min.
        let (current, next) = guide.nowAndNext(forEPGID: "tf1.fr", at: now)
        #expect(current == nil)
        #expect(next?.title == "Le 13h")
        let group = ChannelGroup(id: "france 2", name: "France 2", variants: [])
        #expect(guide.resolveEPGID(for: group) == "france2.fr")

        let reopened = EPGRepository(directories: directories, credentials: InMemoryCredentialStore(), session: StubURLProtocol.session())
        let cached = await reopened.cachedGuide(for: [source])
        #expect(cached.programCount == 3)
        #expect(await reopened.lastFetched(source.id) != nil)
        let demo = await reopened.cachedGuide(for: [DemoContent.makeSource()])
        #expect(demo.channelCount > 0)
    }

    // MARK: Metadata

    @Test func metadataIsCachedAndCoalesced() async throws {
        let host = "api.themoviedb.org"
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        let disabled = MetadataRepository(directories: directories, credentials: InMemoryCredentialStore())
        #expect(await disabled.isEnabled == false)
        let title = MediaTitle(id: TitleID(kind: .movie, normalizedTitle: "heat", year: 1995), kind: .movie, title: "Heat", year: 1995, variants: [])
        #expect(await disabled.metadata(for: title) == nil)

        // TMDB host stub (only this test registers it).
        StubURLProtocol.register(host: host) { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/search/movie") {
                Thread.sleep(forTimeInterval: 0.1)
                let query = request.queryValue("query") ?? ""
                if query == "Heat" {
                    return .json(#"{"results":[{"id":949,"title":"Heat","original_title":"Heat","release_date":"1995-12-15","popularity":50}]}"#)
                }
                return .json(#"{"results":[]}"#)
            }
            if path.hasSuffix("/movie/949") {
                return .json(#"{"id":949,"title":"Heat","overview":"Un braqueur et un flic.","runtime":170,"release_date":"1995-12-15","vote_average":7.9,"genres":[{"id":28,"name":"Action"}],"credits":{"cast":[{"id":1158,"name":"Al Pacino","character":"Vincent Hanna","profile_path":"/a.jpg"}],"crew":[{"id":638,"name":"Michael Mann","job":"Director"}]},"images":{"backdrops":[],"logos":[],"posters":[]},"videos":{"results":[]},"release_dates":{"results":[]}}"#)
            }
            if path == "/3/trending/movie/week" {
                Thread.sleep(forTimeInterval: 0.05)
                return .json(#"{"results":[{"id":949,"title":"Heat","release_date":"1995-12-15","original_language":"en"}]}"#)
            }
            return .text("", status: 404)
        }
        defer { StubURLProtocol.unregister(host: host) }
        let credentials = InMemoryCredentialStore(secrets: [CredentialKeys.tmdb: "0123456789abcdef0123456789abcdef"])
        let repository = MetadataRepository(directories: directories, credentials: credentials, session: StubURLProtocol.session())
        #expect(await repository.isEnabled)
        async let first = repository.metadata(for: title)
        async let second = repository.metadata(for: title)
        let (a, b) = await (first, second)
        #expect(a?.tmdbID == 949)
        #expect(b?.tmdbID == 949)
        #expect(a?.directors == ["Michael Mann"])
        let afterFirst = StubURLProtocol.requestCount(host: host)
        #expect(afterFirst == 2, "search + details, coalesced")

        let reopened = MetadataRepository(directories: directories, credentials: credentials, session: StubURLProtocol.session())
        #expect(await reopened.metadata(for: title)?.title == "Heat")
        #expect(StubURLProtocol.requestCount(host: host) == afterFirst, "served from disk")

        let unknown = MediaTitle(id: TitleID(kind: .movie, normalizedTitle: "zzz", year: nil), kind: .movie, title: "Zzz", year: nil, variants: [])
        #expect(await repository.metadata(for: unknown) == nil)
        let afterMiss = StubURLProtocol.requestCount(host: host)
        #expect(await repository.metadata(for: unknown) == nil)
        #expect(StubURLProtocol.requestCount(host: host) == afterMiss, "negative result cached")
        #expect(await repository.metadata(for: unknown, tmdbID: 949)?.title == "Heat")
        #expect(StubURLProtocol.requestCount(host: host) == afterMiss, "a later provider ID bypasses the cached search miss")

        async let firstTrend = repository.weeklyTrending(for: .movie)
        async let secondTrend = repository.weeklyTrending(for: .movie)
        let (chart, sharedChart) = await (firstTrend, secondTrend)
        #expect(chart.map(\.id) == [949])
        #expect(sharedChart == chart)
        #expect(await repository.weeklyTrending(for: .movie) == chart)
        #expect(StubURLProtocol.requestCount(host: host) == afterMiss + 1, "one weekly chart request")

        // TMDB unreachable: the failed lookup is not cached, but it is not retried on every
        // appearance either during the cooldown.
        StubURLProtocol.register(host: host) { _ in .text("", status: 503) }
        let ronin = MediaTitle(id: TitleID(kind: .movie, normalizedTitle: "ronin", year: 1998), kind: .movie, title: "Ronin", year: 1998, variants: [])
        #expect(await repository.metadata(for: ronin) == nil)
        let afterFailure = StubURLProtocol.requestCount(host: host)
        #expect(afterFailure > 0)
        for _ in 0..<4 { #expect(await repository.metadata(for: ronin) == nil) }
        #expect(StubURLProtocol.requestCount(host: host) == afterFailure, "failure cooldown")
        #expect(!FileManager.default.fileExists(atPath: directories.metadataCacheDirectory
            .appending(path: "v2-title-\(ronin.id.rawValue).json").path), "failures are never persisted")

        try credentials.setSecret(nil, named: CredentialKeys.tmdb)
        await repository.reload()
        #expect(await repository.isEnabled == false)
        #expect(await repository.metadata(for: title) == nil)
        #expect(await repository.weeklyTrending(for: .movie).isEmpty)
    }

    @Test func m3uDetailsComeFromTheCatalog() async throws {
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        let details = DetailRepository(directories: directories, credentials: InMemoryCredentialStore(), session: StubURLProtocol.session())
        let source = F.source(F.a)
        let movie = F.movie(F.a, "1", "Heat", year: 1995, backdrop: "heat.jpg", plot: "Plot", genres: ["Action"], rating: 8)
        let detail = try await details.movieDetail(movie, source: source)
        #expect(detail.plot == "Plot")
        #expect(detail.backdropURLs == [F.url("heat.jpg")])
        let series = F.series(F.a, "s", "Dark", seasons: F.seasons(series: "s", source: F.a, counts: [2, 1]))
        let seriesDetail = try await details.seriesDetail(series, source: source)
        #expect(seriesDetail.seasons.map(\.episodes.count) == [2, 1])
    }
}
