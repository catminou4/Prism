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

    /// One observable cell per title, same narrowing pattern as the import cells in
    /// `AppModel`: the dictionary mutates only when a cell is created (first resolution
    /// for the title), so writing one hero's entry — every carousel advance — invalidates
    /// just that hero's readers instead of every mounted browse page's hero tree.
    /// Evicted entries keep their (empty) cell: cells are tiny, never re-created.
    private var cells: [TitleID: HeroArtworkCell] = [:]
    @ObservationIgnored private var running: [Request: Resolution] = [:]
    /// Insertion order for bounded eviction — hero metadata is re-resolvable, so
    /// oldest-first is enough (a strict LRU would track reads nobody makes).
    @ObservationIgnored private var entryOrder: [TitleID] = []
    private static let maxEntries = 256

    private struct Request: Hashable, Sendable {
        let id: TitleID
        let usesMetadata: Bool
    }

    private struct Resolution {
        let task: Task<Void, Never>
        var waiters: Set<UUID> = []
    }

    /// The cell of one title, created on first use and kept for the session so
    /// readers stay attached to the same instance. Never call during view body
    /// evaluation — reads go through `entry(for:)`, writes through `store(_:for:)`.
    private func cell(for id: TitleID) -> HeroArtworkCell {
        if let cell = cells[id] { return cell }
        let cell = HeroArtworkCell()
        cells[id] = cell
        return cell
    }

    private func entryValue(for id: TitleID) -> Entry? { cells[id]?.entry }

    func entry(for id: TitleID) -> Entry? { cells[id]?.entry }

    /// Kept for tests/tools: a snapshot of every resolved entry. Views should prefer
    /// `entry(for:)` — reading this subscribes to every title's cell.
    var entries: [TitleID: Entry] {
        cells.compactMapValues(\.entry)
    }

    /// Stops speculatively resolving a title if the last interested view goes away.
    func resolve(_ title: MediaTitle, app: AppModel) async {
        let request = Request(id: title.id, usesMetadata: app.isMetadataEnabled)
        guard !Task.isCancelled, entryValue(for: request.id)?.usedMetadata != request.usesMetadata else { return }
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
        let entry = cells[title.id]?.entry
        return [entry?.metadata?.images.backdropURL, title.backdropURL].compactMap { $0 }
            + (entry?.providerDetail?.backdropURLs ?? [])
            + Self.leadVariants(title).compactMap { $0.movie?.backdropURL ?? $0.series?.backdropURL }
    }

    func posterURLs(for title: MediaTitle) -> [URL] {
        [cells[title.id]?.entry?.metadata?.images.posterURL, title.posterURL].compactMap { $0 }
            + Self.leadVariants(title).compactMap { $0.movie?.posterURL ?? $0.series?.posterURL }
    }

    static func leadVariants(_ title: MediaTitle) -> ArraySlice<MediaVariant> { title.variants.prefix(12) }

    private func load(_ title: MediaTitle, app: AppModel, usesMetadata: Bool) async {
        guard !Task.isCancelled else { return }
        let lead = Self.leadVariants(title)
        let candidates = [title.plot] + lead.map { $0.movie?.plot ?? $0.series?.plot }
        let initial = await Self.preferredSynopsis(candidates)
        guard !Task.isCancelled else { return }
        var entry = Entry(metadata: entryValue(for: title.id)?.metadata, providerDetail: entryValue(for: title.id)?.providerDetail,
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
        if entryValue(for: title.id) == nil { entryOrder.append(title.id) }
        cell(for: title.id).entry = entry
        if entryOrder.count > Self.maxEntries {
            let excess = entryOrder.count - Self.maxEntries
            for id in entryOrder.prefix(excess) { cells[id]?.entry = nil }
            entryOrder.removeFirst(excess)
        }
    }

    private static func providerDetail(_ request: (Movie, Source)?, repository: DetailRepository) async -> MovieDetail? {
        guard let request else { return nil }
        return try? await repository.movieDetail(request.0, source: request.1)
    }

    @concurrent private static func preferredSynopsis(_ candidates: [String?]) async -> String? {
        ProviderSynopsis.preferredFrenchOrEnglish(from: candidates)
    }
}

/// One title's resolved hero entry. Splitting entries out of a shared observed
/// dictionary is what narrows observation: a preload resolving title A re-evaluates
/// title A's hero only — the other mounted pages' heroes keep their subscriptions
/// to their own cells.
@MainActor
@Observable
final class HeroArtworkCell {
    var entry: HeroArtworkStore.Entry?
}
