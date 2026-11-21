import SwiftUI
import PrismCore
import PrismData
import PrismDesign

struct BrowseScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.isPageActive) private var isActive
    @Environment(\.displayScale) private var scale
    @State private var selectedHero: Int? = 0
    let kind: MediaKind?

    private func hero(in selection: RecommendationSelection, discovery: DiscoveryShelves?) -> [MediaTitle] {
        guard let kind else { return Array(selection.highlights.prefix(5)) }
        let editorial = [selection.french, selection.american, selection.discoveries].map { shelf in
            shelf.filter { $0.kind == kind && $0.backdropURL != nil }
        }
        let leads = (0..<3).flatMap { index in
            editorial.compactMap { $0.indices.contains(index) ? $0[index] : nil }
        }
        let candidates = (discovery?.trending ?? []) + leads
            + (discovery?.recommended ?? []) + (discovery?.localHighlights ?? [])
        var seen: Set<TitleID> = []
        var result: [MediaTitle] = []
        for title in candidates where seen.insert(title.id).inserted {
            guard title.backdropURL != nil || title.posterURL != nil else { continue }
            result.append(title)
            if result.count == 5 { break }
        }
        return result
    }

    var body: some View {
        let request = isActive ? kind.map { app.discoveryRequest(for: $0) } : nil
        GeometryReader { geometry in
            let selection = app.recommendations.selection(for: app.homeAudioLanguages)
            let discovery = kind.map { app.discovery(for: $0) }
            let featured = hero(in: selection, discovery: discovery)
            let spotlightHeight = min(610, max(356, geometry.size.height * 0.60, geometry.size.width * 0.37))
            let artworkSize = CGSize(width: max(1, geometry.size.width - 24), height: spotlightHeight)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    if !featured.isEmpty {
                        HeroCarousel(
                            items: featured,
                            interval: isActive ? 12 : 0,
                            height: spotlightHeight,
                            index: $selectedHero,
                            isInteractive: isActive
                        ) { title in
                            Spotlight(title: title, size: artworkSize)
                        }
                        .clipShape(.rect(cornerRadius: PrismMetrics.heroRadius))
                        .overlay(alignment: .topTrailing) {
                            browseControls(style: .dark)
                                .environment(\.colorScheme, .dark)
                                .padding(.top, 47)
                                .padding(.trailing, 21)
                        }
                        .padding(.horizontal, 12)
                        .task(id: nextArtwork(in: featured, size: artworkSize)) {
                            guard isActive, let next = nextArtwork(in: featured, size: artworkSize) else { return }
                            _ = await ImagePipeline.shared.image(for: next.url, pixelSize: next.size, fitting: .landscapeFill)
                        }
                    } else {
                        HStack {
                            BrowseHeading(title: kind.map(\.sectionTitle) ?? "Accueil")
                            browseControls(style: .regular)
                                .padding(.trailing, PrismMetrics.contentMargin)
                        }
                        .padding(.top, 20)
                    }

                    if kind == nil {
                        let watching = app.library.continueWatching(in: app.catalog, limit: 14)
                        if !watching.isEmpty {
                            Shelf(title: "Reprendre", items: watching, sizing: .wide, onHeaderTap: {
                                navigation.push(.collection(.continueWatching))
                            }) { item in
                                ResumeCard(item: item)
                            }
                        }
                    }

                    if let kind {
                        sectionShelves(kind: kind, selection: selection, discovery: discovery)
                    } else {
                        homeShelves(selection: selection)
                    }
                    if app.catalog.isEmpty {
                        ContentUnavailableView("Catalogue vide", systemImage: "rectangle.stack",
                                               description: Text("Ajoutez ou actualisez une source pour retrouver vos programmes."))
                    }
                }
                .padding(.top, featured.isEmpty ? 0 : 8)
                .padding(.bottom, 48)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .ignoresSafeArea(.container, edges: featured.isEmpty ? [] : .top)
            .onChange(of: app.homeAudioLanguages) { _, _ in selectedHero = 0 }
        }
        .task(id: request) {
            if let request { await app.refreshDiscovery(request) }
        }
    }

    private func browseControls(style: PrismGlassStyle) -> some View {
        HStack(spacing: 8) {
            if let kind { BrowseCatalogMenu(kind: kind, style: style) }
            HomeLanguageMenu(style: style)
        }
    }

    @ViewBuilder private func homeShelves(selection: RecommendationSelection) -> some View {
        SportsHomeShelf()
        TitleShelf(title: "Le cinéma et les séries d’ici", items: selection.french)
        TitleShelf(title: "Les incontournables américains", items: selection.american)
        TitleShelf(title: "À découvrir", items: selection.discoveries)
        if !selection.hasEditorialTitles {
            TitleShelf(title: "À regarder dans vos sources", items: selection.wellRated)
        }
        if selection.highlights.isEmpty, !app.catalog.isEmpty {
            ContentUnavailableView(
                "Aucune recommandation pour ces langues",
                systemImage: "character.bubble",
                description: Text("Parcourez le catalogue dans Films, Séries ou Rechercher.")
            )
        }
    }

    @ViewBuilder private func sectionShelves(
        kind: MediaKind, selection: RecommendationSelection, discovery: DiscoveryShelves?
    ) -> some View {
        let trending = discovery?.trending ?? []
        let recentPicks = discovery?.localHighlights ?? []
        let recommended = discovery?.recommended ?? []
        let suggested = Set((trending + recommended + recentPicks).map(\.id))
        let curated = (selection.french + selection.american + selection.discoveries).filter {
            $0.kind == kind && !suggested.contains($0.id)
        }
        if !trending.isEmpty {
            RankedTitleShelf(items: trending)
        }
        TitleShelf(title: "Recommandés pour vous", items: recommended)
        TitleShelf(title: "En vue dans vos sources", items: recentPicks)
        TitleShelf(title: "Sélection de Prism", items: curated)

        let categories = app.catalog.categoryGroups(kind)
        if !categories.isEmpty {
            Shelf(title: "Explorer les catégories", items: categories, sizing: .fixed(158)) { category in
                CategoryShortcut(category: category)
            }
        }
        TitleShelf(title: "Ajouts dans vos sources", items: app.catalog.recentlyAdded(kind, limit: 18), action: {
            navigation.push(.collection(.recentlyAdded(kind)))
        })
    }

    private struct Preload: Equatable {
        let url: URL
        let size: CGSize
    }

    private func nextArtwork(in titles: [MediaTitle], size: CGSize) -> Preload? {
        guard isActive, titles.count > 1 else { return nil }
        let next = titles[(min(selectedHero ?? 0, titles.count - 1) + 1) % titles.count]
        guard let url = next.backdropURL else { return nil }
        return Preload(url: url, size: RemoteImage.pixelSize(forPointSize: size, scale: scale))
    }
}

private struct HomeLanguageMenu: View {
    @Environment(AppModel.self) private var app
    let style: PrismGlassStyle

    private var languageLabel: String {
        switch app.homeAudioLanguages {
        case [.french]: "Français"
        case [.english]: "Anglais"
        default: "Français et anglais"
        }
    }

    var body: some View {
        Menu {
            Picker("Langues des recommandations", selection: Binding(
                get: { app.homeAudioLanguages },
                set: { app.setHomeAudioLanguages($0) }
            )) {
                Text("Français et anglais").tag(HomeAudioLanguage.defaults)
                Text("Français").tag(Set([HomeAudioLanguage.french]))
                Text("Anglais").tag(Set([HomeAudioLanguage.english]))
            }
            .pickerStyle(.inline)
        } label: {
            GlassCapsuleLabel(title: languageLabel, systemImage: "character.bubble")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(GlassCapsuleStyle(style: style))
        .accessibilityLabel("Langues des recommandations")
        .accessibilityValue(languageLabel)
        .help("Choisir les langues de lecture des recommandations")
    }
}

private struct BrowseCatalogMenu: View {
    @Environment(NavigationModel.self) private var navigation
    let kind: MediaKind
    let style: PrismGlassStyle

    var body: some View {
        Menu {
            Button(kind == .movie ? "Tous les films" : "Toutes les séries", systemImage: "square.grid.2x2") {
                navigation.push(.collection(.all(kind)))
            }
            Button("Ajouts récents", systemImage: "clock") {
                navigation.push(.collection(.recentlyAdded(kind)))
            }
            Button("Les mieux notés", systemImage: "star") {
                navigation.push(.collection(.topRated(kind)))
            }
        } label: {
            GlassCapsuleLabel(title: "Catalogue", systemImage: "square.grid.2x2")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(GlassCapsuleStyle(style: style))
    }
}

private struct Spotlight: View {
    @Environment(AppModel.self) private var app
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.isPageActive) private var isActive
    @State private var metadata: TMDBMetadata?
    @State private var synopsis: String?
    let title: MediaTitle
    let size: CGSize

    private var leadVariants: ArraySlice<MediaVariant> { title.variants.prefix(12) }

    private var backdropURLs: [URL] {
        [metadata?.images.backdropURL, title.backdropURL].compactMap { $0 }
            + leadVariants.compactMap { $0.movie?.backdropURL ?? $0.series?.backdropURL }
    }

    private var posterURLs: [URL] {
        [metadata?.images.posterURL, title.posterURL].compactMap { $0 }
            + leadVariants.compactMap { $0.movie?.posterURL ?? $0.series?.posterURL }
    }

    private var facts: String {
        let genres = (metadata?.genres ?? title.genres).prefix(2).map(DetailPresentation.genreLabel)
        return ([title.kind == .series ? "Série" : "Film"] + (title.year.map { [String($0)] } ?? []) + genres)
            .joined(separator: "  ·  ")
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HeroBackdrop(
                backdropURLs: backdropURLs, seed: title.id.rawValue, fallbackPosterURLs: posterURLs,
                leadingScrim: 0.67, animates: isActive, artSize: size
            )
            VStack(alignment: .leading, spacing: 9) {
                TitleLogo(
                    url: metadata?.images.logoURL, fallbackTitle: metadata?.title ?? title.title,
                    maxSize: CGSize(width: min(400, size.width * 0.42), height: min(104, size.height * 0.22))
                )
                Text(facts)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(PrismColors.onArtworkSecondary)
                if let synopsis {
                    Text(synopsis).font(.callout)
                        .foregroundStyle(.white.opacity(0.94))
                        .lineLimit(2)
                        .lineSpacing(2)
                }
                HStack(spacing: 9) {
                    PrimaryCapsuleButton("Voir la fiche", systemImage: "info.circle", height: 38, minWidth: 126) {
                        navigation.push(.title(title.id))
                    }
                    WatchlistButton(isAdded: app.library.isInWatchlist(title.id), size: 38) {
                        app.library.toggleWatchlist(title.id)
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: min(488, size.width * 0.47), alignment: .leading)
            .foregroundStyle(.white)
            .padding(.leading, PrismMetrics.contentMargin - 12)
            .padding(.trailing, 24)
            .padding(.bottom, size.height >= 440 ? 58 : 50)
        }
        .task(id: ArtworkRequest(active: isActive, enrichmentEnabled: app.isMetadataEnabled, revision: app.catalogRevision)) {
            guard isActive else { return }
            let candidates = [title.plot] + leadVariants.map { $0.movie?.plot ?? $0.series?.plot }
            let initial = await Self.preferredSynopsis(candidates)
            guard !Task.isCancelled else { return }
            synopsis = initial
            guard app.isMetadataEnabled else {
                metadata = nil
                return
            }
            let newMetadata = await app.metadataRepository.metadata(for: title)
            let enrichedSynopsis = await Self.preferredSynopsis([newMetadata?.overview] + candidates)
            guard !Task.isCancelled else { return }
            metadata = newMetadata
            synopsis = enrichedSynopsis
        }
    }

    private struct ArtworkRequest: Equatable {
        let active: Bool
        let enrichmentEnabled: Bool
        let revision: Int
    }

    @concurrent private static func preferredSynopsis(_ candidates: [String?]) async -> String? {
        ProviderSynopsis.preferredFrenchOrEnglish(from: candidates)
    }
}

struct BrowseHeading: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 36, weight: .bold))
                .tracking(-1)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PrismMetrics.contentMargin)
    }
}

struct TitleShelf: View {
    let title: String
    var subtitle: String? = nil
    let items: [MediaTitle]
    var action: (() -> Void)? = nil

    var body: some View {
        if !items.isEmpty {
            Shelf(title: title, subtitle: subtitle, items: items, onHeaderTap: action) { item in
                BrowsePoster(item: item)
            }
        }
    }
}

private struct RankedTitleShelf: View {
    let items: [MediaTitle]

    private struct Entry: Identifiable {
        let rank: Int
        let title: MediaTitle
        var id: TitleID { title.id }
    }

    var body: some View {
        Shelf(
            title: "Tendances de la semaine",
            subtitle: "Classement TMDB des titres disponibles",
            items: items.prefix(10).enumerated().map { Entry(rank: $0.offset + 1, title: $0.element) }
        ) { entry in
            BrowsePoster(item: entry.title, rank: entry.rank)
        }
    }
}

struct BrowsePoster: View {
    @Environment(AppModel.self) private var app
    @Environment(NavigationModel.self) private var navigation
    let item: MediaTitle
    var width: CGFloat? = nil
    var rank: Int? = nil

    var body: some View {
        let name = rank == nil ? app.recommendations.named(item).title : item.title
        PosterCard(imageURL: item.posterURL, seed: name, title: name,
                   subtitle: item.year.map(String.init), showsTitle: true, rank: rank, width: width,
                   action: { navigation.push(.title(item.id)) }) {
            Button(app.library.isInWatchlist(item.id) ? "Retirer de Ma liste" : "Ajouter à Ma liste") {
                app.library.toggleWatchlist(item.id)
            }
        }
    }
}

struct ResumeCard: View {
    @Environment(AppModel.self) private var app
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.playPrismItem) private var playItem
    let item: ContinueWatchingItem

    var body: some View {
        WideCard(imageURL: item.episode?.stillURL ?? item.title.backdropURL ?? item.title.posterURL,
                 caption: app.recommendations.named(item.title).title, metadata: metadata, progress: item.progress?.fraction,
                 action: resume) {
            Button("Voir la fiche") { navigation.push(.title(item.title.id)) }
        }
    }

    private var metadata: String {
        let episode = item.episode.map { "S\($0.season) · É\($0.number)" }
        let remainder = item.progress.map { "\(max(1, Int($0.remaining / 60))) min" }
        return [episode, remainder].compactMap { $0 }.joined(separator: " · ")
    }

    private func resume() {
        let editionID = item.episode?.seriesID ?? item.contentID
        guard let variant = item.title.variants.first(where: { $0.id == editionID }),
              let source = app.source(variant.sourceID), source.isEnabled,
              let option = TitlePlaybackOption(edition: TitleEdition(variant: variant, source: source), episode: item.episode)
        else {
            navigation.push(.title(item.title.id))
            return
        }
        let position = option.resumePosition(exact: item.progress, equivalent: nil)
        playItem(option.playbackItem(for: item.title, position: position), .title(item.title.id), option.contentID,
                 seriesEditionID: item.episode?.seriesID)
    }
}

private struct CategoryShortcut: View {
    @Environment(NavigationModel.self) private var navigation
    let category: CategoryGroup

    var body: some View {
        Button {
            navigation.push(.collection(.category(groupID: category.id)))
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: category.kind == .movie ? "film.stack" : "rectangle.stack")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.tint)
                Spacer(minLength: 0)
                Text(category.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(category.itemCount.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 71)
            .padding(14)
            .background(.fill.tertiary, in: .rect(cornerRadius: PrismMetrics.tileRadius))
        }
        .buttonStyle(.plain)
    }
}

extension MediaKind {
    var sectionTitle: String {
        switch self {
        case .live: "TV en direct"
        case .movie: "Films"
        case .series: "Séries"
        case .episode: "Épisodes"
        }
    }
}
