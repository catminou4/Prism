import Foundation
import PrismCore
import PrismData
import PrismDesign
import SwiftUI

struct TitleDetailView: View {
    @Environment(AppModel.self) private var app
    @State private var memo = DetailPageMemo()
    let titleID: TitleID

    var body: some View {
        if let title = app.catalog.title(titleID) {
            let content = memo.content(for: title, app: app)
            TitleDetailContent(title: content.title, editions: content.editions)
                .id(title.id)
        } else {
            ContentUnavailableView("Titre indisponible", systemImage: "film", description: Text("Ce titre ne figure plus dans vos sources actives."))
        }
    }
}

/// The detail page's per-evaluation work that ignores playback state: the display
/// title (editorial copy + the audio-language scan over the variants) and the
/// enabled `[TitleEdition]` list (`PlaybackEdition` tag folding per variant).
/// Navigation re-evaluates every mounted page's body in a section, so both are
/// rebuilt only when their inputs actually change.
@MainActor
private final class DetailPageMemo {
    private struct Key: Equatable {
        let titleID: TitleID
        let catalogRevision: Int
        let languages: Set<HomeAudioLanguage>
        let sources: [Source]
    }

    private var key: Key?
    private var displayTitle: MediaTitle?
    private var editions: [TitleEdition] = []

    func content(for title: MediaTitle, app: AppModel) -> (title: MediaTitle, editions: [TitleEdition]) {
        let key = Key(
            titleID: title.id, catalogRevision: app.catalogRevision,
            languages: app.homeAudioLanguages, sources: app.sources
        )
        if key == self.key, let displayTitle { return (displayTitle, editions) }

        var display = app.recommendations.named(title)
        if let name = app.recommendations.localizedName(for: title, in: app.catalog, languages: app.homeAudioLanguages) {
            display.title = name
        }
        // `app.source(_:)` is a linear scan; editions look variants up once each.
        let sourcesByID = Dictionary(app.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let editions = title.variants.compactMap { variant -> TitleEdition? in
            guard let source = sourcesByID[variant.sourceID], source.isEnabled else { return nil }
            return TitleEdition(variant: variant, source: source, categoryLanguages: app.catalog.providerLanguages(for: variant))
        }
        self.key = key
        self.displayTitle = display
        self.editions = editions
        return (display, editions)
    }
}

private struct TitleDetailContent: View {
    @Environment(AppModel.self) private var app
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.playPrismItem) private var playItem
    @Environment(\.isPageActive) private var isPageActive
    @Environment(\.openURL) private var openURL
    @Environment(\.prismSnapshotRendering) private var snapshotRendering
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: MediaTitle
    let editions: [TitleEdition]

    @State private var loadedMovieDetail: MovieDetail?
    @State private var inventory: DetailEpisodeInventory?
    @State private var enriched: TMDBMetadata?
    @State private var resolvedMetadata: MetadataKey?
    @State private var tvmazeCast: CastAttachment?
    @State private var alternateMoviePlot: String?
    @State private var plot: String?
    @State private var related: [MediaTitle] = []
    @State private var seasonMetadata: SeasonMetadata?
    @State private var selectedSeason: Int?
    @State private var loadingEpisodes = true
    @State private var isAtTop = true
    @State private var heroBlurStep = 0
    @State private var failedToLoadEpisodes = false
    @State private var episodeFailureReason: String?
    @State private var retryCount = 0
    @State private var browseEditionID: ContentID?
    @State private var playbackSelection: TitlePlaybackSelection?
    @Environment(\.playbackOverlay) private var playbackOverlay
    /// Latest on-screen frame of each episode card, so the playback sheet can grow out of it.
    /// Not observed: scrolling updates it without re-evaluating the page.
    @State private var episodeFrames = EpisodeFrames()
    /// Sizes the playback sheet relative to the page it covers.
    @State private var viewportSize = CGSize(width: 1280, height: 860)

    private let margin = PrismMetrics.contentMargin
    private let landscapeCardWidth: CGFloat = 256
    /// Shared by every evaluation: `Calendar(identifier:)` resolves locale/timezone each time.
    private static let gregorian = Calendar(identifier: .gregorian)

    private var preferredID: ContentID? { app.library.preferredVariant(for: title.id) }
    private var preferredEditionID: ContentID? { browseEditionID ?? preferredID }
    private var activeEdition: TitleEdition? {
        let preferred = preferredEditionID
        return editions.first { $0.id == preferred } ?? editions.first
    }
    private var movieDetail: MovieDetail? {
        guard let loadedMovieDetail, loadedMovieDetail.movieID == activeEdition?.id else { return nil }
        return loadedMovieDetail
    }
    private var synopsisCandidates: [String?] {
        catalogSynopses + [alternateMoviePlot]
    }
    private var catalogSynopses: [String?] {
        [enriched?.overview, title.plot, movieDetail?.plot, inventory?.detail.plot]
            + editions.prefix(12).map { $0.variant.movie?.plot ?? $0.variant.series?.plot }
    }
    private var backdrops: [URL] {
        let metadata = [enriched?.images.backdropURL, title.backdropURL].compactMap { $0 }
        return metadata + (movieDetail?.backdropURLs ?? inventory?.detail.backdropURLs ?? [])
    }
    private var posters: [URL] {
        [enriched?.images.posterURL, title.posterURL, activeEdition?.variant.movie?.posterURL,
         activeEdition?.variant.series?.posterURL].compactMap { $0 }
    }
    private var genres: [String] {
        [enriched?.genres, movieDetail?.genres, inventory?.detail.genres, title.genres]
            .compactMap { $0 }.first { !$0.isEmpty } ?? []
    }
    private var year: Int? {
        let providerDate = movieDetail?.releaseDate ?? inventory?.detail.releaseDate
        return enriched?.releaseYear ?? title.year
            ?? providerDate.map { Self.gregorian.component(.year, from: $0) }
    }
    private var minutes: Int? {
        enriched?.runtimeMinutes
            ?? (movieDetail?.durationSeconds ?? activeEdition?.variant.movie?.durationSeconds).flatMap(Self.minutes)
    }
    private var displayedSeason: Season? {
        inventory?.seasons.first { $0.number == selectedSeason } ?? inventory?.seasons.first { $0.number > 0 }
            ?? inventory?.seasons.first
    }
    private var heroEpisode: Episode? {
        // Hidden pages skip every library read so playback ticks (~5 s) do not
        // re-evaluate them; reads resume when the page becomes active again.
        guard isPageActive, let inventory else { return nil }
        let library = app.library
        // The store memoizes the per-title latest progress: when it belongs to
        // this edition it is also the edition's latest (the common case while
        // playing). Otherwise fall back to the per-edition scan, which also
        // covers progress entries whose titleID was never recorded.
        let latest: PlaybackProgress?
        if let titleLatest = library.latestProgress(forTitle: title.id),
           inventory.contains(titleLatest.contentID) {
            latest = titleLatest
        } else {
            latest = inventory.latestProgress(in: library.progress)
        }
        return inventory.nextEpisode(after: latest, isWatched: library.isWatched)
    }
    private var seasonLookup: SeasonLookup {
        let tmdbID = enriched?.tmdbID ?? inventory?.detail.tmdbID ?? inventory?.edition.variant.series?.tmdbID
        return SeasonLookup(active: isPageActive && app.isMetadataEnabled, tmdbID: tmdbID, season: displayedSeason?.number)
    }
    private var metadataLookup: MetadataKey {
        MetadataKey(
            active: isPageActive, enabled: app.isMetadataEnabled, revision: app.catalogRevision,
            tmdbID: movieDetail?.tmdbID ?? inventory?.detail.tmdbID
        )
    }
    private var hasTMDBPortraits: Bool {
        enriched?.cast.contains { $0.profileURL != nil } == true
    }
    private var tvmazeLookup: CastLookup? {
        guard isPageActive, !snapshotRendering, title.kind == .series, !hasTMDBPortraits,
              !app.isMetadataEnabled || metadataLookup == resolvedMetadata,
              editions.contains(where: { !DemoContent.isDemo($0.source) })
        else { return nil }
        return castIdentity
    }
    private var castIdentity: CastLookup? {
        year.map { CastLookup(title: enriched?.title ?? title.title, year: $0) }
    }
    private var externalCast: SeriesCast? {
        guard !hasTMDBPortraits, let tvmazeCast, tvmazeCast.lookup == castIdentity else { return nil }
        return tvmazeCast.cast
    }
    private var relatedLookup: RelatedLookup {
        RelatedLookup(
            active: isPageActive, revision: app.catalogRevision, curation: app.curationRevision, genres: genres,
            languages: app.homeAudioLanguages
        )
    }
    private var rating: DetailRating? {
        DetailRating.preferred(
            tmdb: enriched?.voteAverage,
            provider: [movieDetail?.rating, inventory?.detail.rating, title.rating]
        )
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 34) {
                    masthead(viewportHeight: viewport.size.height)
                    if title.kind == .series { episodes }
                    if let trailer { trailerShelf(trailer) }
                    if !related.isEmpty { similarTitles }
                    if !cast.isEmpty { castShelf }
                    details
                        .padding(.horizontal, margin)
                    if let rating {
                        VStack(alignment: .leading, spacing: 12) {
                            ShelfHeader("Évaluation")
                            TitleRatingPanel(rating: rating)
                        }
                        .padding(.horizontal, margin)
                    }
                }
                .padding(.bottom, 52)
            }
            .scrollContentBackground(.hidden)
            .onScrollGeometryChange(for: Bool.self) { scroll in
                scroll.contentOffset.y + scroll.contentInsets.top <= 1
            } action: { _, atTop in
                isAtTop = atTop
            }
            .onScrollGeometryChange(for: Int.self) { scroll in
                let distance = max(0, scroll.contentOffset.y + scroll.contentInsets.top)
                let heroHeight = Self.mastheadHeight(for: viewport.size.height)
                let progress = max(0, min(1, (distance / heroHeight - 0.78) / 0.20))
                return Int((progress * 20).rounded())
            } action: { _, step in
                heroBlurStep = step
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .prismScrollPhase()
            .background(alignment: .top) {
                if reduceMotion && isAtTop {
                    HeroOverscrollBackground(backdropURLs: backdrops, fallbackPosterURLs: posters, seed: title.id.rawValue)
                        .frame(height: Self.mastheadHeight(for: viewport.size.height))
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .background(PrismColors.pageBackground)
        .task(id: LookupKey(active: isPageActive, revision: app.catalogRevision, edition: preferredEditionID, retry: retryCount)) {
            guard isPageActive else { return }
            await loadProviderDetails()
        }
        .task(id: metadataLookup) { [lookup = metadataLookup] in
            guard lookup.active else { return }
            await loadEnrichment(for: lookup)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewportSize = $0 }
        .task(id: tvmazeLookup) { [lookup = tvmazeLookup] in
            guard let lookup else { return }
            let cast = await SeriesCastRepository.shared.cast(title: lookup.title, year: lookup.year)
            if !Task.isCancelled { tvmazeCast = cast.map { CastAttachment(lookup: lookup, cast: $0) } }
        }
        .task(id: seasonLookup) { [lookup = seasonLookup] in await loadEpisodeInfo(for: lookup) }
        .task(id: isPageActive ? synopsisCandidates : []) {
            guard isPageActive else { return }
            let synopsis = await DetailPresentation.synopsis(synopsisCandidates)
            if !Task.isCancelled { plot = synopsis }
        }
        .task(id: relatedLookup) { [lookup = relatedLookup] in
            guard lookup.active else { return }
            // Catalogue-wide similarity (genres, platforms, era) first; provider genre labels otherwise.
            var values = await app.similarTitles(to: title)
            if values.count < 4 {
                values = await DetailPresentation.relatedTitles(
                    to: title, genres: lookup.genres, in: app.catalog, recommendations: app.recommendations,
                    languages: lookup.languages
                )
            }
            if !Task.isCancelled { related = values }
        }
        .sheet(item: $playbackSelection) { selection in
            playbackSheet(selection, hero: playbackHero(for: selection.episode), container: viewportSize)
        }
        .onDisappear { playbackOverlay?.dismiss() }
    }

    private func playbackSheet(_ selection: TitlePlaybackSelection, hero: PlaybackSheetHero, container: CGSize) -> TitlePlaybackSheet {
        TitlePlaybackSheet(
            title: title,
            selection: selection,
            hero: hero,
            containerSize: container,
            repository: app.detailRepository,
            resumePosition: { position(for: $0, equivalentEpisode: selection.episode) },
            onPlay: { option, position in play(option, from: position) }
        )
    }

    private var titleFacts: [String] {
        [
            year.map(String.init),
            genres.first.map(DetailPresentation.genreLabel),
            title.kind == .movie ? minutes.map { "\($0) min" } : nil,
            enriched?.certification,
        ].compactMap { $0 }
    }

    private func playbackHero(for episode: Episode?) -> PlaybackSheetHero {
        guard let episode else {
            return .title(
                title, year: year, genre: genres.first.map(DetailPresentation.genreLabel),
                runtimeMinutes: title.kind == .movie ? minutes : nil, certification: enriched?.certification,
                plot: plot, rating: enriched?.voteAverage,
                backdrop: backdrops.first, poster: posters.first, logo: enriched?.images.logoURL
            )
        }
        let metadata = seasonMetadata.flatMap { metadata in
            metadata.matches(seasonLookup) && metadata.season == episode.season ? metadata.episodes[episode.number] : nil
        }
        return .episode(episode, series: title.title, metadata: metadata, backdrop: backdrops.first, poster: posters.first)
    }

    private func masthead(viewportHeight: CGFloat) -> some View {
        let episode = heroEpisode
        let edition = title.kind == .series ? inventory?.edition ?? activeEdition : activeEdition
        let option = edition.flatMap { TitlePlaybackOption(edition: $0, episode: episode) }
        let progress = isPageActive ? option.flatMap { resumeProgress(for: $0) } : nil
        let resuming = progress != nil
        let facts = [title.kind == .series ? "Série" : "Film"] + titleFacts
        let label = episode.map {
            "\(resuming ? "Reprendre" : "Lire") \(EpisodeCoordinate($0).label)"
        } ?? (resuming ? "Reprendre" : "Lecture")

        return TitleDetailMasthead(
            title: title, height: Self.mastheadHeight(for: viewportHeight), blurAmount: Double(heroBlurStep) / 20,
            metadata: enriched,
            backdrops: backdrops, posters: posters, plot: plot, facts: facts,
            quality: movieDetail?.tech?.quality.badge ?? edition?.variant.quality.badge, playLabel: label,
            progress: resuming ? progress?.fraction : nil,
            canPlay: title.kind == .series ? episode != nil : activeEdition != nil,
            // Hidden pages skip library reads (see `heroEpisode`): the watchlist scan is
            // O(#watchlist) and would subscribe this subtree to unrelated watchlist edits.
            isInWatchlist: isPageActive && app.library.isInWatchlist(title.id),
            edition: edition, editionCount: editions.count,
            play: { choosePlayback(episode: episode) },
            toggleWatchlist: { app.library.toggleWatchlist(title.id) },
            showEditions: { choosePlayback(episode: episode, alwaysShowPicker: true) }
        )
    }

    private static func mastheadHeight(for viewportHeight: CGFloat) -> CGFloat {
        min(760, max(460, viewportHeight * 0.78))
    }

    private var episodes: some View {
        VStack(alignment: .leading, spacing: 14) {
            episodeShelfHeader
            if let season = displayedSeason {
                let lookup = seasonLookup
                let metadata = seasonMetadata.flatMap { $0.matches(lookup) ? $0.episodes : nil }
                Shelf(title: nil, items: season.episodes, sizing: .fixed(landscapeCardWidth), spacing: 18, margin: margin,
                      posterArtwork: isPageActive ? \.stillURL : nil) { episode in
                    episodeCard(episode, metadata: metadata?[episode.number])
                }
                .id(season.id)
            } else {
                episodeStatus
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, margin)
            }
        }
    }

    private var episodeShelfHeader: some View {
        let edition = inventory?.edition ?? activeEdition
        return HStack(alignment: .center, spacing: 12) {
            if let season = displayedSeason {
                let label = Self.seasonLabel(season)
                if let inventory, inventory.seasons.count > 1 {
                    ShelfMenuHeader(label) {
                        ForEach(inventory.seasons) { option in
                            Button {
                                selectedSeason = option.number
                            } label: {
                                if option.id == season.id {
                                    Label(Self.seasonLabel(option), systemImage: "checkmark")
                                } else {
                                    Text(Self.seasonLabel(option))
                                }
                            }
                        }
                    }
                } else {
                    Text(label).font(PrismFont.shelfTitle).accessibilityAddTraits(.isHeader)
                }
                Text(season.episodes.count == 1 ? "1 épisode" : "\(season.episodes.count) épisodes")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Épisodes").font(PrismFont.shelfTitle).accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 0)
            if let edition, editions.count > 1 {
                Menu {
                    ForEach(editions) { candidate in
                        Button {
                            if browseEditionID == candidate.id, inventory?.edition.id != candidate.id {
                                retryCount += 1
                            } else {
                                browseEditionID = candidate.id
                            }
                        } label: {
                            if candidate.id == edition.id {
                                Label(Self.editionLabel(candidate), systemImage: "checkmark")
                            } else {
                                Text(Self.editionLabel(candidate))
                            }
                        }
                    }
                } label: {
                    Label(edition.source.name, systemImage: "rectangle.on.rectangle")
                        .lineLimit(1)
                }
                .menuStyle(.borderedButton)
                .accessibilityLabel("Source des épisodes")
                .accessibilityValue(Self.editionLabel(edition))
                .help("Changer la source de cette liste d’épisodes")
            }
        }
        .padding(.horizontal, margin)
    }

    @ViewBuilder private var episodeStatus: some View {
        if loadingEpisodes {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Chargement des épisodes…")
            }
        } else if failedToLoadEpisodes {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Label("Impossible de charger les épisodes.", systemImage: "exclamationmark.circle")
                    Button("Réessayer") { retryCount += 1 }
                }
                if let episodeFailureReason {
                    Text(episodeFailureReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Label("Aucun épisode disponible dans vos sources.", systemImage: "tv")
        }
    }

    private func episodeCard(_ episode: Episode, metadata: TMDBEpisodeInfo?) -> some View {
        // Skip library reads while the page is hidden: they would subscribe this
        // subtree to every playback tick for an invisible page.
        let progress = isPageActive ? app.library.progress(for: episode.id) : nil
        let watched = isPageActive ? app.library.isWatched(episode.id) : false
        return DetailEpisodeTile(
            episode: episode, metadata: metadata, artwork: backdrops.first, progress: progress, watched: watched
        ) {
            choosePlayback(episode: episode, alwaysShowPicker: true, from: episodeFrames.frames[episode.id])
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { [episodeFrames] frame in
            episodeFrames.frames[episode.id] = frame
        }
        .contextMenu {
            Button(watched ? "Marquer comme non vu" : "Marquer comme vu", systemImage: watched ? "circle" : "checkmark.circle") {
                if watched {
                    app.library.markUnwatched(episode.id)
                } else {
                    app.library.markWatched(episode.id, titleID: title.id)
                }
            }
            if progress != nil && !watched {
                Button("Effacer la progression", systemImage: "arrow.counterclockwise") {
                    app.library.clearProgress(for: episode.id)
                }
            }
        }
    }

    @ViewBuilder private var details: some View {
        let providerDirectors = [movieDetail?.director ?? inventory?.detail.director
            ?? activeEdition?.variant.movie?.director ?? activeEdition?.variant.series?.director].compactMap { $0 }
        let directors = enriched?.directors.isEmpty == false ? enriched?.directors ?? [] : providerDirectors
        let fields: [(label: String, value: String?)] = [
            ("Année", year.map(String.init)),
            ("Durée", title.kind == .movie ? minutes.map { "\($0) min" } : nil),
            ("Genres", genres.isEmpty ? nil : genres.map(DetailPresentation.genreLabel).joined(separator: ", ")),
            ("Réalisation", directors.isEmpty ? nil : directors.joined(separator: ", ")),
            ("Pays", movieDetail?.country),
        ]
        let rows: [(label: String, value: String)] = fields.compactMap { label, value in
            guard let value, !value.isEmpty else { return nil }
            return (label, value)
        }
        let edition = inventory?.edition ?? activeEdition

        if plot != nil || !rows.isEmpty || edition != nil {
            VStack(alignment: .leading, spacing: 28) {
                if let plot {
                    VStack(alignment: .leading, spacing: 12) {
                        ShelfHeader("À propos")
                        Text(plot)
                            .font(.system(size: 14))
                            .foregroundStyle(.primary)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: 680, alignment: .leading)
                            .padding(18)
                            .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 14))
                    }
                }
                HStack(alignment: .top, spacing: 42) {
                    if !rows.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            detailHeading("Informations")
                            ForEach(rows, id: \.label) { row in credit(row.label, value: row.value) }
                        }
                        .frame(maxWidth: 220, alignment: .leading)
                    }
                    if let edition { editionDetails(edition) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func editionDetails(_ edition: TitleEdition) -> some View {
        let tech = movieDetail?.tech
        let format = [tech?.quality.badge ?? edition.variant.quality.badge, edition.variant.movie?.containerExtension?.uppercased()]
            .compactMap { $0 }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 10) {
            detailHeading("Édition")
            credit("Source", value: edition.source.name)
            credit("Langue ou version", value: edition.edition.title)
            if !format.isEmpty { credit("Vidéo", value: format) }
        }
        .frame(maxWidth: 220, alignment: .leading)
    }

    private var trailer: URL? {
        [enriched?.trailerURL, movieDetail?.trailerURL, inventory?.detail.trailerURL,
         activeEdition?.variant.movie?.trailerURL, activeEdition?.variant.series?.trailerURL]
            .compactMap { $0 }.first { url in
                url.host != nil && (url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http")
            }
    }

    private func trailerShelf(_ destination: URL) -> some View {
        Shelf(title: "Bandes-annonces", items: [title], sizing: .fixed(landscapeCardWidth), margin: margin) { item in
            WideCard(
                imageURL: backdrops.first, seed: item.id.rawValue + "/trailer", caption: "Bande-annonce",
                showsPlayGlyph: true, placeholderTitle: item.title
            ) { openURL(destination) }
            .accessibilityHint("Ouvrir la bande-annonce")
        }
    }

    private func detailHeading(_ title: String) -> some View {
        Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
    }

    private func credit(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.callout)
        }
        .accessibilityElement(children: .combine)
    }

    private var similarTitles: some View {
        Shelf(title: "À voir aussi", items: related, spacing: 16, margin: margin,
              posterArtwork: isPageActive ? \.posterURL : nil) { item in
            PosterCard(
                imageURL: item.posterURL, seed: item.id.rawValue, title: item.title,
                subtitle: item.year.map(String.init), showsTitle: true
            ) { navigation.push(.title(item.id)) }
        }
    }

    private var cast: [TMDBPerson] {
        if let externalCast {
            return externalCast.people.map {
                TMDBPerson(id: $0.id, name: $0.name, role: $0.role, profileURL: $0.portrait)
            }
        }
        if let enriched, !enriched.cast.isEmpty { return Array(enriched.cast.prefix(16)) }
        let names = [movieDetail?.cast, inventory?.detail.cast, activeEdition?.variant.movie?.cast, activeEdition?.variant.series?.cast]
            .compactMap { $0 }.first { !$0.isEmpty } ?? []
        return names.prefix(16).enumerated().map {
            TMDBPerson(id: $0.offset, name: $0.element, role: nil, profileURL: nil)
        }
    }

    private var castShelf: some View {
        VStack(alignment: .leading, spacing: PrismMetrics.shelfHeaderSpacing) {
            ShelfHeader("Distribution") {
                if let externalCast {
                    Link("TVmaze · CC BY-SA", destination: externalCast.creditURL)
                        .font(.caption)
                        .accessibilityLabel("Distribution par TVmaze, licence Creative Commons BY-SA")
                }
            }
            .padding(.horizontal, margin)
            Shelf(title: nil, items: cast, sizing: .fixed(96), spacing: 18, margin: margin,
                  posterArtwork: isPageActive ? \.profileURL : nil) { person in
                PersonCircle(name: person.name, role: person.role, imageURL: person.profileURL, diameter: 83)
            }
        }
    }

    private func choosePlayback(episode: Episode?, alwaysShowPicker: Bool = false, from source: CGRect? = nil) {
        let available = editions
        let options: [TitlePlaybackOption]
        let others: [TitleEdition]
        if let episode, let current = available.first(where: { $0.id == episode.seriesID }) {
            options = [TitlePlaybackOption(edition: current, episode: episode)].compactMap { $0 }
            others = available.filter { $0.id != current.id }
        } else if title.kind == .movie {
            options = available.compactMap { TitlePlaybackOption(edition: $0) }
            others = []
        } else {
            return
        }

        guard let first = options.first else { return }
        if alwaysShowPicker || options.count > 1 || !others.isEmpty {
            let selection = TitlePlaybackSelection(
                options: options, otherEditions: others, episode: episode,
                preferred: episode == nil ? preferredID : first.id
            )
            if let playbackOverlay {
                let hero = playbackHero(for: episode)
                playbackOverlay.present(from: source) { container in
                    playbackSheet(selection, hero: hero, container: container)
                }
            } else {
                playbackSelection = selection
            }
        } else {
            play(first, from: position(for: first))
        }
    }

    private func position(for option: TitlePlaybackOption, equivalentEpisode: Episode? = nil) -> TimeInterval? {
        resumeProgress(for: option, equivalentEpisode: equivalentEpisode)?.position
    }

    private func resumeProgress(for option: TitlePlaybackOption, equivalentEpisode: Episode? = nil) -> PlaybackProgress? {
        let library = app.library
        let exact = library.progress(for: option.contentID)
        let equivalent: PlaybackProgress?
        if let requested = equivalentEpisode, option.episode != nil {
            equivalent = library.progress(for: requested.id)
        } else if title.kind == .movie {
            equivalent = library.latestProgress(forTitle: title.id)
        } else {
            equivalent = nil
        }
        guard option.resumePosition(exact: exact, equivalent: equivalent) != nil else { return nil }
        return exact ?? equivalent
    }

    private func play(_ option: TitlePlaybackOption, from position: TimeInterval?) {
        guard app.source(option.titleEdition.source.id)?.isEnabled == true else { return }
        playbackSelection = nil
        app.library.setPreferredVariant(option.id, for: title.id)
        browseEditionID = nil
        playItem(
            option.playbackItem(for: title, position: position), .title(title.id), option.contentID,
            seriesEditionID: option.episode == nil ? nil : option.id
        )
    }

    private func loadProviderDetails() async {
        let candidates = editions
        let preferred = candidates.first { $0.id == preferredEditionID }
        let ordered = [preferred].compactMap { $0 } + candidates.filter { $0.id != preferred?.id }
        if title.kind == .movie {
            guard let edition = ordered.first, let movie = edition.variant.movie else { return }
            alternateMoviePlot = nil
            var detail = try? await app.detailRepository.movieDetail(movie, source: edition.source)
            guard !Task.isCancelled else { return }
            let plot = ProviderSynopsis.cleaned(detail?.plot)
            detail?.plot = plot
            loadedMovieDetail = detail
            let candidate = DetailPresentation.alternateSynopsisEdition(in: ordered.dropFirst())
            await loadAlternateMovieSynopsis(from: candidate)
            return
        }

        failedToLoadEpisodes = false
        episodeFailureReason = nil
        if inventory?.edition.id != ordered.first?.id {
            inventory = nil
        }
        loadingEpisodes = inventory == nil
        var encounteredFailure = false
        for edition in ordered {
            guard !Task.isCancelled, let series = edition.variant.series else { return }
            do {
                let detail = try await app.detailRepository.seriesDetail(series, source: edition.source)
                let loaded = await DetailEpisodeInventory.build(edition: edition, detail: detail)
                guard !Task.isCancelled else { return }
                if !loaded.seasons.isEmpty {
                    inventory = loaded
                    if selectedSeason == nil {
                        selectedSeason = heroEpisode?.season
                    }
                    loadingEpisodes = false
                    return
                }
            } catch {
                encounteredFailure = true
                if episodeFailureReason == nil { episodeFailureReason = Self.episodeErrorDescription(error) }
            }
        }
        guard !Task.isCancelled else { return }
        failedToLoadEpisodes = encounteredFailure
        loadingEpisodes = false
    }

    private static func episodeErrorDescription(_ error: any Error) -> String {
        if let error = error as? XtreamError {
            switch error {
            case .network:
                return "Connexion au serveur impossible. Vérifiez votre connexion ou réessayez plus tard."
            default:
                return error.errorDescription ?? "La source n’a pas répondu correctement."
            }
        }
        if (error as? SourceError) == .missingCredentials {
            return "Les identifiants de cette source sont introuvables. Vérifiez les réglages de la source."
        }
        return "La source n’a pas répondu correctement. Réessayez ou vérifiez ses réglages."
    }

    private func loadAlternateMovieSynopsis(from edition: TitleEdition?) async {
        guard let edition, let movie = edition.variant.movie, enriched?.overview == nil,
              await DetailPresentation.synopsis(catalogSynopses) == nil,
              !Task.isCancelled, enriched?.overview == nil else { return }
        let detail = try? await app.detailRepository.movieDetail(movie, source: edition.source)
        if !Task.isCancelled { alternateMoviePlot = detail?.plot }
    }

    private func loadEnrichment(for lookup: MetadataKey) async {
        let metadata = lookup.enabled ? await app.metadataRepository.metadata(for: title, tmdbID: lookup.tmdbID) : nil
        guard !Task.isCancelled else { return }
        enriched = metadata
        resolvedMetadata = lookup
    }

    private func loadEpisodeInfo(for lookup: SeasonLookup) async {
        guard lookup.active, let id = lookup.tmdbID, id > 0, let season = lookup.season else { return }
        if seasonMetadata?.matches(lookup) == true { return }
        let info = await app.metadataRepository.episodes(tmdbID: id, season: season)
        if !Task.isCancelled, !info.isEmpty {
            seasonMetadata = SeasonMetadata(
                tmdbID: id, season: season,
                episodes: Dictionary(info.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
            )
        }
    }

    nonisolated private static func seasonLabel(_ season: Season) -> String {
        season.number == 0 ? "Épisodes spéciaux" : "Saison \(season.number)"
    }

    nonisolated private static func editionLabel(_ edition: TitleEdition) -> String {
        [edition.source.name, edition.edition.title, edition.variant.quality.badge]
            .compactMap { $0 }.joined(separator: " · ")
    }

    nonisolated private static func minutes(_ duration: Int) -> Int? {
        duration > 0 ? max(1, duration / 60) : nil
    }

    private struct RelatedLookup: Equatable {
        let active: Bool
        let revision: Int
        let curation: Int
        let genres: [String]
        let languages: Set<HomeAudioLanguage>
    }

    private struct LookupKey: Equatable {
        let active: Bool
        let revision: Int
        let edition: ContentID?
        let retry: Int
    }

    private struct MetadataKey: Equatable {
        let active: Bool
        let enabled: Bool
        let revision: Int
        let tmdbID: Int?
    }

    private struct CastLookup: Equatable {
        let title: String
        let year: Int
    }

    private struct CastAttachment {
        let lookup: CastLookup
        let cast: SeriesCast
    }

    private struct SeasonLookup: Equatable {
        let active: Bool
        let tmdbID: Int?
        let season: Int?
    }

    private struct SeasonMetadata {
        let tmdbID: Int
        let season: Int
        let episodes: [Int: TMDBEpisodeInfo]

        func matches(_ lookup: SeasonLookup) -> Bool {
            tmdbID == lookup.tmdbID && season == lookup.season
        }
    }
}

/// Reference box for card frames: written on scroll without invalidating the page.
private final class EpisodeFrames {
    var frames: [ContentID: CGRect] = [:]
}
