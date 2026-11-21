import Foundation

/// Video quality inferred from tags in the stream name or from technical info.
public enum VideoQuality: Int, Codable, Sendable, Hashable, Comparable, CaseIterable {
    case unknown = 0, sd, hd, fhd, uhd

    /// Badge label shown in the UI (Apple TV style: "4K", "HD"…). `nil` when unknown.
    public var badge: String? {
        switch self {
        case .unknown: nil
        case .sd: "SD"
        case .hd: "HD"
        case .fhd: "FHD"
        case .uhd: "4K"
        }
    }

    public static func < (lhs: VideoQuality, rhs: VideoQuality) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct Category: Identifiable, Codable, Sendable, Hashable {
    /// `<sourceID>:<kind>:<nativeID>`
    public var id: String
    public var sourceID: SourceID
    public var kind: MediaKind
    public var nativeID: String
    /// Cleaned display name (prefixes such as "FR |" removed).
    public var name: String
    public var rawName: String
    public var isAdult: Bool
    public var sortIndex: Int

    public init(sourceID: SourceID, kind: MediaKind, nativeID: String, name: String, rawName: String? = nil, isAdult: Bool = false, sortIndex: Int = 0) {
        self.id = "\(sourceID.rawValue):\(kind.rawValue):\(nativeID)"
        self.sourceID = sourceID
        self.kind = kind
        self.nativeID = nativeID
        self.name = name
        self.rawName = rawName ?? name
        self.isAdult = isAdult
        self.sortIndex = sortIndex
    }
}

/// Catch-up / timeshift capability of a live channel.
public struct Catchup: Codable, Sendable, Hashable {
    public enum Mode: String, Codable, Sendable, Hashable {
        /// Xtream `/timeshift/{user}/{pass}/{duration}/{start}/{id}.ts`
        case xtream
        /// M3U `catchup="default"` with `catchup-source` template.
        case `default`
        /// M3U `catchup="append"`: template appended to the stream URL.
        case append
        /// M3U `catchup="shift"`: `?utc={start}&lutc={now}`.
        case shift
        case flussonic
    }

    public var mode: Mode
    public var days: Int
    /// `catchup-source` template (e.g. `?utc={utc}&lutc={lutc}`), when provided.
    public var template: String?

    public init(mode: Mode, days: Int, template: String? = nil) {
        self.mode = mode
        self.days = days
        self.template = template
    }
}

public struct Channel: Identifiable, Codable, Sendable, Hashable {
    public var id: ContentID
    public var sourceID: SourceID
    /// Xtream `stream_id`, or M3U entry key.
    public var nativeID: String
    /// Cleaned display name ("TF1"), see `TitleNormalizer`.
    public var name: String
    public var rawName: String
    public var number: Int?
    public var logoURL: URL?
    public var categoryID: String?
    /// XMLTV channel id (`tvg-id` / `epg_channel_id`).
    public var epgID: String?
    public var streamURL: URL
    /// Fallback URL (e.g. `.ts` when the primary is `.m3u8`).
    public var alternateStreamURL: URL?
    public var quality: VideoQuality
    /// Normalized tags extracted from the raw name (e.g. ["FR", "HEVC"]).
    public var tags: [String]
    public var catchup: Catchup?
    public var isAdult: Bool
    /// Extra HTTP headers (`#EXTVLCOPT:http-user-agent`, `http-referrer`…).
    public var httpHeaders: [String: String]

    public init(
        sourceID: SourceID, nativeID: String, name: String, rawName: String? = nil, number: Int? = nil,
        logoURL: URL? = nil, categoryID: String? = nil, epgID: String? = nil, streamURL: URL,
        alternateStreamURL: URL? = nil, quality: VideoQuality = .unknown, tags: [String] = [],
        catchup: Catchup? = nil, isAdult: Bool = false, httpHeaders: [String: String] = [:]
    ) {
        self.id = ContentID(source: sourceID, kind: .live, nativeID: nativeID)
        self.sourceID = sourceID
        self.nativeID = nativeID
        self.name = name
        self.rawName = rawName ?? name
        self.number = number
        self.logoURL = logoURL
        self.categoryID = categoryID
        self.epgID = epgID
        self.streamURL = streamURL
        self.alternateStreamURL = alternateStreamURL
        self.quality = quality
        self.tags = tags
        self.catchup = catchup
        self.isAdult = isAdult
        self.httpHeaders = httpHeaders
    }
}

public struct Movie: Identifiable, Codable, Sendable, Hashable {
    public var id: ContentID
    public var sourceID: SourceID
    public var nativeID: String
    /// Cleaned title, without year/quality/language tags.
    public var title: String
    public var rawName: String
    public var year: Int?
    public var posterURL: URL?
    public var backdropURL: URL?
    public var plot: String?
    public var genres: [String]
    /// 0…10 scale.
    public var rating: Double?
    public var durationSeconds: Int?
    public var cast: [String]
    public var director: String?
    public var categoryID: String?
    public var streamURL: URL
    /// File extension of the stream (`mp4`, `mkv`…), when known.
    public var containerExtension: String?
    public var quality: VideoQuality
    public var tags: [String]
    public var addedAt: Date?
    public var tmdbID: Int?
    public var trailerURL: URL?
    public var isAdult: Bool
    public var httpHeaders: [String: String]

    public init(
        sourceID: SourceID, nativeID: String, title: String, rawName: String? = nil, year: Int? = nil,
        posterURL: URL? = nil, backdropURL: URL? = nil, plot: String? = nil, genres: [String] = [],
        rating: Double? = nil, durationSeconds: Int? = nil, cast: [String] = [], director: String? = nil,
        categoryID: String? = nil, streamURL: URL, containerExtension: String? = nil,
        quality: VideoQuality = .unknown, tags: [String] = [], addedAt: Date? = nil, tmdbID: Int? = nil,
        trailerURL: URL? = nil, isAdult: Bool = false, httpHeaders: [String: String] = [:]
    ) {
        self.id = ContentID(source: sourceID, kind: .movie, nativeID: nativeID)
        self.sourceID = sourceID
        self.nativeID = nativeID
        self.title = title
        self.rawName = rawName ?? title
        self.year = year
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.plot = plot
        self.genres = genres
        self.rating = rating
        self.durationSeconds = durationSeconds
        self.cast = cast
        self.director = director
        self.categoryID = categoryID
        self.streamURL = streamURL
        self.containerExtension = containerExtension
        self.quality = quality
        self.tags = tags
        self.addedAt = addedAt
        self.tmdbID = tmdbID
        self.trailerURL = trailerURL
        self.isAdult = isAdult
        self.httpHeaders = httpHeaders
    }
}

public struct Episode: Identifiable, Codable, Sendable, Hashable {
    public var id: ContentID
    public var seriesID: ContentID
    public var sourceID: SourceID
    public var nativeID: String
    public var season: Int
    public var number: Int
    public var title: String
    public var plot: String?
    public var durationSeconds: Int?
    public var stillURL: URL?
    public var streamURL: URL
    public var containerExtension: String?
    public var airDate: Date?
    public var rating: Double?
    public var httpHeaders: [String: String]

    public init(
        seriesID: ContentID, sourceID: SourceID, nativeID: String, season: Int, number: Int, title: String,
        plot: String? = nil, durationSeconds: Int? = nil, stillURL: URL? = nil, streamURL: URL,
        containerExtension: String? = nil, airDate: Date? = nil, rating: Double? = nil,
        httpHeaders: [String: String] = [:]
    ) {
        self.id = ContentID(source: sourceID, kind: .episode, nativeID: nativeID)
        self.seriesID = seriesID
        self.sourceID = sourceID
        self.nativeID = nativeID
        self.season = season
        self.number = number
        self.title = title
        self.plot = plot
        self.durationSeconds = durationSeconds
        self.stillURL = stillURL
        self.streamURL = streamURL
        self.containerExtension = containerExtension
        self.airDate = airDate
        self.rating = rating
        self.httpHeaders = httpHeaders
    }
}

public struct Season: Identifiable, Codable, Sendable, Hashable {
    public var id: Int { number }
    public var number: Int
    public var name: String?
    public var posterURL: URL?
    public var overview: String?
    public var episodes: [Episode]

    public init(number: Int, name: String? = nil, posterURL: URL? = nil, overview: String? = nil, episodes: [Episode]) {
        self.number = number
        self.name = name
        self.posterURL = posterURL
        self.overview = overview
        self.episodes = episodes
    }
}

public struct Series: Identifiable, Codable, Sendable, Hashable {
    public var id: ContentID
    public var sourceID: SourceID
    public var nativeID: String
    public var title: String
    public var rawName: String
    public var year: Int?
    public var posterURL: URL?
    public var backdropURL: URL?
    public var plot: String?
    public var genres: [String]
    public var rating: Double?
    public var cast: [String]
    public var director: String?
    public var categoryID: String?
    public var quality: VideoQuality
    public var tags: [String]
    public var addedAt: Date?
    public var tmdbID: Int?
    public var trailerURL: URL?
    public var isAdult: Bool
    /// Known upfront for M3U-derived series; `nil` for Xtream until `SeriesDetail` is loaded.
    public var seasons: [Season]?

    public init(
        sourceID: SourceID, nativeID: String, title: String, rawName: String? = nil, year: Int? = nil,
        posterURL: URL? = nil, backdropURL: URL? = nil, plot: String? = nil, genres: [String] = [],
        rating: Double? = nil, cast: [String] = [], director: String? = nil, categoryID: String? = nil,
        quality: VideoQuality = .unknown, tags: [String] = [], addedAt: Date? = nil, tmdbID: Int? = nil,
        trailerURL: URL? = nil, isAdult: Bool = false, seasons: [Season]? = nil
    ) {
        self.id = ContentID(source: sourceID, kind: .series, nativeID: nativeID)
        self.sourceID = sourceID
        self.nativeID = nativeID
        self.title = title
        self.rawName = rawName ?? title
        self.year = year
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.plot = plot
        self.genres = genres
        self.rating = rating
        self.cast = cast
        self.director = director
        self.categoryID = categoryID
        self.quality = quality
        self.tags = tags
        self.addedAt = addedAt
        self.tmdbID = tmdbID
        self.trailerURL = trailerURL
        self.isAdult = isAdult
        self.seasons = seasons
    }
}

/// Technical stream description (from Xtream `get_vod_info` / player).
public struct StreamTechInfo: Codable, Sendable, Hashable {
    public var videoCodec: String?
    public var width: Int?
    public var height: Int?
    public var frameRate: Double?
    public var bitrateKbps: Int?
    public var audioCodec: String?
    public var audioChannels: Int?
    public var isHDR: Bool

    public init(videoCodec: String? = nil, width: Int? = nil, height: Int? = nil, frameRate: Double? = nil, bitrateKbps: Int? = nil, audioCodec: String? = nil, audioChannels: Int? = nil, isHDR: Bool = false) {
        self.videoCodec = videoCodec
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.bitrateKbps = bitrateKbps
        self.audioCodec = audioCodec
        self.audioChannels = audioChannels
        self.isHDR = isHDR
    }

    public var quality: VideoQuality {
        guard let height else { return .unknown }
        switch height {
        case 1600...: return .uhd
        case 1000...: return .fhd
        case 700...: return .hd
        default: return .sd
        }
    }
}

/// Lazily loaded movie details (Xtream `get_vod_info`, TMDB enrichment).
public struct MovieDetail: Codable, Sendable, Hashable {
    public var movieID: ContentID
    public var plot: String?
    public var cast: [String]
    public var director: String?
    public var genres: [String]
    public var backdropURLs: [URL]
    public var durationSeconds: Int?
    public var releaseDate: Date?
    public var rating: Double?
    public var country: String?
    public var trailerURL: URL?
    public var tech: StreamTechInfo?
    public var tmdbID: Int?

    public init(movieID: ContentID, plot: String? = nil, cast: [String] = [], director: String? = nil, genres: [String] = [], backdropURLs: [URL] = [], durationSeconds: Int? = nil, releaseDate: Date? = nil, rating: Double? = nil, country: String? = nil, trailerURL: URL? = nil, tech: StreamTechInfo? = nil, tmdbID: Int? = nil) {
        self.movieID = movieID
        self.plot = plot
        self.cast = cast
        self.director = director
        self.genres = genres
        self.backdropURLs = backdropURLs
        self.durationSeconds = durationSeconds
        self.releaseDate = releaseDate
        self.rating = rating
        self.country = country
        self.trailerURL = trailerURL
        self.tech = tech
        self.tmdbID = tmdbID
    }
}

/// Lazily loaded series details (Xtream `get_series_info`).
public struct SeriesDetail: Codable, Sendable, Hashable {
    public var seriesID: ContentID
    public var plot: String?
    public var cast: [String]
    public var director: String?
    public var genres: [String]
    public var backdropURLs: [URL]
    public var releaseDate: Date?
    public var rating: Double?
    public var trailerURL: URL?
    public var seasons: [Season]
    public var tmdbID: Int?

    public init(seriesID: ContentID, plot: String? = nil, cast: [String] = [], director: String? = nil, genres: [String] = [], backdropURLs: [URL] = [], releaseDate: Date? = nil, rating: Double? = nil, trailerURL: URL? = nil, seasons: [Season] = [], tmdbID: Int? = nil) {
        self.seriesID = seriesID
        self.plot = plot
        self.cast = cast
        self.director = director
        self.genres = genres
        self.backdropURLs = backdropURLs
        self.releaseDate = releaseDate
        self.rating = rating
        self.trailerURL = trailerURL
        self.seasons = seasons
        self.tmdbID = tmdbID
    }
}

/// Everything fetched from one source. Cached to disk per source.
public struct SourceCatalog: Codable, Sendable {
    public var sourceID: SourceID
    public var categories: [Category]
    public var channels: [Channel]
    public var movies: [Movie]
    public var series: [Series]
    public var account: XtreamAccount?
    public var fetchedAt: Date

    public init(sourceID: SourceID, categories: [Category] = [], channels: [Channel] = [], movies: [Movie] = [], series: [Series] = [], account: XtreamAccount? = nil, fetchedAt: Date = .now) {
        self.sourceID = sourceID
        self.categories = categories
        self.channels = channels
        self.movies = movies
        self.series = series
        self.account = account
        self.fetchedAt = fetchedAt
    }
}

/// Unambiguous alias for `Category` (which clashes with `ObjectiveC.Category` in modules
/// importing Foundation). Prefer `ContentCategory` outside PrismCore.
public typealias ContentCategory = Category
