import Foundation

/// Lenient decoders for Xtream Codes `player_api.php` responses → PrismCore models.
/// Pure functions (no I/O): every element is decoded independently, broken ones are skipped.
public enum XtreamDecoder {
    static let genreSeparators: Set<Character> = [",", "/", "|", ";"]

    // MARK: Account

    public static func account(_ data: Data, credentials: XtreamCredentials, now: Date = .now) throws -> XtreamAccount {
        guard let root = JSONObject(try json(data)) else { throw XtreamError.unauthorized }
        guard let user = root.object("user_info") else { throw XtreamError.unauthorized }
        if let auth = user.int("auth"), auth == 0 { throw XtreamError.unauthorized }
        if user.int("auth") == nil, user.string("status") == nil, user.string("username") == nil { throw XtreamError.unauthorized }

        let status = user.string("status") ?? "Active"
        let expiresAt = user.date("exp_date")
        switch status.lowercased() {
        case "active", "actif", "enabled":
            break
        case "expired", "expiré", "expire":
            throw XtreamError.accountExpired(expiresAt)
        default:
            throw XtreamError.accountDisabled(status)
        }

        let server = root.object("server_info")
        return XtreamAccount(
            username: user.string("username") ?? credentials.username,
            status: status,
            isActive: true,
            isTrial: user.bool("is_trial") ?? false,
            expiresAt: expiresAt,
            createdAt: user.date("created_at"),
            maxConnections: user.int("max_connections"),
            activeConnections: user.int("active_cons", "active_connections"),
            allowedOutputFormats: user.list("allowed_output_formats").map { $0.lowercased() },
            serverTimeZone: server?.string("timezone"),
            serverURL: server.flatMap(serverURL) ?? credentials.server
        )
    }

    static func serverURL(_ info: JSONObject) -> URL? {
        guard let host = info.string("url") else { return nil }
        let scheme = info.string("server_protocol")?.lowercased() == "https" ? "https" : "http"
        // `url` may be "host", "host:port", "//host" or already carry a scheme.
        let string = host.hasPrefix("//") ? "\(scheme):\(host)" : host.contains("://") ? host : "\(scheme)://\(host)"
        // Userinfo in a panel-reported URL is rejected rather than silently dropped.
        guard var components = URLComponents(string: string),
              components.user == nil, components.password == nil,
              components.host != nil else { return nil }
        if components.port == nil, !host.contains("://"),
           let port = scheme == "https" ? (info.string("https_port") ?? info.string("port")) : info.string("port"),
           let number = Int(port), (1...65_535).contains(number),
           !(scheme == "http" && number == 80), !(scheme == "https" && number == 443) {
            components.port = number
        }
        return XtreamCredentials.normalizeServer(components.string ?? string)
    }

    // MARK: Categories

    public static func categories(_ data: Data, kind: MediaKind, sourceID: SourceID) throws -> [Category] {
        let items = try elements(data)
        var result: [Category] = []
        result.reserveCapacity(items.count)
        for element in items {
            guard let obj = JSONObject(element), let id = obj.string("category_id") else { continue }
            let raw = obj.string("category_name") ?? "Sans nom"
            result.append(Category(
                sourceID: sourceID, kind: kind, nativeID: id,
                name: TitleNormalizer.cleanCategoryName(raw), rawName: raw,
                isAdult: TitleNormalizer.isAdult(raw), sortIndex: result.count
            ))
        }
        return result
    }

    // MARK: Live

    public static func liveStreams(
        _ data: Data, sourceID: SourceID, credentials: XtreamCredentials, preferHLS: Bool,
        allowedFormats: [String] = [], adultCategoryIDs: Set<String> = []
    ) throws -> [Channel] {
        try liveStreams(elements(data)[...], sourceID: sourceID, credentials: credentials, preferHLS: preferHLS,
                        allowedFormats: allowedFormats, adultCategoryIDs: adultCategoryIDs)
    }

    /// Maps already-parsed JSON elements → channels. Non-throwing: malformed elements are skipped,
    /// order is preserved. Shared by the sequential entry point and the client's chunked decode.
    static func liveStreams(
        _ items: ArraySlice<Any>, sourceID: SourceID, credentials: XtreamCredentials, preferHLS: Bool,
        allowedFormats: [String] = [], adultCategoryIDs: Set<String> = []
    ) -> [Channel] {
        let formats = Set(allowedFormats.map { $0.lowercased() })
        let canHLS = formats.isEmpty || formats.contains("m3u8") || formats.contains("hls")
        let canTS = formats.isEmpty || formats.contains("ts") || formats.contains("mpegts")
        let primaryIsHLS = (preferHLS && canHLS) || !canTS

        var result: [Channel] = []
        result.reserveCapacity(items.count)
        for element in items {
            guard let obj = JSONObject(element), let id = obj.string("stream_id", "id") else { continue }
            let rawName = obj.string("name", "title") ?? "Chaîne \(id)"
            let n = TitleNormalizer.normalize(rawName)
            let category = categoryNativeID(obj)
            let hls = XtreamURLBuilder.live(credentials, streamID: id, format: .m3u8)
            let ts = XtreamURLBuilder.live(credentials, streamID: id, format: .ts)
            var catchup: Catchup?
            if obj.bool("tv_archive") == true {
                catchup = Catchup(mode: .xtream, days: max(obj.int("tv_archive_duration") ?? 1, 1))
            }
            let isAdult = obj.bool("is_adult") == true
                || category.map { adultCategoryIDs.contains($0) } == true
                || TitleNormalizer.isAdultName(n)
            result.append(Channel(
                sourceID: sourceID,
                nativeID: id,
                name: n.title.isEmpty ? rawName : n.title,
                rawName: rawName,
                number: obj.int("num").flatMap { $0 > 0 ? $0 : nil },
                logoURL: obj.url("stream_icon", "logo"),
                categoryID: category.map { "\(sourceID.rawValue):\(MediaKind.live.rawValue):\($0)" },
                epgID: obj.string("epg_channel_id"),
                streamURL: primaryIsHLS ? hls : ts,
                alternateStreamURL: primaryIsHLS ? (canTS ? ts : nil) : (canHLS ? hls : nil),
                quality: n.quality,
                tags: n.tags,
                catchup: catchup,
                isAdult: isAdult
            ))
        }
        return result
    }

    // MARK: VOD

    public static func vodStreams(
        _ data: Data, sourceID: SourceID, credentials: XtreamCredentials, adultCategoryIDs: Set<String> = []
    ) throws -> [Movie] {
        try vodStreams(elements(data)[...], sourceID: sourceID, credentials: credentials, adultCategoryIDs: adultCategoryIDs)
    }

    /// Maps already-parsed JSON elements → movies. Non-throwing: malformed elements are skipped,
    /// order is preserved. Shared by the sequential entry point and the client's chunked decode.
    static func vodStreams(
        _ items: ArraySlice<Any>, sourceID: SourceID, credentials: XtreamCredentials, adultCategoryIDs: Set<String> = []
    ) -> [Movie] {
        var result: [Movie] = []
        result.reserveCapacity(items.count)
        for element in items {
            guard let obj = JSONObject(element), let id = obj.string("stream_id", "id") else { continue }
            let rawName = obj.string("name", "title") ?? "Film \(id)"
            let n = TitleNormalizer.normalize(rawName)
            let ext = obj.string("container_extension")
            let category = categoryNativeID(obj)
            let year = obj.year("year") ?? obj.year("releaseDate", "releasedate", "release_date") ?? n.year
            result.append(Movie(
                sourceID: sourceID,
                nativeID: id,
                title: n.title.isEmpty ? rawName : TitleRefinement.refine(n.title),
                rawName: rawName,
                year: year,
                posterURL: obj.url("stream_icon", "cover", "cover_big"),
                backdropURL: obj.urls("backdrop_path").first,
                plot: obj.string("plot", "description"),
                genres: obj.list("genre", "genres", separators: genreSeparators),
                rating: rating(obj),
                durationSeconds: obj.int("duration_secs") ?? obj.int("episode_run_time").map { $0 * 60 },
                cast: obj.list("cast", "actors"),
                director: obj.string("director"),
                categoryID: category.map { "\(sourceID.rawValue):\(MediaKind.movie.rawValue):\($0)" },
                streamURL: XtreamURLBuilder.movie(credentials, streamID: id, ext: ext),
                containerExtension: ext?.lowercased(),
                quality: n.quality,
                tags: n.tags,
                addedAt: obj.date("added"),
                tmdbID: obj.int("tmdb", "tmdb_id").flatMap { $0 > 0 ? $0 : nil },
                trailerURL: youtubeURL(obj.string("trailer", "youtube_trailer")),
                isAdult: obj.bool("is_adult") == true || category.map { adultCategoryIDs.contains($0) } == true || TitleNormalizer.isAdultName(n)
            ))
        }
        return result
    }

    // MARK: Series

    public static func series(_ data: Data, sourceID: SourceID, adultCategoryIDs: Set<String> = []) throws -> [Series] {
        try series(elements(data)[...], sourceID: sourceID, adultCategoryIDs: adultCategoryIDs)
    }

    /// Maps already-parsed JSON elements → series. Non-throwing: malformed elements are skipped,
    /// order is preserved. Shared by the sequential entry point and the client's chunked decode.
    static func series(_ items: ArraySlice<Any>, sourceID: SourceID, adultCategoryIDs: Set<String> = []) -> [Series] {
        var result: [Series] = []
        result.reserveCapacity(items.count)
        for element in items {
            guard let obj = JSONObject(element), let id = obj.string("series_id", "id") else { continue }
            let rawName = obj.string("name", "title") ?? "Série \(id)"
            let n = TitleNormalizer.normalize(rawName)
            let category = categoryNativeID(obj)
            result.append(Series(
                sourceID: sourceID,
                nativeID: id,
                title: n.title.isEmpty ? rawName : TitleRefinement.refine(n.title),
                rawName: rawName,
                year: obj.year("year") ?? obj.year("releaseDate", "releasedate", "release_date") ?? n.year,
                posterURL: obj.url("cover", "stream_icon", "cover_big"),
                backdropURL: obj.urls("backdrop_path").first,
                plot: obj.string("plot", "description"),
                genres: obj.list("genre", "genres", separators: genreSeparators),
                rating: rating(obj),
                cast: obj.list("cast", "actors"),
                director: obj.string("director"),
                categoryID: category.map { "\(sourceID.rawValue):\(MediaKind.series.rawValue):\($0)" },
                quality: n.quality,
                tags: n.tags,
                addedAt: obj.date("last_modified", "added"),
                tmdbID: obj.int("tmdb", "tmdb_id").flatMap { $0 > 0 ? $0 : nil },
                trailerURL: youtubeURL(obj.string("youtube_trailer", "trailer")),
                isAdult: obj.bool("is_adult") == true || category.map { adultCategoryIDs.contains($0) } == true || TitleNormalizer.isAdultName(n),
                seasons: nil
            ))
        }
        return result
    }

    // MARK: Details

    public static func movieDetail(_ data: Data, movie: Movie) throws -> MovieDetail {
        guard let root = JSONObject(try json(data)) else { throw XtreamError.decoding("get_vod_info: objet attendu") }
        let info = root.object("info") ?? JSONObject.empty
        let movieData = root.object("movie_data")
        let duration = info.int("duration_secs") ?? LenientValue.hms(info.value(["duration"]))
            ?? info.int("episode_run_time", "runtime").map { $0 * 60 }
        return MovieDetail(
            movieID: movie.id,
            plot: info.string("plot", "description"),
            cast: info.list("cast", "actors"),
            director: info.string("director"),
            genres: info.list("genre", "genres", separators: genreSeparators),
            backdropURLs: info.urls("backdrop_path", "backdrop"),
            durationSeconds: duration.flatMap { $0 > 0 ? $0 : nil },
            releaseDate: info.day("releasedate", "release_date", "releaseDate"),
            rating: rating(info),
            country: info.string("country"),
            trailerURL: youtubeURL(info.string("youtube_trailer", "trailer")),
            tech: tech(info),
            tmdbID: (info.int("tmdb_id", "tmdb") ?? movieData?.int("tmdb_id")).flatMap { $0 > 0 ? $0 : nil }
        )
    }

    public static func seriesDetail(_ data: Data, series: Series, credentials: XtreamCredentials) throws -> SeriesDetail {
        guard let root = JSONObject(try json(data)) else { throw XtreamError.decoding("get_series_info: objet attendu") }
        let info = root.object("info") ?? JSONObject.empty

        var seasonMeta: [Int: JSONObject] = [:]
        for element in root.array("seasons") {
            guard let obj = JSONObject(element), let number = obj.int("season_number", "season") else { continue }
            seasonMeta[number] = obj
        }

        // Episodes: {"1": [...], "2": [...]} or [[...], [...]] or [ep, ep…].
        var raw: [(season: Int?, value: Any)] = []
        let episodesValue = root.raw["episodes"]
        if let dict = episodesValue as? [String: Any] {
            let keys = dict.keys.sorted { (Int($0) ?? .max, $0) < (Int($1) ?? .max, $1) }
            for key in keys {
                let season = Int(key.trimmingCharacters(in: .whitespaces))
                for ep in LenientValue.array(dict[key]) { raw.append((season, ep)) }
            }
        } else if let array = episodesValue as? [Any] {
            for element in array {
                if element is [Any] || (element is [String: Any] && JSONObject(element)?.raw["id"] == nil && JSONObject(element)?.raw["episode_num"] == nil) {
                    for ep in LenientValue.array(element) { raw.append((nil, ep)) }
                } else {
                    raw.append((nil, element))
                }
            }
        }

        var bySeason: [Int: [Episode]] = [:]
        var seenIDs = Set<String>()
        let seriesKey = TitleNormalizer.key(series.title)
        for item in raw {
            guard let ep = JSONObject(item.value), let id = ep.string("id", "stream_id"), seenIDs.insert(id).inserted else { continue }
            let epInfo = ep.object("info") ?? JSONObject.empty
            let season = ep.int("season") ?? item.season ?? epInfo.int("season") ?? 1
            let number = ep.int("episode_num", "episode") ?? epInfo.int("episode_num") ?? ((bySeason[season]?.count ?? 0) + 1)
            let ext = ep.string("container_extension")
            let duration = epInfo.int("duration_secs") ?? LenientValue.hms(epInfo.value(["duration"]))
            let episode = Episode(
                seriesID: series.id,
                sourceID: series.sourceID,
                nativeID: id,
                season: season,
                number: number,
                title: episodeTitle(ep.string("title") ?? epInfo.string("name", "title"), number: number, seriesKey: seriesKey),
                plot: epInfo.string("plot", "overview", "description"),
                durationSeconds: duration.flatMap { $0 > 0 ? $0 : nil },
                stillURL: epInfo.url("movie_image", "cover_big", "still_path", "cover"),
                streamURL: XtreamURLBuilder.episode(credentials, episodeID: id, ext: ext),
                containerExtension: ext?.lowercased(),
                airDate: epInfo.day("releasedate", "release_date", "air_date") ?? ep.date("added"),
                rating: rating(epInfo),
                httpHeaders: [:]
            )
            bySeason[season, default: []].append(episode)
        }

        let seasons = bySeason.keys.sorted().map { number -> Season in
            let meta = seasonMeta[number]
            let episodes = (bySeason[number] ?? []).enumerated().sorted { lhs, rhs in
                lhs.element.number != rhs.element.number ? lhs.element.number < rhs.element.number : lhs.offset < rhs.offset
            }.map(\.element)
            return Season(
                number: number,
                name: meta?.string("name") ?? "Saison \(number)",
                posterURL: meta?.url("cover_big", "cover", "cover_tmdb"),
                overview: meta?.string("overview"),
                episodes: episodes
            )
        }

        return SeriesDetail(
            seriesID: series.id,
            plot: info.string("plot", "description"),
            cast: info.list("cast", "actors"),
            director: info.string("director"),
            genres: info.list("genre", "genres", separators: genreSeparators),
            backdropURLs: info.urls("backdrop_path", "backdrop"),
            releaseDate: info.day("releaseDate", "releasedate", "release_date"),
            rating: rating(info),
            trailerURL: youtubeURL(info.string("youtube_trailer", "trailer")),
            seasons: seasons,
            tmdbID: info.int("tmdb", "tmdb_id").flatMap { $0 > 0 ? $0 : nil }
        )
    }

    // MARK: EPG

    public static func shortEPG(_ data: Data, streamID: String, epgChannelID: String?) throws -> [EPGProgram] {
        let value = try json(data)
        let listings: [Any]
        if let obj = JSONObject(value) {
            listings = obj.array("epg_listings")
        } else {
            listings = LenientValue.array(value)
        }
        var result: [EPGProgram] = []
        for element in listings {
            guard let item = JSONObject(element) else { continue }
            guard let start = item.date("start_timestamp") ?? item.day("start"),
                  let end = item.date("stop_timestamp", "end_timestamp") ?? item.day("end", "stop") else { continue }
            let title = LenientValue.base64Text(item.value(["title"])) ?? ""
            let channel = epgChannelID.flatMap { $0.isEmpty ? nil : $0 } ?? item.string("channel_id", "epg_id") ?? streamID
            result.append(EPGProgram(
                channelID: channel,
                start: start,
                end: max(end, start),
                title: title,
                summary: LenientValue.base64Text(item.value(["description"]))
            ))
        }
        return result.sorted { $0.start < $1.start }
    }

    // MARK: Helpers

    static func json(_ data: Data) throws -> Any {
        guard let first = data.firstIndex(where: { $0 != 0x20 && $0 != 0x0A && $0 != 0x0D && $0 != 0x09 }) else {
            return [Any]()
        }
        do {
            // Some panels prepend whitespace before a UTF-8 BOM.
            var payload = first != data.startIndex && data[first...].starts(with: [0xEF, 0xBB, 0xBF]) ? data[first...] : data
            // Panels behind misconfigured proxies can emit gzip bodies without Content-Encoding
            // (URLSession only decompresses when the header is present). A failed inflate falls
            // back to the raw bytes, preserving the previous parse error.
            if Gzip.isCompressed(payload), let inflated = try? Gzip.decompress(payload) {
                payload = inflated
            }
            return try LenientValue.parse(payload)
        } catch {
            let preview = String(decoding: data[first...].prefix(80), as: UTF8.self)
            throw XtreamError.decoding("JSON invalide : \(preview)")
        }
    }

    /// Top-level array (or dictionary of elements).
    static func elements(_ data: Data) throws -> [Any] {
        let value = try json(data)
        if let dict = value as? [String: Any] {
            if let userInfo = dict["user_info"] {
                if JSONObject(userInfo)?.bool("auth") == false { throw XtreamError.unauthorized }
                throw XtreamError.decoding("Liste attendue, réponse de compte reçue")
            }
            if dict.values.allSatisfy({ $0 is [String: Any] }) { return LenientValue.array(dict) }
            return []
        }
        return LenientValue.array(value)
    }

    static func categoryNativeID(_ obj: JSONObject) -> String? {
        if let id = obj.string("category_id") { return id }
        if let ids = obj.raw["category_ids"] as? [Any], let first = ids.lazy.compactMap({ LenientValue.string($0) }).first { return first }
        return nil
    }

    /// 0…10 scale: `rating` ("7.4", 7.4, "") else `rating_5based` × 2.
    static func rating(_ obj: JSONObject) -> Double? {
        if let r = obj.double("rating"), r > 0, r <= 10 { return r }
        if let r = obj.double("rating_5based"), r > 0, r <= 5 { return r * 2 }
        if let r = obj.double("vote_average"), r > 0, r <= 10 { return r }
        return nil
    }

    /// YouTube id or URL → watch URL.
    static func youtubeURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.lowercased().hasPrefix("http") { return LenientValue.url(raw) }
        let allowed = raw.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard allowed, (6...20).contains(raw.count) else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(raw)")
    }

    /// Episode title without the redundant "Show - S01E02 -" prefix; "Épisode N" when empty.
    static func episodeTitle(_ raw: String?, number: Int, seriesTitle: String) -> String {
        episodeTitle(raw, number: number, seriesKey: TitleNormalizer.key(seriesTitle))
    }

    /// `seriesKey` = `TitleNormalizer.key(seriesTitle)`, hoisted out of per-episode loops.
    static func episodeTitle(_ raw: String?, number: Int, seriesKey: String) -> String {
        guard let raw, !raw.isEmpty else { return "Épisode \(number)" }
        let n = TitleNormalizer.normalize(raw)
        if n.season != nil || n.episode != nil {
            if let title = n.episodeTitle, !title.isEmpty, TitleNormalizer.key(title) != seriesKey { return title }
            if n.key != seriesKey, !n.title.isEmpty, n.episodeTitle != nil { return n.title }
            return "Épisode \(number)"
        }
        if n.key == seriesKey { return "Épisode \(number)" }
        return raw
    }

    static func tech(_ info: JSONObject) -> StreamTechInfo? {
        let video = info.object("video")
        let audio = info.object("audio")
        let bitrate = info.int("bitrate")
        guard video != nil || audio != nil || bitrate != nil else { return nil }
        var frameRate: Double?
        if let rate = video?.string("avg_frame_rate", "r_frame_rate") {
            let parts = rate.split(separator: "/").compactMap { Double($0) }
            if parts.count == 2, parts[1] > 0 { frameRate = (parts[0] / parts[1] * 100).rounded() / 100 } else if parts.count == 1 { frameRate = parts[0] }
            if frameRate == 0 { frameRate = nil }
        }
        let transfer = video?.string("color_transfer")?.lowercased() ?? ""
        let isHDR = transfer.contains("2084") || transfer.contains("b67") || transfer.contains("hlg")
        return StreamTechInfo(
            videoCodec: video?.string("codec_name"),
            width: video?.int("width", "coded_width"),
            height: video?.int("height", "coded_height"),
            frameRate: frameRate,
            bitrateKbps: bitrate.flatMap { $0 > 0 ? $0 : nil } ?? video?.int("bit_rate").map { $0 / 1000 },
            audioCodec: audio?.string("codec_name"),
            audioChannels: audio?.int("channels"),
            isHDR: isHDR
        )
    }
}
