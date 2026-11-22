import Foundation
import Observation
import PrismCore
import PrismData

/// Hero artwork and synopsis from the provider and TMDB, shared by the visible page and its preload.
@MainActor
@Observable
final class HeroArtworkStore {
    struct Entry {
        var metadata: TMDBMetadata?
        var providerDetail: MovieDetail?
        var synopsis: String?
        /// TMDB was consulted (it is skipped while no key is set).
        var usedMetadata: Bool
    }

    private(set) var entries: [TitleID: Entry] = [:]
    @ObservationIgnored private var running: [Request: Resolution] = [:]

    private struct Request: Hashable, Sendable {
        let id: TitleID
        let usesMetadata: Bool
    }

    private struct Resolution {
        let task: Task<Void, Never>
        var waiters: Set<UUID> = []
    }

    func entry(for id: TitleID) -> Entry? { entries[id] }

    /// Stops speculatively resolving a title if the last interested view goes away.
    func resolve(_ title: MediaTitle, app: AppModel) async {
        let request = Request(id: title.id, usesMetadata: app.isMetadataEnabled)
        guard !Task.isCancelled, entries[request.id]?.usedMetadata != request.usesMetadata else { return }
        if running[request] == nil {
            running[request] = Resolution(task: Task { await self.load(title, app: app, usesMetadata: request.usesMetadata) })
        }
        guard let task = running[request]?.task else { return }
        let waiter = UUID()
        running[request]?.waiters.insert(waiter)
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor in self.release(request, waiter: waiter, cancelled: true) }
        }
        release(request, waiter: waiter, cancelled: Task.isCancelled)
    }

    private func release(_ request: Request, waiter: UUID, cancelled: Bool) {
        guard running[request]?.waiters.remove(waiter) != nil,
              let resolution = running[request], resolution.waiters.isEmpty else { return }
        running[request] = nil
        if cancelled { resolution.task.cancel() }
    }

    func backdropURLs(for title: MediaTitle) -> [URL] {
        let entry = entries[title.id]
        return [entry?.metadata?.images.backdropURL, title.backdropURL].compactMap { $0 }
            + (entry?.providerDetail?.backdropURLs ?? [])
            + Self.leadVariants(title).compactMap { $0.movie?.backdropURL ?? $0.series?.backdropURL }
    }

    func posterURLs(for title: MediaTitle) -> [URL] {
        [entries[title.id]?.metadata?.images.posterURL, title.posterURL].compactMap { $0 }
            + Self.leadVariants(title).compactMap { $0.movie?.posterURL ?? $0.series?.posterURL }
    }

    static func leadVariants(_ title: MediaTitle) -> ArraySlice<MediaVariant> { title.variants.prefix(12) }

    private func load(_ title: MediaTitle, app: AppModel, usesMetadata: Bool) async {
        guard !Task.isCancelled else { return }
        let lead = Self.leadVariants(title)
        let candidates = [title.plot] + lead.map { $0.movie?.plot ?? $0.series?.plot }
        let initial = await Self.preferredSynopsis(candidates)
        guard !Task.isCancelled else { return }
        var entry = Entry(metadata: entries[title.id]?.metadata, providerDetail: entries[title.id]?.providerDetail,
                          synopsis: initial, usedMetadata: usesMetadata)

        // Provider detail only when the listing lacks what the hero shows (and only for films).
        let providerMovie: (Movie, Source)? = {
            guard title.backdropURL == nil || initial == nil,
                  let movie = lead.lazy.compactMap(\.movie).first(where: { app.source($0.sourceID)?.isEnabled == true }),
                  let source = app.source(movie.sourceID), source.kind == .xtream else { return nil }
            return (movie, source)
        }()
        let metadataRepository = app.metadataRepository, detailRepository = app.detailRepository
        async let metadata: TMDBMetadata? = usesMetadata ? metadataRepository.metadata(for: title) : nil
        async let detail: MovieDetail? = Self.providerDetail(providerMovie, repository: detailRepository)
        let (resolvedMetadata, resolvedDetail) = await (metadata, detail)
        guard !Task.isCancelled else { return }
        entry.metadata = resolvedMetadata ?? entry.metadata
        entry.providerDetail = resolvedDetail ?? entry.providerDetail
        if let enriched = await Self.preferredSynopsis([resolvedMetadata?.overview] + candidates + [resolvedDetail?.plot]) {
            entry.synopsis = enriched
        }
        guard !Task.isCancelled, usesMetadata == app.isMetadataEnabled else { return }
        entries[title.id] = entry
    }

    private static func providerDetail(_ request: (Movie, Source)?, repository: DetailRepository) async -> MovieDetail? {
        guard let request else { return nil }
        return try? await repository.movieDetail(request.0, source: request.1)
    }

    @concurrent private static func preferredSynopsis(_ candidates: [String?]) async -> String? {
        ProviderSynopsis.preferredFrenchOrEnglish(from: candidates)
    }
}
