import PrismCore

/// The episode list of one edition. Concrete identifiers are used for progress;
/// season and episode numbers locate the equivalent streams at playback time.
nonisolated struct DetailEpisodeInventory: Sendable {
    let edition: TitleEdition
    let detail: SeriesDetail
    let seasons: [Season]
    let orderedEpisodes: [Episode]
    private let episodeIndices: [ContentID: Int]

    @concurrent static func build(edition: TitleEdition, detail: SeriesDetail) async -> Self {
        var detail = detail
        detail.plot = ProviderSynopsis.cleaned(detail.plot)
        let groups = Dictionary(grouping: detail.seasons, by: \.number)
        let seasons = groups.keys.sorted().compactMap { number -> Season? in
            guard let parts = groups[number], var season = parts.first else { return nil }
            var seen: Set<Int> = []
            season.episodes = parts.flatMap(\.episodes).filter {
                $0.season == number && $0.seriesID == edition.id && $0.sourceID == edition.source.id
            }.sorted {
                $0.number != $1.number ? $0.number < $1.number : $0.id < $1.id
            }.filter { seen.insert($0.number).inserted }
            return season.episodes.isEmpty ? nil : season
        }
        let episodes = seasons.flatMap(\.episodes)
        return Self(
            edition: edition, detail: detail, seasons: seasons, orderedEpisodes: episodes,
            episodeIndices: Dictionary(episodes.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        )
    }

    func latestProgress(in progress: [ContentID: PlaybackProgress]) -> PlaybackProgress? {
        let older: (PlaybackProgress, PlaybackProgress) -> Bool = { first, second in
            first.updatedAt == second.updatedAt ? first.contentID < second.contentID : first.updatedAt < second.updatedAt
        }
        if progress.count < orderedEpisodes.count {
            return progress.values.lazy.filter { episodeIndices[$0.contentID] != nil }.max(by: older)
        }
        return orderedEpisodes.lazy.compactMap { progress[$0.id] }.max(by: older)
    }

    func nextAvailableEpisode(after id: ContentID) -> Episode? {
        guard let index = episodeIndices[id], orderedEpisodes.indices.contains(index + 1) else { return nil }
        return orderedEpisodes[index + 1]
    }

    func nextEpisode(after progress: PlaybackProgress?, isWatched: (ContentID) -> Bool) -> Episode? {
        guard let first = orderedEpisodes.first else { return nil }
        if let progress, let index = episodeIndices[progress.contentID] {
            let previous = orderedEpisodes[index]
            if !progress.isFinished { return previous }
            if let next = orderedEpisodes.dropFirst(index + 1).first(where: { !isWatched($0.id) }) {
                return next
            }
        }
        return orderedEpisodes.first { $0.season > 0 && !isWatched($0.id) }
            ?? orderedEpisodes.first { !isWatched($0.id) }
            ?? first
    }
}
