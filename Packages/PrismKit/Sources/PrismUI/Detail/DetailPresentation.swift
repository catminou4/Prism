import Foundation
import PrismCore
import PrismData

nonisolated enum DetailPresentation {
    @concurrent static func synopsis(_ candidates: [String?]) async -> String? {
        ProviderSynopsis.preferredFrenchOrEnglish(from: candidates)
    }

    static func alternateSynopsisEdition(in candidates: ArraySlice<TitleEdition>) -> TitleEdition? {
        candidates.first { edition in
            switch edition.edition.key {
            case "VFF", "VFQ", "VF2", "VOSTFR": true
            default: edition.edition.key.split(separator: "+").contains("FR")
            }
        } ?? candidates.first { $0.edition.key.split(separator: "+").contains("EN") }
    }

    static func genreLabel(_ name: String) -> String {
        switch TitleNormalizer.key(name) {
        case "action adventure", "action aventure": "Action et aventure"
        case "sci fi fantasy", "science fiction fantasy": "Science-fiction et fantastique"
        case "war politics", "guerre politique": "Guerre et politique"
        case "science fiction", "scifi", "sci fi": "Science-fiction"
        case "drama", "drame": "Drame"
        case "comedy", "comedie": "Comédie"
        case "mystery", "mystere": "Mystère"
        case "crime", "policier": "Policier"
        case "horror", "horreur": "Horreur"
        case "adventure", "aventure": "Aventure"
        case "fantasy", "fantastique": "Fantastique"
        case "documentary", "documentaire": "Documentaire"
        case "history", "histoire": "Histoire"
        case "family", "familial", "famille": "Famille"
        case "music", "musique": "Musique"
        case "war", "guerre": "Guerre"
        default: name
        }
    }

    @concurrent static func relatedTitles(
        to title: MediaTitle, genres: [String], in catalog: Catalog, recommendations: Recommendations,
        languages: Set<HomeAudioLanguage>
    ) async -> [MediaTitle] {
        let keys = genreKeys(genres)
        guard !keys.isEmpty else { return [] }

        var query = title
        query.genres = genres
        let editorial = recommendations.selection(for: languages)
        let candidates = catalog.related(to: query, limit: 100) + editorial.french + editorial.american + editorial.discoveries
        let demo = !catalog.sources.isEmpty && catalog.sources.allSatisfy(DemoContent.isDemo)
        var seen: Set<TitleID> = [title.id]
        var ranked: [(item: MediaTitle, matches: Int, primary: Bool, order: Int)] = []
        for (index, candidate) in candidates.enumerated() {
            if Task.isCancelled { return [] }
            guard candidate.kind == title.kind, candidate.posterURL != nil,
                  !candidate.isAdult, seen.insert(candidate.id).inserted else { continue }
            let others = Set(genreKeys(candidate.genres))
            let matches = keys.lazy.filter(others.contains).count
            guard matches > 0 else { continue }
            let name = demo ? candidate.title : recommendations.localizedName(for: candidate, in: catalog, languages: languages)
            guard let name else { continue }
            var named = recommendations.named(candidate)
            named.title = name
            ranked.append((named, matches, keys.first.map(others.contains) ?? false, index))
        }
        return ranked.sorted { first, second in
            if first.primary != second.primary { return first.primary }
            if first.matches != second.matches { return first.matches > second.matches }
            return first.order < second.order
        }.prefix(14).map(\.item)
    }

    private static func genreKeys(_ genres: [String]) -> [String] {
        var seen: Set<String> = []
        return genres
            .flatMap { genreLabel($0).components(separatedBy: " et ") }
            .map(TitleNormalizer.key)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
