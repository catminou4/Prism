import Foundation
import PrismCore
import PrismData
import PrismDesign
import SwiftUI

struct TitleDetailView: View {
    @Environment(AppModel.self) private var app
    let titleID: TitleID

    var body: some View {
        if let title = app.catalog.title(titleID) {
            let editions = title.variants.compactMap { variant -> TitleEdition? in
                guard let source = app.source(variant.sourceID), source.isEnabled else { return nil }
                return TitleEdition(variant: variant, source: source, categoryLanguages: app.catalog.providerLanguages(for: variant))
            }
            TitleDetailContent(title: app.recommendations.named(title), editions: editions)
                .id(title.id)
        } else {
            ContentUnavailableView("Titre indisponible", systemImage: "film", description: Text("Ce titre ne figure plus dans vos sources actives."))
        }
    }
}

private struct TitleDetailContent: View {
    @Environment(AppModel.self) private var app
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.playPrismItem) private var playItem
    @Environment(\.isPageActive) private var isPageActive
    let title: MediaTitle
    let editions: [TitleEdition]

    @State private var loadedMovieDetail: MovieDetail?
    @State private var inventory: DetailEpisodeInventory?
    @State private var enriched: TMDBMetadata?
    @State private var related: [MediaTitle] = []
    @State private var seasonMetadata: SeasonMetadata?
    @State private var selectedSeason: Int?
    @State private var loadingEpisodes = true
    @State private var failedToLoadEpisodes = false
    @State private var retryCount = 0
    @State private var browseEditionID: ContentID?
    @State private var playbackSelection: TitlePlaybackSelection?

    private let margin = PrismMetrics.contentMargin

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
    private var plot: String? { enriched?.overview ?? movieDetail?.plot ?? inventory?.detail.plot ?? title.plot }
    private var backdrop: URL? {
        enriched?.images.backdropURL ?? movieDetail?.backdropURLs.first
            ?? inventory?.detail.backdropURLs.first ?? title.backdropURL
    }
    private var genres: [String] {
        [enriched?.genres, movieDetail?.genres, inventory?.detail.genres, title.genres]
            .compactMap { $0 }.first { !$0.isEmpty } ?? []
    }
    private var year: Int? {
        let providerDate = movieDetail?.releaseDate ?? inventory?.detail.releaseDate
        return enriched?.releaseYear ?? title.year
            ?? providerDate.map { Calendar(identifier: .gregorian).component(.year, from: $0) }
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
        inventory?.nextEpisode(after: app.library.latestProgress(forTitle: title.id), isWatched: app.library.isWatched)
    }
    private var seasonLookup: SeasonLookup {
        SeasonLookup(active: isPageActive, tmdbID: enriched?.tmdbID, season: displayedSeason?.number)
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    masthead(viewportHeight: viewport.size.height)
                        .padding(.horizontal, 8)
                    if title.kind == .series { episodes }
                    if let trailer {
                        Link(destination: trailer) { Label("Bande-annonce", systemImage: "play.rectangle") }
                            .buttonStyle(.glass)
                            .padding(.horizontal, margin)
                    }
                    if !related.isEmpty { similarTitles }
                    if !cast.isEmpty { castShelf }
                    details
                        .padding(.horizontal, margin)
                }
                .padding(.top, 8)
                .padding(.bottom, 42)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .ignoresSafeArea(.container, edges: .top)
        }
        .background(PrismColors.pageBackground)
        .task(id: LookupKey(active: isPageActive, revision: app.catalogRevision, edition: preferredEditionID, retry: retryCount)) {
            guard isPageActive else { return }
            await loadProviderDetails()
        }
        .task(id: MetadataKey(active: isPageActive, enabled: app.isMetadataEnabled, revision: app.catalogRevision)) {
            guard isPageActive else { return }
            await loadEnrichment()
        }
        .task(id: seasonLookup) { [lookup = seasonLookup] in await loadEpisodeInfo(for: lookup) }
        .task(id: isPageActive ? app.catalogRevision : nil) {
            guard isPageActive else { return }
            let values = await Self.relatedTitles(to: title, in: app.catalog)
            if !Task.isCancelled { related = values }
        }
        .sheet(item: $playbackSelection) { selection in
            TitlePlaybackSheet(
                title: title,
                selection: selection,
                repository: app.detailRepository,
                resumePosition: { position(for: $0) },
                onPlay: { option, position in play(option, from: position) }
            )
        }
    }

    private func masthead(viewportHeight: CGFloat) -> some View {
        let episode = heroEpisode
        let edition = title.kind == .series ? inventory?.edition ?? activeEdition : activeEdition
        let progress = title.kind == .series
            ? episode.flatMap { app.library.progress(for: $0.id) }
            : app.library.latestProgress(forTitle: title.id)
        let resuming = progress.map { !$0.isFinished && $0.position >= 5 } ?? false
        let facts = [
            title.kind == .series ? "Série" : "Film",
            year.map(String.init),
            genres.first,
            title.kind == .movie ? minutes.map { "\($0) min" } : nil,
            enriched?.certification,
            movieDetail?.tech?.quality.badge ?? edition?.variant.quality.badge,
        ].compactMap { $0 }
        let label = episode.map {
            "\(resuming ? "Reprendre" : "Lire") \(EpisodeCoordinate($0).label)"
        } ?? (resuming ? "Reprendre" : "Lecture")

        return TitleDetailMasthead(
            title: title, height: min(550, max(378, viewportHeight * 0.62)), metadata: enriched,
            backdrop: backdrop, plot: plot, facts: facts, playLabel: label,
            progress: resuming ? progress?.fraction : nil,
            canPlay: title.kind == .series ? episode != nil : activeEdition != nil,
            isInWatchlist: app.library.isInWatchlist(title.id),
            edition: edition, editionCount: editions.count,
            play: { choosePlayback(episode: episode) },
            toggleWatchlist: { app.library.toggleWatchlist(title.id) },
            showEditions: { choosePlayback(episode: episode, alwaysShowPicker: true) }
        )
    }

    private var episodes: some View {
        VStack(alignment: .leading, spacing: 14) {
            episodeShelfHeader
            if let season = displayedSeason {
                let lookup = seasonLookup
                let metadata = seasonMetadata.flatMap { $0.matches(lookup) ? $0.episodes : nil }
                Shelf(title: nil, items: season.episodes, sizing: .columns(minWidth: 224), spacing: 16, margin: margin) { episode in
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
            Text("Épisodes")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if let season = displayedSeason {
                if let inventory, inventory.seasons.count > 1 {
                    Picker("Saison des épisodes", selection: seasonBinding) {
                        ForEach(inventory.seasons) { season in
                            Text(Self.seasonLabel(season)).tag(season.number)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                } else {
                    Text(Self.seasonLabel(season))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(season.episodes.count == 1 ? "1 épisode" : "\(season.episodes.count) épisodes")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let edition, editions.count > 1 {
                Menu {
                    ForEach(editions) { candidate in
                        Button {
                            browseEditionID = candidate.id
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
            HStack(spacing: 12) {
                Label("Impossible de charger les épisodes.", systemImage: "exclamationmark.circle")
                Button("Réessayer") { retryCount += 1 }
            }
        } else {
            Label("Aucun épisode disponible dans vos sources.", systemImage: "tv")
        }
    }

    private var seasonBinding: Binding<Int> {
        Binding(get: { displayedSeason?.number ?? 1 }, set: { selectedSeason = $0 })
    }

    private func episodeCard(_ episode: Episode, metadata: TMDBEpisodeInfo?) -> some View {
        let progress = app.library.progress(for: episode.id)
        let watched = app.library.isWatched(episode.id)
        return DetailEpisodeTile(
            episode: episode, metadata: metadata, artwork: backdrop, progress: progress, watched: watched
        ) {
            choosePlayback(episode: episode)
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
        let rating = enriched?.voteAverage ?? movieDetail?.rating ?? inventory?.detail.rating ?? title.rating
        let providerDirectors = [movieDetail?.director ?? inventory?.detail.director
            ?? activeEdition?.variant.movie?.director ?? activeEdition?.variant.series?.director].compactMap { $0 }
        let directors = enriched?.directors.isEmpty == false ? enriched?.directors ?? [] : providerDirectors
        let formattedRating: String? = if let rating, (0.1...10.0).contains(rating) {
            "\(rating.formatted(.number.precision(.fractionLength(1)))) / 10"
        } else { nil }
        let fields: [(label: String, value: String?)] = [
            ("Année", year.map(String.init)),
            ("Durée", title.kind == .movie ? minutes.map { "\($0) min" } : nil),
            ("Genres", genres.isEmpty ? nil : genres.joined(separator: ", ")),
            ("Réalisation", directors.isEmpty ? nil : directors.joined(separator: ", ")),
            ("Note", formattedRating),
            ("Pays", movieDetail?.country),
        ]
        let rows: [(label: String, value: String)] = fields.compactMap { label, value in
            guard let value, !value.isEmpty else { return nil }
            return (label, value)
        }
        let edition = inventory?.edition ?? activeEdition

        if plot != nil || !rows.isEmpty || edition != nil {
            VStack(alignment: .leading, spacing: 20) {
                Divider()
                HStack(alignment: .top, spacing: 32) {
                    if let plot {
                        VStack(alignment: .leading, spacing: 10) {
                            detailHeading("À propos")
                            Text(plot)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .layoutPriority(1)
                        .frame(maxWidth: 530, alignment: .leading)
                    }
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
        Shelf(title: "À découvrir aussi", items: related, spacing: 16, margin: margin) { item in
            PosterCard(
                imageURL: item.posterURL, seed: item.id.rawValue, title: item.title,
                subtitle: item.year.map(String.init), showsTitle: true
            ) { navigation.push(.title(item.id)) }
        }
    }

    private var cast: [TMDBPerson] {
        if let enriched, !enriched.cast.isEmpty { return Array(enriched.cast.prefix(16)) }
        let names = [movieDetail?.cast, inventory?.detail.cast, activeEdition?.variant.movie?.cast, activeEdition?.variant.series?.cast]
            .compactMap { $0 }.first { !$0.isEmpty } ?? []
        return names.prefix(16).enumerated().map {
            TMDBPerson(id: $0.offset, name: $0.element, role: nil, profileURL: nil)
        }
    }

    private var castShelf: some View {
        Shelf(title: "Distribution", items: cast, sizing: .fixed(92), spacing: 16, margin: margin) { person in
            PersonCircle(name: person.name, role: person.role, imageURL: person.profileURL, diameter: 76)
        }
    }

    private func choosePlayback(episode: Episode?, alwaysShowPicker: Bool = false) {
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
            playbackSelection = TitlePlaybackSelection(
                options: options, otherEditions: others, episode: episode,
                preferred: episode == nil ? preferredID : first.id
            )
        } else {
            play(first, from: position(for: first))
        }
    }

    private func position(for option: TitlePlaybackOption) -> TimeInterval? {
        let library = app.library
        let equivalent: PlaybackProgress?
        if let requested = playbackSelection?.episode, option.episode != nil {
            equivalent = library.progress(for: requested.id)
        } else if title.kind == .movie {
            equivalent = library.latestProgress(forTitle: title.id)
        } else {
            equivalent = nil
        }
        return option.resumePosition(exact: library.progress(for: option.contentID), equivalent: equivalent)
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
            var detail = try? await app.detailRepository.movieDetail(movie, source: edition.source)
            guard !Task.isCancelled else { return }
            let plot = ProviderSynopsis.cleaned(detail?.plot)
            detail?.plot = plot
            loadedMovieDetail = detail
            return
        }

        failedToLoadEpisodes = false
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
            }
        }
        guard !Task.isCancelled else { return }
        failedToLoadEpisodes = encounteredFailure
        loadingEpisodes = false
    }

    private func loadEnrichment() async {
        guard app.isMetadataEnabled else { enriched = nil; return }
        let metadata = await app.metadataRepository.metadata(for: title)
        if !Task.isCancelled { enriched = metadata }
    }

    private func loadEpisodeInfo(for lookup: SeasonLookup) async {
        guard lookup.active, let id = lookup.tmdbID, let season = lookup.season else { return }
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

    @concurrent private static func relatedTitles(to title: MediaTitle, in catalog: Catalog) async -> [MediaTitle] {
        catalog.related(to: title, limit: 12)
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
