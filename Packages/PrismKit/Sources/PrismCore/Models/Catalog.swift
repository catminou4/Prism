import Foundation

/// One concrete, playable/browsable offer of a title from a given source.
/// The same film can exist several times (different sources, 4K/HD, VF/VOSTFR…):
/// the UI lets the user choose between variants ("Choisir la source").
public enum MediaVariant: Identifiable, Sendable, Hashable {
    case movie(Movie)
    case series(Series)

    public var id: ContentID {
        switch self {
        case .movie(let m): m.id
        case .series(let s): s.id
        }
    }
    public var sourceID: SourceID {
        switch self {
        case .movie(let m): m.sourceID
        case .series(let s): s.sourceID
        }
    }
    public var quality: VideoQuality {
        switch self {
        case .movie(let m): m.quality
        case .series(let s): s.quality
        }
    }
    public var tags: [String] {
        switch self {
        case .movie(let m): m.tags
        case .series(let s): s.tags
        }
    }
    public var rawName: String {
        switch self {
        case .movie(let m): m.rawName
        case .series(let s): s.rawName
        }
    }
    public var title: String {
        switch self {
        case .movie(let movie): movie.title
        case .series(let series): series.title
        }
    }
    public var movie: Movie? { if case .movie(let m) = self { m } else { nil } }
    public var series: Series? { if case .series(let s) = self { s } else { nil } }
}

/// A movie or series grouped across all its variants.
public struct MediaTitle: Identifiable, Sendable, Hashable {
    public var id: TitleID
    /// `.movie` or `.series`.
    public var kind: MediaKind
    public var title: String
    public var year: Int?
    /// Sorted best first (enabled source order, then quality desc).
    public var variants: [MediaVariant]
    public var posterURL: URL?
    public var backdropURL: URL?
    public var plot: String?
    public var genres: [String]
    public var rating: Double?
    public var addedAt: Date?
    /// Union of category IDs of all variants.
    public var categoryIDs: Set<String>
    public var isAdult: Bool

    public init(id: TitleID, kind: MediaKind, title: String, year: Int?, variants: [MediaVariant], posterURL: URL? = nil, backdropURL: URL? = nil, plot: String? = nil, genres: [String] = [], rating: Double? = nil, addedAt: Date? = nil, categoryIDs: Set<String> = [], isAdult: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.year = year
        self.variants = variants
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.plot = plot
        self.genres = genres
        self.rating = rating
        self.addedAt = addedAt
        self.categoryIDs = categoryIDs
        self.isAdult = isAdult
    }

    public var primary: MediaVariant? { variants.first }
    public var bestQuality: VideoQuality { variants.map(\.quality).max() ?? .unknown }
}

/// A live channel grouped across variants ("TF1", "TF1 HD", "FR: TF1 4K" from 2 sources…).
public struct ChannelGroup: Identifiable, Sendable, Hashable {
    /// Normalized channel name key.
    public var id: String
    public var name: String
    public var logoURL: URL?
    public var number: Int?
    public var epgID: String?
    /// Sorted best first.
    public var variants: [Channel]
    public var categoryIDs: Set<String>
    public var isAdult: Bool

    public init(id: String, name: String, logoURL: URL? = nil, number: Int? = nil, epgID: String? = nil, variants: [Channel], categoryIDs: Set<String> = [], isAdult: Bool = false) {
        self.id = id
        self.name = name
        self.logoURL = logoURL
        self.number = number
        self.epgID = epgID
        self.variants = variants
        self.categoryIDs = categoryIDs
        self.isAdult = isAdult
    }

    public var primary: Channel? { variants.first }
    public var hasCatchup: Bool { variants.contains { $0.catchup != nil } }
}

/// Categories with the same (normalized) name merged across sources.
public struct CategoryGroup: Identifiable, Sendable, Hashable {
    /// `<kind>:<normalized name>`
    public var id: String
    public var kind: MediaKind
    public var name: String
    public var categoryIDs: [String]
    public var itemCount: Int
    public var isAdult: Bool
    public var sortIndex: Int

    public init(id: String, kind: MediaKind, name: String, categoryIDs: [String], itemCount: Int, isAdult: Bool = false, sortIndex: Int = 0) {
        self.id = id
        self.kind = kind
        self.name = name
        self.categoryIDs = categoryIDs
        self.itemCount = itemCount
        self.isAdult = isAdult
        self.sortIndex = sortIndex
    }
}
