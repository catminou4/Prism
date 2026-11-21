import PrismCore

/// The episode list of one edition. Concrete identifiers are used for progress;
/// season and episode numbers locate the equivalent streams at playback time.
nonisolated struct DetailEpisodeInventory: Sendable {
    let edition: TitleEdition
    let detail: SeriesDetail
    let seasons: [Season]
    let orderedEpisodes: [Episode]
    let episodesByID: [ContentID: Episode]

    @concurrent static func build(edition: TitleEdition, detail: SeriesDetail) async -> Self {
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
            episodesByID: Dictionary(episodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        )
    }

    func nextEpisode(after progress: PlaybackProgress?, isWatched: (ContentID) -> Bool) -> Episode? {
        guard let first = orderedEpisodes.first else { return nil }
        if let progress, let previous = episodesByID[progress.contentID] {
            if !progress.isFinished { return previous }
            let coordinate = EpisodeCoordinate(previous)
            if let next = orderedEpisodes.first(where: { EpisodeCoordinate($0) > coordinate && !isWatched($0.id) }) {
                return next
            }
        }
        return orderedEpisodes.first { $0.season > 0 && !isWatched($0.id) }
            ?? orderedEpisodes.first { !isWatched($0.id) }
            ?? first
    }
}
