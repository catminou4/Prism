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
            TitleDetailContent(title: title)
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

    @State private var availableHeight: CGFloat = 760
    @State private var movieDetail: MovieDetail?
    @State private var inventory: DetailEpisodeInventory?
    @State private var enriched: TMDBMetadata?
    @State private var related: [MediaTitle] = []
    @State private var episodeInfo: [Int: TMDBEpisodeInfo] = [:]
    @State private var selectedSeason: Int?
    @State private var loadingEpisodes = true
    @State private var failedToLoadEpisodes = false
    @State private var retryCount = 0
    @State private var browseEditionID: ContentID?
    @State private var playbackSelection: TitlePlaybackSelection?

    private let margin = PrismMetrics.contentMargin

    private var preferredID: ContentID? { app.library.preferredVariant(for: title.id) }
    private var preferredEditionID: ContentID? { browseEditionID ?? preferredID }
    private var editions: [TitleEdition] {
        title.variants.compactMap { variant in
            guard let source = app.source(variant.sourceID), source.isEnabled else { return nil }
            return TitleEdition(variant: variant, source: source)
        }
    }
    private var activeEdition: TitleEdition? {
        let options = editions
        return options.first { $0.id == preferredEditionID } ?? options.first
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                masthead
                    .padding(.horizontal, margin)
                if title.kind == .series { episodes }
                details
                    .padding(.horizontal, margin)
                if !related.isEmpty { similarTitles }
                if !cast.isEmpty { castShelf }
            }
            .padding(.top, 48)
            .padding(.bottom, 42)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(PrismColors.pageBackground)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { availableHeight = $0 }
        .task(id: LookupKey(active: isPageActive, revision: app.catalogRevision, edition: preferredEditionID, retry: retryCount)) {
            guard isPageActive else { return }
            await loadProviderDetails()
        }
        .task(id: MetadataKey(active: isPageActive, enabled: app.isMetadataEnabled, revision: app.catalogRevision)) {
            guard isPageActive else { return }
            await loadEnrichment()
        }
        .task(id: SeasonLookup(active: isPageActive, tmdbID: enriched?.tmdbID, season: displayedSeason?.number)) {
            await loadEpisodeInfo()
        }
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

    private var masthead: some View {
        let episode = heroEpisode
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
            (movieDetail?.tech?.quality.badge ?? title.bestQuality.badge),
        ].compactMap { $0 }
        let label = episode.map {
            "\(resuming ? "Reprendre" : "Lire") \(EpisodeCoordinate($0).label)"
        } ?? (resuming ? "Reprendre" : "Lecture")

        return TitleDetailMasthead(
            title: title, height: min(590, max(415, availableHeight * 0.60)), metadata: enriched,
            backdrop: backdrop, plot: plot, facts: facts, playLabel: label,
            progress: resuming ? progress?.fraction : nil,
            canPlay: title.kind == .series ? episode != nil : activeEdition != nil,
            isInWatchlist: app.library.isInWatchlist(title.id),
            edition: activeEdition, editionCount: editions.count,
            play: { choosePlayback(episode: episode) },
            toggleWatchlist: { app.library.toggleWatchlist(title.id) },
            showEditions: { choosePlayback(episode: episode, alwaysShowPicker: true) }
        )
    }

    @ViewBuilder private var episodes: some View {
        if let season = displayedSeason {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .center, spacing: 12) {
                    Text("Épisodes")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("\(season.episodes.count) dans cette saison")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let inventory, inventory.seasons.count > 1 {
                        Picker("Saison", selection: seasonBinding) {
                            ForEach(inventory.seasons) { season in
                                Text(season.number == 0 ? "Épisodes spéciaux" : "Saison \(season.number)")
                                    .tag(season.number)
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel("Saison")
                        .fixedSize()
                    } else if season.number > 0 {
                        Text("Saison \(season.number)").foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, margin)

                Shelf(title: nil, items: season.episodes, sizing: .columns(minWidth: 224), spacing: 16, margin: margin) { episode in
                    episodeCard(episode, metadata: episodeInfo[episode.number])
                }
                .id(season.id)
            }
        } else if loadingEpisodes {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Chargement des épisodes…").foregroundStyle(.secondary)
            }
            .padding(.horizontal, margin)
        } else if failedToLoadEpisodes {
            HStack(spacing: 12) {
                Label("Cette source n’a pas répondu.", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                Button("Réessayer") { retryCount += 1 }
            }
            .padding(.horizontal, margin)
        } else {
            Label("Aucun épisode disponible dans vos sources.", systemImage: "tv")
                .foregroundStyle(.secondary)
                .padding(.horizontal, margin)
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

    private var details: some View {
        let rating = enriched?.voteAverage ?? movieDetail?.rating ?? inventory?.detail.rating ?? title.rating
        let directors = enriched?.directors ?? [movieDetail?.director ?? inventory?.detail.director
            ?? activeEdition?.variant.movie?.director ?? activeEdition?.variant.series?.director].compactMap { $0 }
        let trailer = enriched?.trailerURL ?? movieDetail?.trailerURL ?? inventory?.detail.trailerURL
            ?? activeEdition?.variant.movie?.trailerURL ?? activeEdition?.variant.series?.trailerURL

        return VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("À propos").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    if let plot {
                        Text(plot).font(.callout).foregroundStyle(.secondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if let trailer, let scheme = trailer.scheme?.lowercased(), ["https", "http"].contains(scheme) {
                        Link(destination: trailer) { Label("Bande-annonce", systemImage: "play.rectangle") }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 10) {
                    if !genres.isEmpty { credit("Genres", value: genres.joined(separator: ", ")) }
                    if !directors.isEmpty { credit("Réalisation", value: directors.joined(separator: ", ")) }
                    if let rating, rating.isFinite, (0.1...10).contains(rating) {
                        credit("Note", value: "\(rating.formatted(.number.precision(.fractionLength(1)))) / 10")
                    }
                    if let country = movieDetail?.country, !country.isEmpty { credit("Pays", value: country) }
                    if let container = activeEdition?.variant.movie?.containerExtension {
                        credit("Format vidéo", value: [movieDetail?.tech?.quality.badge, container.uppercased()].compactMap { $0 }.joined(separator: " · "))
                    }
                }
                .frame(maxWidth: 215, alignment: .leading)
            }

            if let edition = inventory?.edition ?? activeEdition {
                Divider()
                sourceLine(edition)
            }
        }
        .padding(22)
        .background(PrismColors.panelFill, in: .rect(cornerRadius: 16))
    }

    private func credit(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.callout)
        }
        .accessibilityElement(children: .combine)
    }

    private func sourceLine(_ edition: TitleEdition) -> some View {
        let sourceEditions = editions
        return HStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title.kind == .movie ? (preferredID == nil ? "Édition par défaut" : "Édition préférée") : "Édition des épisodes")
                    .font(.callout.weight(.semibold))
                Text(Self.editionLabel(edition))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if sourceEditions.count > 1 {
                if title.kind == .series {
                    Menu("Changer d’édition", systemImage: "chevron.up.chevron.down") {
                        ForEach(sourceEditions) { candidate in
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
                    }
                    .menuStyle(.borderedButton)
                    .fixedSize()
                } else {
                    Button("Voir les éditions") { choosePlayback(episode: nil, alwaysShowPicker: true) }
                }
            }
        }
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
        playItem(option.playbackItem(for: title, position: position), .title(title.id), option.contentID)
    }

    private func loadProviderDetails() async {
        let candidates = editions
        let preferred = candidates.first { $0.id == preferredEditionID }
        let ordered = [preferred].compactMap { $0 } + candidates.filter { $0.id != preferred?.id }
        if title.kind == .movie {
            guard let edition = ordered.first, let movie = edition.variant.movie else { return }
            let detail = try? await app.detailRepository.movieDetail(movie, source: edition.source)
            if !Task.isCancelled { movieDetail = detail }
            return
        }

        failedToLoadEpisodes = false
        if inventory?.edition.id != ordered.first?.id {
            inventory = nil
            episodeInfo = [:]
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

    private func loadEpisodeInfo() async {
        guard isPageActive, let id = enriched?.tmdbID, let season = displayedSeason?.number else { return }
        episodeInfo = [:]
        let info = await app.metadataRepository.episodes(tmdbID: id, season: season)
        if !Task.isCancelled {
            episodeInfo = Dictionary(info.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        }
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
}
