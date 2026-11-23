import Foundation

/// Turns a parsed M3U playlist into a `SourceCatalog` (live channels, movies, series grouped
/// into seasons, categories). Pure and synchronous: run it off the main actor.
public enum M3UCatalogMapper {
    /// Used when an entry advertises catch-up without a number of days.
    public static let defaultCatchupDays = 1

    static let movieExtensions: Set<String> = ["mp4", "mkv", "avi", "mov", "m4v", "wmv", "webm", "mpg", "mpeg", "flv", "divx", "ogv", "3gp"]
    static let liveExtensions: Set<String> = ["ts", "m3u8", "m3u", "mpd", "php"]

    public static func makeCatalog(from playlist: M3UPlaylist, sourceID: SourceID, now: Date = .now) -> SourceCatalog {
        var builder = CatalogBuilder(sourceID: sourceID)
        var separatorGroup: String?
        for entry in playlist.entries {
            let normalized = TitleNormalizer.normalize(entry.name)
            if normalized.isSeparator {
                separatorGroup = normalized.title.isEmpty ? nil : normalized.title
                continue
            }
            var group = entry.group
            if group?.isEmpty ?? true { group = separatorGroup }
            switch classify(entry, normalized) {
            case .live: builder.addChannel(entry, normalized, group: group)
            case .movie: builder.addMovie(entry, normalized, group: group)
            default: builder.addEpisode(entry, normalized, group: group)
            }
        }
        return SourceCatalog(
            sourceID: sourceID,
            categories: builder.categories,
            channels: builder.channels,
            movies: builder.movies,
            series: builder.finishSeries(),
            account: nil,
            fetchedAt: now
        )
    }

    /// `.live`, `.movie` or `.series` (an episode of a series).
    static func classify(_ entry: M3UEntry, _ name: NormalizedName) -> MediaKind {
        if let type = entry.attributes["tvg-type"]?.lowercased() {
            switch type {
            case "live", "channel", "tv": return .live
            case "movie", "movies", "vod", "film": return .movie
            case "series", "serie", "show", "episode": return .series
            default: break
            }
        }
        switch pathMarker(entry.url) {
        case .series?: return .series
        case .movie?: return .movie
        case .live?: return .live
        default: break
        }
        if name.season != nil, name.episode != nil { return .series }
        let ext = entry.url.pathExtension.lowercased()
        // Live extensions are unambiguous (never in movieExtensions); checking them first
        // skips the four attribute lookups `hasLiveMarkers` costs on every live entry.
        if liveExtensions.contains(ext) { return .live }
        if movieExtensions.contains(ext) { return hasLiveMarkers(entry.attributes) ? .live : .movie }
        return entry.duration > 0 && !hasLiveMarkers(entry.attributes) ? .movie : .live
    }

    /// Catch-up/timeshift attributes turn an otherwise movie-looking entry into a live channel.
    private static func hasLiveMarkers(_ attributes: [String: String]) -> Bool {
        attributes["catchup"] != nil || attributes["timeshift"] != nil
            || attributes["tvg-rec"] != nil || attributes["catchup-days"] != nil
    }

    /// First directory segment of the path naming the content type (`/series/`, `/movie/`, `/live/`…).
    /// Scans `absoluteString` bytes (case-insensitive, no allocation); exotic URLs without
    /// "scheme://" fall back to the Foundation path.
    static func pathMarker(_ url: URL) -> MediaKind? {
        let bytes = url.absoluteString.utf8
        var i = bytes.startIndex
        var hierarchical = false
        while i < bytes.endIndex {
            let byte = bytes[i]
            if byte == 0x3A { // ':' ends the scheme when followed by "//"
                let slash1 = bytes.index(after: i)
                if slash1 < bytes.endIndex, bytes[slash1] == 0x2F {
                    let slash2 = bytes.index(after: slash1)
                    if slash2 < bytes.endIndex, bytes[slash2] == 0x2F {
                        i = bytes.index(after: slash2)
                        hierarchical = true
                    }
                }
                break
            }
            if byte == 0x2F || byte == 0x3F || byte == 0x23 { break } // '/', '?', '#' before ':' → no "scheme://"
            i = bytes.index(after: i)
        }
        guard hierarchical else { return pathMarker(url.path(percentEncoded: true)) }
        // Skip the authority: the path starts at the first '/', ends at '?' or '#'.
        while i < bytes.endIndex {
            let byte = bytes[i]
            if byte == 0x2F { break }
            if byte == 0x3F || byte == 0x23 { return nil }
            i = bytes.index(after: i)
        }
        guard i < bytes.endIndex else { return nil }
        var segment = PackedKey()
        var overflow = false
        var isFirstByte = true
        while i < bytes.endIndex {
            let byte = bytes[i]
            if byte == 0x3F || byte == 0x23 { break }
            if byte == 0x2F {
                if !isFirstByte, !overflow, segment.count > 0, let kind = markerSegments[segment] { return kind }
                segment = PackedKey()
                overflow = false
                isFirstByte = false
                i = bytes.index(after: i)
                continue
            }
            isFirstByte = false
            let lower = byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte
            if !segment.append(lower) { overflow = true }
            i = bytes.index(after: i)
        }
        return nil // the last segment is the file name, never a marker
    }

    /// First directory segment of the path naming the content type (`/series/`, `/movie/`, `/live/`…),
    /// scanned on bytes (case-insensitive, no allocation).
    static func pathMarker(_ path: String) -> MediaKind? {
        var segment = PackedKey()
        var overflow = false
        var isFirstByte = true
        for byte in path.utf8 {
            if byte == 0x2F { // "/"
                if !isFirstByte, !overflow, segment.count > 0, let kind = markerSegments[segment] { return kind }
                segment = PackedKey()
                overflow = false
                isFirstByte = false
                continue
            }
            isFirstByte = false
            let lower = byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte
            if !segment.append(lower) { overflow = true }
        }
        return nil // the last segment is the file name, never a marker
    }

    static let markerSegments: [PackedKey: MediaKind] = [
        PackedKey("series"): .series, PackedKey("movie"): .movie, PackedKey("movies"): .movie,
        PackedKey("vod"): .movie, PackedKey("live"): .live,
    ]

    static func catchup(from attributes: [String: String]) -> Catchup? {
        func int(_ key: String) -> Int? {
            guard let raw = attributes[key]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
            return Int(raw) ?? Double(raw).flatMap { Int(exactly: $0.rounded(.towardZero)) }
        }
        let source = attributes["catchup-source"].flatMap { $0.isEmpty ? nil : $0 }
        let days = int("catchup-days") ?? int("timeshift") ?? int("tvg-rec")
        if let rawMode = (attributes["catchup"] ?? attributes["catchup-type"])?.lowercased(), !rawMode.isEmpty {
            let mode: Catchup.Mode
            switch rawMode {
            case "none", "0", "false", "no", "disabled": return nil
            case "append": mode = .append
            case "shift", "timeshift": mode = .shift
            case "flussonic", "flussonic-hls", "flussonic-ts", "fs": mode = .flussonic
            case "xc", "xtream": mode = .xtream
            default: mode = .default
            }
            let resolvedDays = days.flatMap { $0 > 0 ? $0 : nil } ?? defaultCatchupDays
            return Catchup(mode: mode, days: resolvedDays, template: source)
        }
        if let days, days > 0 {
            return Catchup(mode: source == nil ? .shift : .default, days: days, template: source)
        }
        return nil
    }

    static func imageURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty,
              let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "file", url.host() != nil || scheme == "file" else { return nil }
        return url
    }

    /// Provider-declared tags take precedence over regional prefixes in the display name.
    static func mediaTags(_ name: NormalizedName, attributes: [String: String]) -> [String] {
        var tags = name.tags
        for tag in declaredAudio(attributes: attributes).sorted() where !tags.contains(tag) { tags.append(tag) }
        return tags
    }

    static func declaredAudio(attributes: [String: String]) -> Set<String> {
        guard let declared = attributes["audio-language"] ?? attributes["tvg-language"] else { return [] }
        var tags: Set<String> = []
        for part in declared.split(whereSeparator: { ",;|/".contains($0) }).prefix(8) {
            let key = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let tag = declaredLanguages[key] { tags.insert(tag) }
        }
        return tags
    }

    private static let declaredLanguages: [String: String] = [
        "fr": "FRA", "fra": "FRA", "fre": "FRA", "français": "FRA", "french": "FRA", "fr-fr": "FRA",
        "en": "ENG", "eng": "ENG", "english": "ENG", "anglais": "ENG", "en-us": "ENG", "en-gb": "ENG",
        "de": "DEU", "deu": "DEU", "ger": "DEU", "german": "DEU", "deutsch": "DEU",
        "es": "SPA", "spa": "SPA", "spanish": "SPA", "español": "SPA", "es-es": "SPA",
        "it": "ITA", "ita": "ITA", "italian": "ITA", "italiano": "ITA",
        "pt": "POR", "por": "POR", "portuguese": "POR", "português": "POR", "pt-br": "POR",
        "ar": "ARA", "ara": "ARA", "arabic": "ARA", "العربية": "ARA",
        "ja": "JPN", "jpn": "JPN", "japanese": "JPN", "日本語": "JPN",
        "ko": "KOR", "kor": "KOR", "korean": "KOR", "한국어": "KOR",
    ]

    private static let explicitEditions: [String] = [
        "MULTI", "VOSTFR", "VOSTA", "VOST", "SUBFRENCH", "VFF", "VFQ", "VFI", "VF2", "TRUEFRENCH", "FRENCH", "VF", "VO",
    ]

    /// Edition → position in `explicitEditions`; first match wins, as before.
    private static let editionRank: [String: Int] = Dictionary(
        explicitEditions.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first }
    )

    static func audioEdition(tags: [String], declared: Set<String>) -> String? {
        var bestRank = Int.max
        var edition: String?
        for tag in tags {
            if let rank = editionRank[tag], rank < bestRank {
                bestRank = rank
                edition = tag
            }
        }
        if let edition { return edition }
        if !declared.isEmpty { return declared.sorted().joined(separator: "+") }
        let locales = tags.filter { NameTables.trailingCodes.contains($0) || NameTables.longCodes.contains($0) }
        return locales.isEmpty ? nil : Set(locales).sorted().joined(separator: "+")
    }
}

// MARK: - Builder

private struct CategoryKey: Hashable {
    var kind: MediaKind
    var raw: String
}

private struct SeriesBuilder {
    var nativeID: String
    var title: String
    var categoryID: String?
    var isAdult: Bool
    var episodes: [PendingEpisode] = []
}

private struct SeriesEdition: Hashable {
    var year: Int?
    var audio: String?
}

private struct PendingEpisode {
    var nativeID: String
    var rawName: String
    var edition: SeriesEdition
    var quality: VideoQuality
    var tags: [String]
    var season: Int
    var number: Int?
    var title: String?
    var durationSeconds: Int?
    var logoURL: URL?
    var streamURL: URL
    var containerExtension: String?
    var headers: [String: String]
    var order: Int
}

private struct CatalogBuilder {
    let sourceID: SourceID
    var categories: [Category] = []
    var channels: [Channel] = []
    var movies: [Movie] = []
    private var categoryLookup: [CategoryKey: (id: String, isAdult: Bool)] = [:]
    private var categoryCounters: [MediaKind: Int] = [:]
    private var usedIDs: [MediaKind: Set<String>] = [:]
    private var series: [String: SeriesBuilder] = [:]
    private var seriesOrder: [String] = []
    private var episodeCounter = 0
    private var lastCategory: (kind: MediaKind, raw: String, value: (id: String, isAdult: Bool))?

    init(sourceID: SourceID) {
        self.sourceID = sourceID
    }

    mutating func category(kind: MediaKind, raw: String?) -> (id: String, isAdult: Bool)? {
        guard let raw, !raw.isEmpty else { return nil }
        // Consecutive entries usually share their group.
        if let last = lastCategory, last.kind == kind, last.raw == raw { return last.value }
        let key = CategoryKey(kind: kind, raw: raw)
        if let existing = categoryLookup[key] {
            lastCategory = (kind, raw, existing)
            return existing
        }
        let index = categoryCounters[kind, default: 0]
        categoryCounters[kind] = index + 1
        let isAdult = TitleNormalizer.isAdult(raw)
        let category = Category(
            sourceID: sourceID, kind: kind, nativeID: StableHash.hex(raw),
            name: TitleNormalizer.cleanCategoryName(raw), rawName: raw, isAdult: isAdult, sortIndex: index
        )
        categories.append(category)
        let value = (id: category.id, isAdult: isAdult)
        categoryLookup[key] = value
        lastCategory = (kind, raw, value)
        return value
    }

    /// Deterministic ID from the URL; duplicates (same URL listed twice) get "-2", "-3"…
    mutating func uniqueID(_ base: String, kind: MediaKind) -> String {
        if usedIDs[kind, default: []].insert(base).inserted { return base }
        var suffix = 2
        while true {
            let candidate = "\(base)-\(suffix)"
            if usedIDs[kind, default: []].insert(candidate).inserted { return candidate }
            suffix += 1
        }
    }

    mutating func addChannel(_ entry: M3UEntry, _ n: NormalizedName, group: String?) {
        let category = category(kind: .live, raw: group)
        let attributes = entry.attributes
        let numberString = attributes["tvg-chno"] ?? attributes["channel-number"] ?? attributes["tvg-num"]
        let number = numberString.flatMap { Int($0) }
        let epgID = attributes["tvg-id"].flatMap { $0.isEmpty ? nil : $0 }
        let name = n.title.isEmpty ? entry.name : n.title
        let channel = Channel(
            sourceID: sourceID,
            nativeID: uniqueID(StableHash.hex(entry.url.absoluteString), kind: .live),
            name: name,
            rawName: entry.name,
            number: number,
            logoURL: M3UCatalogMapper.imageURL(attributes["tvg-logo"]),
            categoryID: category?.id,
            epgID: epgID,
            streamURL: entry.url,
            quality: n.quality,
            tags: n.tags,
            catchup: M3UCatalogMapper.catchup(from: attributes),
            isAdult: (category?.isAdult ?? false) || TitleNormalizer.isAdultName(n),
            httpHeaders: entry.headers
        )
        channels.append(channel)
    }

    mutating func addMovie(_ entry: M3UEntry, _ n: NormalizedName, group: String?) {
        let category = category(kind: .movie, raw: group)
        let ext = entry.url.pathExtension.lowercased()
        let movie = Movie(
            sourceID: sourceID,
            nativeID: uniqueID(StableHash.hex(entry.url.absoluteString), kind: .movie),
            title: n.title.isEmpty ? entry.name : TitleRefinement.refine(n.title),
            rawName: entry.name,
            year: n.year,
            posterURL: M3UCatalogMapper.imageURL(entry.attributes["tvg-logo"]),
            durationSeconds: entry.duration > 0 ? entry.duration : nil,
            categoryID: category?.id,
            streamURL: entry.url,
            containerExtension: ext.isEmpty ? nil : ext,
            quality: n.quality,
            tags: M3UCatalogMapper.mediaTags(n, attributes: entry.attributes),
            isAdult: (category?.isAdult ?? false) || TitleNormalizer.isAdultName(n),
            httpHeaders: entry.headers
        )
        movies.append(movie)
    }

    mutating func addEpisode(_ entry: M3UEntry, _ n: NormalizedName, group: String?) {
        let category = category(kind: .series, raw: group)
        let showKey = (n.key.isEmpty ? TitleNormalizer.key(entry.name) : n.key) + "|" + (group ?? "")
        let logo = M3UCatalogMapper.imageURL(entry.attributes["tvg-logo"])
        if series[showKey] == nil {
            series[showKey] = SeriesBuilder(
                nativeID: StableHash.hex(showKey),
                title: n.title.isEmpty ? entry.name : TitleRefinement.refine(n.title),
                categoryID: category?.id,
                isAdult: (category?.isAdult ?? false) || TitleNormalizer.isAdultName(n)
            )
            seriesOrder.append(showKey)
        }
        let ext = entry.url.pathExtension.lowercased()
        let declared = M3UCatalogMapper.declaredAudio(attributes: entry.attributes)
        let tags = n.tags + declared.sorted().filter { !n.tags.contains($0) }
        let episode = PendingEpisode(
            nativeID: uniqueID(StableHash.hex(entry.url.absoluteString), kind: .episode),
            rawName: entry.name,
            edition: SeriesEdition(year: n.year, audio: M3UCatalogMapper.audioEdition(tags: tags, declared: declared)),
            quality: n.quality,
            tags: tags,
            season: n.season ?? 1,
            number: n.episode,
            title: n.episodeTitle,
            durationSeconds: entry.duration > 0 ? entry.duration : nil,
            logoURL: logo,
            streamURL: entry.url,
            containerExtension: ext.isEmpty ? nil : ext,
            headers: entry.headers,
            order: episodeCounter
        )
        episodeCounter += 1
        series[showKey]?.episodes.append(episode)
    }

    func finishSeries() -> [Series] {
        seriesOrder.flatMap { key -> [Series] in
            guard let builder = series[key] else { return [] }
            return offers(for: builder.episodes).enumerated().compactMap { index, offer in
                guard let first = offer.episodes.first else { return nil }
                let suffix = "\(offer.edition.year ?? 0)|\(offer.edition.audio ?? "")"
                let nativeID = index == 0 ? builder.nativeID : "\(builder.nativeID)-\(StableHash.hex(suffix))"
                return makeSeries(builder, nativeID: nativeID, year: offer.edition.year, episodes: offer.episodes, first: first)
            }
        }
    }

    /// A missing hint may inherit the only known edition. When several versions exist, keep it separate.
    func offers(for episodes: [PendingEpisode]) -> [(edition: SeriesEdition, episodes: [PendingEpisode])] {
        guard let first = episodes.first else { return [] }
        if episodes.dropFirst().allSatisfy({ $0.edition == first.edition }) { return [(first.edition, episodes)] }

        let years = Set(episodes.lazy.compactMap { $0.edition.year })
        let fallbackYear = years.count == 1 ? years.first : nil
        var audioByYear: [Int?: Set<String>] = [:]
        for episode in episodes {
            if let audio = episode.edition.audio { audioByYear[episode.edition.year ?? fallbackYear, default: []].insert(audio) }
        }
        var positions: [SeriesEdition: Int] = [:]
        var offers: [(edition: SeriesEdition, episodes: [PendingEpisode])] = []
        for episode in episodes {
            let year = episode.edition.year ?? fallbackYear
            let possibleAudio = audioByYear[year]
            let audio = episode.edition.audio ?? (possibleAudio?.count == 1 ? possibleAudio?.first : nil)
            let edition = SeriesEdition(year: year, audio: audio)
            if let index = positions[edition] {
                offers[index].episodes.append(episode)
            } else {
                positions[edition] = offers.count
                offers.append((edition, [episode]))
            }
        }
        return offers
    }

    func makeSeries(_ builder: SeriesBuilder, nativeID: String, year: Int?, episodes: [PendingEpisode], first: PendingEpisode) -> Series {
        let seriesID = ContentID(source: sourceID, kind: .series, nativeID: nativeID)
        let posterURL = episodes.lazy.compactMap(\.logoURL).first
        var bySeason: [Int: [PendingEpisode]] = [:]
        var tags = first.tags
        var quality = first.quality
        for episode in episodes {
            bySeason[episode.season, default: []].append(episode)
            quality = max(quality, episode.quality)
            for tag in episode.tags where !tags.contains(tag) { tags.append(tag) }
        }
        let seasons = bySeason.keys.sorted().map { number -> Season in
            var running = 0
            let episodes = (bySeason[number] ?? []).map { pending -> Episode in
                running += 1
                let episodeNumber = pending.number ?? running
                let still = pending.logoURL == posterURL ? nil : pending.logoURL
                return Episode(
                    seriesID: seriesID, sourceID: sourceID, nativeID: pending.nativeID, season: number,
                    number: episodeNumber, title: pending.title ?? "Épisode \(episodeNumber)",
                    durationSeconds: pending.durationSeconds, stillURL: still, streamURL: pending.streamURL,
                    containerExtension: pending.containerExtension, httpHeaders: pending.headers
                )
            }
            .enumerated()
            .sorted { lhs, rhs in
                lhs.element.number != rhs.element.number ? lhs.element.number < rhs.element.number : lhs.offset < rhs.offset
            }
            .map(\.element)
            return Season(number: number, name: "Saison \(number)", episodes: episodes)
        }
        return Series(
            sourceID: sourceID, nativeID: nativeID, title: builder.title, rawName: first.rawName,
            year: year, posterURL: posterURL, categoryID: builder.categoryID,
            quality: quality, tags: tags, isAdult: builder.isAdult, seasons: seasons
        )
    }
}
