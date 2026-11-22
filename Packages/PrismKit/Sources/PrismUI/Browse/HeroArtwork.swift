import Foundation
import Observation
import PrismCore
import PrismData
import PrismDesign

/// Artwork and synopsis of the hero pages, resolved once per title and kept for the session.
///
/// IPTV listings rarely carry a backdrop or a plot for films: they come from TMDB and from the
/// provider's detail call. Resolving them when a page appears (one request after the other) left
/// each page on its poster fallback for a second or more, every time the carousel came back to it.
/// The store resolves every page of a hero as soon as it is shown, both sources in parallel, and
/// downloads the chosen backdrops ahead of time.
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
    @ObservationIgnored private var running: [TitleID: Task<Void, Never>] = [:]

    func entry(for id: TitleID) -> Entry? { entries[id] }

    /// Resolves `titles` (in order, a few at a time) and warms their hero artwork for `pixelSize`.
    func warm(_ titles: [MediaTitle], app: AppModel, pixelSize: CGSize) async {
        await withTaskGroup(of: Void.self) { group in
            var pending = titles.makeIterator()
            func next() -> Bool {
                guard let title = pending.next() else { return false }
                group.addTask { await self.resolve(title, app: app, pixelSize: pixelSize) }
                return true
            }
            for _ in 0..<3 where next() {}
            for await _ in group {
                if Task.isCancelled { group.cancelAll(); return }
                _ = next()
            }
        }
    }

    /// Resolves one title (joins a resolution already running).
    func resolve(_ title: MediaTitle, app: AppModel, pixelSize: CGSize) async {
        if let entry = entries[title.id], entry.usedMetadata == app.isMetadataEnabled { return }
        if let task = running[title.id] {
            await task.value
            return
        }
        let task = Task { await self.load(title, app: app, pixelSize: pixelSize) }
        running[title.id] = task
        await task.value
        running[title.id] = nil
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

    private func load(_ title: MediaTitle, app: AppModel, pixelSize: CGSize) async {
        let lead = Self.leadVariants(title)
        let candidates = [title.plot] + lead.map { $0.movie?.plot ?? $0.series?.plot }
        let initial = await Self.preferredSynopsis(candidates)
        let usesMetadata = app.isMetadataEnabled
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
        entries[title.id] = entry

        // The backdrop the page will show, on disk before the carousel gets there.
        if let backdrop = backdropURLs(for: title).first {
            ImagePipeline.shared.warm([backdrop], pixelSize: pixelSize, fitting: .landscapeFill)
        } else if let poster = posterURLs(for: title).first {
            ImagePipeline.shared.warm([poster], pixelSize: pixelSize, fitting: .portraitFit)
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
