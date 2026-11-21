import PrismCore

nonisolated enum AlternateEditionResolver {
    struct Result: Sendable {
        let index: Int
        let option: TitlePlaybackOption?
        let failed: Bool
    }

    /// Keep requests in flight without making each group wait for its slowest response.
    @concurrent static func resolve(
        _ editions: [TitleEdition],
        episode: Episode,
        load: @escaping @Sendable (_ series: Series, _ source: Source) async throws -> SeriesDetail,
        didResolve: @MainActor @Sendable (Result) -> Bool
    ) async {
        let coordinate = EpisodeCoordinate(episode)
        await withTaskGroup(of: Result.self) { group in
            var nextIndex = 0
            while nextIndex < min(editions.count, 4) {
                enqueue(nextIndex, edition: editions[nextIndex], coordinate: coordinate, load: load, in: &group)
                nextIndex += 1
            }
            while let result = await group.next() {
                guard !Task.isCancelled, await didResolve(result) else {
                    group.cancelAll()
                    return
                }
                if nextIndex < editions.count {
                    enqueue(nextIndex, edition: editions[nextIndex], coordinate: coordinate, load: load, in: &group)
                    nextIndex += 1
                }
            }
        }
    }

    private static func enqueue(
        _ index: Int, edition: TitleEdition, coordinate: EpisodeCoordinate,
        load: @escaping @Sendable (Series, Source) async throws -> SeriesDetail, in group: inout TaskGroup<Result>
    ) {
        _ = group.addTaskUnlessCancelled {
            guard let series = edition.variant.series else { return Result(index: index, option: nil, failed: false) }
            do {
                let detail = try await load(series, edition.source)
                let option = option(in: detail, edition: edition, coordinate: coordinate)
                return Result(index: index, option: option, failed: false)
            } catch {
                return Result(index: index, option: nil, failed: true)
            }
        }
    }

    static func option(in detail: SeriesDetail, edition: TitleEdition, coordinate: EpisodeCoordinate) -> TitlePlaybackOption? {
        guard detail.seriesID == edition.id else { return nil }
        let match = detail.seasons.lazy
            .filter { $0.number == coordinate.season }
            .flatMap(\.episodes)
            .filter {
                $0.seriesID == edition.id && $0.sourceID == edition.source.id
                    && $0.season == coordinate.season && $0.number == coordinate.number
            }
            .min { $0.id < $1.id }
        return match.flatMap { TitlePlaybackOption(edition: edition, episode: $0) }
    }
}
