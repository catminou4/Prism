import PrismCore

/// Curated shelves for the current playable catalog. Empty editorial shelves can be left out of the UI.
public struct Recommendations: Sendable {
    public static let empty = Recommendations(highlights: [], french: [], american: [], discoveries: [], wellRated: [])

    public let highlights: [MediaTitle]
    public let french: [MediaTitle]
    public let american: [MediaTitle]
    public let discoveries: [MediaTitle]
    public let wellRated: [MediaTitle]
}

public enum RecommendationBuilder {
    /// Resolves editorial entries through the catalog's existing title index. The local fallback
    /// only examines the precomputed rating and artwork pools, so rebuild cost is bounded even for
    /// a catalog with hundreds of thousands of titles. This performs no network or disk work.
    @concurrent
    public static func build(for catalog: Catalog) async -> Recommendations {
        var selected: Set<TitleID> = []
        let french = resolve(EditorialSelection.french, in: catalog, excluding: &selected)
        let american = resolve(EditorialSelection.american, in: catalog, excluding: &selected)
        let discoveries = resolve(EditorialSelection.discoveries, in: catalog, excluding: &selected)

        // Provider ratings power a separate shelf, without implying production country or acclaim.
        let ratedMovies = wellRated(.movie, in: catalog, excluding: selected)
        let ratedSeries = wellRated(.series, in: catalog, excluding: selected)
        let rated = interleaved([ratedMovies, ratedSeries], limit: 24)

        // Promote both places of production and smaller films/shows in the hero. Within each
        // shelf, a backdrop beats an enlarged poster, and a poster beats a generated placeholder.
        var highlights = interleaved([french, american, discoveries].map(artworkFirst), limit: 7)
        var highlighted = Set(highlights.map(\.id))
        for title in artworkFirst(rated) + catalog.featured(limit: 28) where highlights.count < 7 {
            guard !title.isAdult, title.backdropURL != nil || title.posterURL != nil,
                  highlighted.insert(title.id).inserted else { continue }
            highlights.append(title)
        }
        return Recommendations(
            highlights: artworkFirst(highlights), french: french, american: american,
            discoveries: discoveries, wellRated: rated
        )
    }

    private static func resolve(_ entries: [EditorialTitle], in catalog: Catalog, excluding seen: inout Set<TitleID>) -> [MediaTitle] {
        var result: [MediaTitle] = []
        for entry in entries {
            guard let title = entry.match(in: catalog), !title.isAdult,
                  seen.insert(title.id).inserted else { continue }
            result.append(title)
            if result.count == 20 { break }
        }
        return result
    }

    private static func wellRated(_ kind: MediaKind, in catalog: Catalog, excluding seen: Set<TitleID>) -> [MediaTitle] {
        catalog.topRated(kind, limit: 96).filter { title in
            guard let rating = title.rating, (7...10).contains(rating), !title.isAdult,
                  !seen.contains(title.id) else { return false }
            return title.posterURL != nil || title.backdropURL != nil || (title.plot?.utf8.count ?? 0) >= 40
        }
    }

    private static func artworkFirst(_ titles: [MediaTitle]) -> [MediaTitle] {
        titles.filter { $0.backdropURL != nil }
            + titles.filter { $0.backdropURL == nil && $0.posterURL != nil }
            + titles.filter { $0.backdropURL == nil && $0.posterURL == nil }
    }

    private static func interleaved(_ shelves: [[MediaTitle]], limit: Int) -> [MediaTitle] {
        var result: [MediaTitle] = []
        for index in 0..<(shelves.map(\.count).max() ?? 0) {
            for shelf in shelves where index < shelf.count {
                result.append(shelf[index])
                if result.count == limit { return result }
            }
        }
        return result
    }
}

/// Names are the official original title and common localized titles. The first release year
/// disambiguates remakes and unrelated works. A small number of distinctive names can also match
/// an undated playlist entry. Catalog title resolution includes unambiguous variant aliases.
struct EditorialTitle: Sendable {
    let dated: [TitleID]
    let undated: [TitleID]
    let year: Int

    init(_ kind: MediaKind, _ year: Int, _ names: String..., allowUndated: Bool = false) {
        let keys = names.map(TitleNormalizer.key)
        self.year = year
        dated = keys.map { TitleID(kind: kind, normalizedTitle: $0, year: year) }
        undated = allowUndated ? keys.map { TitleID(kind: kind, normalizedTitle: $0, year: nil) } : []
    }

    func match(in catalog: Catalog) -> MediaTitle? {
        if let title = dated.lazy.compactMap({ catalog.title($0) }).first(where: { $0.year == year }) {
            return title
        }
        return undated.lazy.compactMap { catalog.title($0) }.first { $0.year == nil }
    }
}
