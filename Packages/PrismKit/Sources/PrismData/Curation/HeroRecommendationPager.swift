import PrismCore

/// Walks the precomputed ranking in bounded batches, cycling only after the catalogue is exhausted.
/// The caller excludes its current window, so small catalogues can loop without duplicates.
public actor HeroRecommendationPager {
    private let scope: CurationScope
    private let catalog: Catalog
    private let index: CurationIndex
    private let recommendations: Recommendations
    private let languages: Set<HomeAudioLanguage>
    private let audioMask: UInt8
    private let dismissed: Set<TitleID>
    private var positions: [MediaKind: Int] = [:]
    private var nextKind = 0

    public init(
        scope: CurationScope, catalog: Catalog, index: CurationIndex, recommendations: Recommendations,
        languages: Set<HomeAudioLanguage>, profile: CurationProfile
    ) {
        self.scope = scope
        self.catalog = catalog
        self.index = index
        self.recommendations = recommendations
        let selected = languages.isEmpty ? HomeAudioLanguage.defaults : languages
        self.languages = selected
        self.audioMask = (selected.contains(.french) ? 1 : 0) | (selected.contains(.english) ? 2 : 0)
        self.dismissed = profile.dismissed
    }

    public func next(excluding excluded: Set<TitleID>, limit: Int = 12) -> [CuratedHighlight] {
        let kinds = scope.kinds.filter { !index.ranking($0).isEmpty }
        let available = kinds.reduce(0) { $0 + index.ranking($1).count }
        guard limit > 0, available > 0 else { return [] }
        var seen = excluded
        var result: [CuratedHighlight] = []
        var scanned = 0
        var scannedByKind: [MediaKind: Int] = [:]
        while scanned < available && result.count < limit && !Task.isCancelled {
            let kind = kinds[nextKind % kinds.count]
            nextKind = (nextKind + 1) % kinds.count
            let ranking = index.ranking(kind)
            guard scannedByKind[kind, default: 0] < ranking.count else { continue }
            scannedByKind[kind, default: 0] += 1
            let position = positions[kind, default: 0] % ranking.count
            positions[kind] = (position + 1) % ranking.count
            scanned += 1
            let itemIndex = Int(ranking[position])
            let signal = index.signals(kind)[itemIndex]
            guard (!index.hasLanguageEvidence || signal.matches(audio: audioMask)),
                  index.facetMember(signal, kind: kind, facet: .discover) else { continue }
            let title = kind == .movie ? catalog.movies[itemIndex] : catalog.series[itemIndex]
            guard !dismissed.contains(title.id), seen.insert(title.id).inserted else { continue }
            var presented = recommendations.named(title)
            if let name = recommendations.localizedName(for: title, in: catalog, languages: languages) {
                presented.title = name
            }
            guard RecommendationBuilder.hasLatinTitle(presented.title) else { continue }
            result.append(CuratedHighlight(title: presented, label: nil))
        }
        return result
    }
}
