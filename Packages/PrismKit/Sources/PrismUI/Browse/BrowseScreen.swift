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

    private func hero(in selection: RecommendationSelection) -> [MediaTitle] {
        guard let kind else { return Array(selection.highlights.prefix(5)) }
        let editorial = selection.highlights.lazy.filter { $0.kind == kind }
        if !editorial.isEmpty { return Array(editorial.prefix(5)) }
        return app.catalog.featured(limit: 16).lazy.filter { $0.kind == kind }.prefix(5).map(app.recommendations.named)
    }

    var body: some View {
        GeometryReader { geometry in
            let selection = app.recommendations.selection(for: app.homeAudioLanguages)
            let featured = hero(in: selection)
            let spotlightHeight = max(322, min(500, geometry.size.height * 0.55))
            let artworkSize = CGSize(width: max(1, geometry.size.width - 16), height: spotlightHeight)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if !featured.isEmpty {
                        HeroCarousel(
                            items: featured,
                            interval: isActive ? 9 : 0,
                            height: spotlightHeight,
                            index: $selectedHero
                        ) { title in
                            Spotlight(title: title, size: artworkSize)
                        }
                        .clipShape(.rect(cornerRadius: PrismMetrics.heroRadius))
                        .overlay(alignment: .topTrailing) {
                            if kind == nil {
                                HomeLanguageMenu()
                                    .environment(\.colorScheme, .dark)
                                    .padding(.top, 48)
                                    .padding(.trailing, 16)
                            }
                        }
                        .padding(.horizontal, 8)
                        .task(id: nextArtwork(in: featured, size: artworkSize)) {
                            guard isActive, let next = nextArtwork(in: featured, size: artworkSize) else { return }
                            _ = await ImagePipeline.shared.image(for: next.url, pixelSize: next.size, fitting: .fill)
                        }
                    } else {
                        HStack {
                            BrowseHeading(title: kind.map(\.sectionTitle) ?? "Accueil")
                            if kind == nil {
                                HomeLanguageMenu().padding(.trailing, PrismMetrics.contentMargin)
                            }
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

                    if kind == nil {
                        SportsHomeShelf()
                    }
                    editorialShelf("Le cinéma et les séries d’ici", titles: selection.french)
                    editorialShelf("Les incontournables américains", titles: selection.american)
                    editorialShelf("À découvrir", titles: selection.discoveries)
                    if kind == nil, !selection.hasEditorialTitles {
                        editorialShelf("À regarder dans vos sources", titles: selection.wellRated)
                    }
                    if kind == nil, featured.isEmpty, !app.catalog.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Aucune recommandation pour ces langues").font(.headline)
                            Text("Vous pouvez retrouver le catalogue complet dans Films, Séries et Rechercher.")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, PrismMetrics.contentMargin)
                    }

                    if let kind {
                        let categories = app.catalog.categoryGroups(kind)
                        if !categories.isEmpty {
                            Shelf(title: "Explorer les catégories", items: categories, sizing: .fixed(160), onHeaderTap: {
                                navigation.push(.collection(.all(kind)))
                            }) { category in
                                CategoryShortcut(category: category)
                            }
                        }
                        TitleShelf(title: "Ajouts récents", items: app.catalog.recentlyAdded(kind, limit: 22), action: {
                            navigation.push(.collection(.recentlyAdded(kind)))
                        })
                        TitleShelf(title: "Les mieux notés", items: app.catalog.topRated(kind, limit: 22), action: {
                            navigation.push(.collection(.topRated(kind)))
                        })
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
    }

    private func editorialShelf(_ title: String, titles: [MediaTitle]) -> some View {
        TitleShelf(title: title, items: titles.filter { kind == nil || $0.kind == kind })
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
            Label(languageLabel, systemImage: "character.bubble")
                .font(.subheadline.weight(.medium))
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .controlSize(.regular)
        .accessibilityLabel("Langues des recommandations")
        .accessibilityValue(languageLabel)
        .help("Choisir les langues de lecture des recommandations")
    }
}

private struct Spotlight: View {
    @Environment(AppModel.self) private var app
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.isPageActive) private var isActive
    let title: MediaTitle
    let size: CGSize

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HeroBackdrop(imageURL: title.backdropURL, seed: title.title, fallbackPosterURL: title.posterURL,
                         leadingScrim: 0.83, animates: isActive, artSize: size)
            VStack(alignment: .leading, spacing: 10) {
                Text(title.title)
                    .font(.system(size: 52, weight: .bold))
                    .tracking(-1.8)
                    .lineLimit(2)
                    .minimumScaleFactor(0.58)
                    .accessibilityAddTraits(.isHeader)
                Text(([title.kind == .series ? "Série" : "Film"] + (title.year.map { [String($0)] } ?? []) + Array(title.genres.prefix(2))).joined(separator: "  ·  "))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.82))
                if let plot = ProviderSynopsis.cleaned(title.plot) {
                    Text(plot).font(.callout).foregroundStyle(.white.opacity(0.86)).lineLimit(2)
                }
                HStack(spacing: 9) {
                    PrimaryCapsuleButton("Voir la fiche", height: 37, minWidth: 125) {
                        navigation.push(.title(title.id))
                    }
                    WatchlistButton(isAdded: app.library.isInWatchlist(title.id), size: 37) {
                        app.library.toggleWatchlist(title.id)
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: 420, alignment: .leading)
            .foregroundStyle(.white)
            .padding(.leading, 40)
            .padding(.trailing, 24)
            .padding(.bottom, 48)
        }
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

struct BrowsePoster: View {
    @Environment(AppModel.self) private var app
    @Environment(NavigationModel.self) private var navigation
    let item: MediaTitle
    var width: CGFloat? = nil

    var body: some View {
        let name = app.recommendations.named(item).title
        PosterCard(imageURL: item.posterURL, seed: name, title: name,
                   subtitle: item.year.map(String.init), showsTitle: true, width: width,
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
