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

    private var hero: [MediaTitle] {
        let curated = app.recommendations.highlights.filter { kind == nil || $0.kind == kind }
        if !curated.isEmpty { return Array(curated.prefix(5)) }
        return Array(app.catalog.featured(limit: 16).lazy.filter { kind == nil || $0.kind == kind }.prefix(5))
    }

    var body: some View {
        GeometryReader { geometry in
            let featured = hero
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
                        .clipShape(.rect(cornerRadius: 15))
                        .padding(.horizontal, 8)
                        .task(id: nextArtwork(in: featured, size: artworkSize)) {
                            guard isActive, let next = nextArtwork(in: featured, size: artworkSize) else { return }
                            _ = await ImagePipeline.shared.image(for: next.url, pixelSize: next.size, fitting: .fill)
                        }
                    } else {
                        BrowseHeading(title: kind.map(\.sectionTitle) ?? "Accueil")
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

                    editorialShelf("Le cinéma et les séries d’ici", subtitle: "Une sélection française", titles: app.recommendations.french)
                    editorialShelf("Les incontournables américains", titles: app.recommendations.american)
                    editorialShelf("À découvrir", subtitle: "Des œuvres remarquées à l’international", titles: app.recommendations.discoveries)
                    if kind == nil {
                        editorialShelf("Les mieux notés", titles: app.recommendations.wellRated)
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
                    } else {
                        TitleShelf(title: "Derniers films ajoutés", items: app.catalog.recentlyAdded(.movie, limit: 16), action: {
                            navigation.push(.collection(.recentlyAdded(.movie)))
                        })
                        TitleShelf(title: "Dernières séries ajoutées", items: app.catalog.recentlyAdded(.series, limit: 16), action: {
                            navigation.push(.collection(.recentlyAdded(.series)))
                        })
                    }
                    if kind == nil, !app.catalog.channels.isEmpty {
                        Button("Voir les chaînes en direct", systemImage: "dot.radiowaves.left.and.right") {
                            navigation.select(.live)
                        }
                        .buttonStyle(.bordered)
                        .padding(.horizontal, PrismMetrics.contentMargin)
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
        }
    }

    private func editorialShelf(_ title: String, subtitle: String? = nil, titles: [MediaTitle]) -> some View {
        TitleShelf(title: title, subtitle: subtitle, items: titles.filter { kind == nil || $0.kind == kind })
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
                if let plot = title.plot, !plot.isEmpty {
                    Text(plot).font(.callout).foregroundStyle(.white.opacity(0.86)).lineLimit(2)
                }
                HStack(spacing: 9) {
                    PrimaryCapsuleButton("Voir la fiche", systemImage: "info.circle", height: 37) {
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
        PosterCard(imageURL: item.posterURL, seed: item.title, title: item.title,
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
                 caption: item.title.title, metadata: metadata, progress: item.progress?.fraction,
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
            .background(.fill.tertiary, in: .rect(cornerRadius: 14))
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
