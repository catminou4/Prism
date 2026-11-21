import SwiftUI
import PrismCore
import PrismData
import PrismDesign

struct BrowseScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.isPageActive) private var isActive
    let kind: MediaKind?

    private var hero: [MediaTitle] {
        let curated = app.recommendations.highlights.filter { kind == nil || $0.kind == kind }
        let featured = app.catalog.featured(limit: 16).filter { kind == nil || $0.kind == kind }
        return Array((curated.isEmpty ? featured : curated).prefix(5))
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    if !hero.isEmpty {
                        HeroCarousel(
                            items: hero,
                            interval: isActive ? 9 : 0,
                            height: max(330, min(520, geometry.size.height * 0.56))
                        ) { title in
                            Spotlight(title: title)
                        }
                        .clipShape(.rect(cornerRadius: 25))
                        .padding(.horizontal, 28)
                    } else {
                        BrowseHeading(title: kind.map(\.sectionTitle) ?? "Accueil")
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
                        if !app.catalog.channels.isEmpty {
                            Button {
                                navigation.select(.live)
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "dot.radiowaves.left.and.right")
                                        .font(.title2)
                                        .foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("TV en direct").font(.headline)
                                        Text("\(app.catalog.channels.count.formatted()) chaînes")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }
                                .padding(17)
                                .background(.fill.tertiary, in: .rect(cornerRadius: 14))
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, PrismMetrics.contentMargin)
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
                    if app.catalog.isEmpty {
                        ContentUnavailableView("Catalogue vide", systemImage: "rectangle.stack",
                                               description: Text("Ajoutez ou actualisez une source pour retrouver vos programmes."))
                    }
                }
                .padding(.top, 14)
                .padding(.bottom, 48)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
    }

    private func editorialShelf(_ title: String, subtitle: String? = nil, titles: [MediaTitle]) -> some View {
        TitleShelf(title: title, subtitle: subtitle, items: titles.filter { kind == nil || $0.kind == kind })
    }
}

private struct Spotlight: View {
    @Environment(AppModel.self) private var app
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.isPageActive) private var isActive
    let title: MediaTitle

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HeroBackdrop(imageURL: title.backdropURL, seed: title.title, fallbackPosterURL: title.posterURL,
                         leadingScrim: 0.92, animates: isActive)
            LinearGradient(colors: [Color(red: 0.075, green: 0.07, blue: 0.18).opacity(0.91), .clear],
                           startPoint: .bottomLeading, endPoint: .topTrailing)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    PrismLogoMark(size: 19)
                        .accessibilityHidden(true)
                    Text("À l’affiche")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.84))
                }
                Text(title.title)
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .tracking(-2)
                    .lineLimit(2)
                    .minimumScaleFactor(0.58)
                    .accessibilityAddTraits(.isHeader)
                Text(([title.kind == .series ? "Série" : "Film"] + (title.year.map { [String($0)] } ?? []) + Array(title.genres.prefix(2))).joined(separator: "  ·  "))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.82))
                if let plot = title.plot, !plot.isEmpty {
                    Text(plot).font(.callout).foregroundStyle(.white.opacity(0.86)).lineLimit(2)
                }
                HStack(spacing: 12) {
                    Button {
                        navigation.push(.title(title.id))
                    } label: {
                        Label("Voir la fiche", systemImage: "arrow.right")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 17)
                            .frame(height: 38)
                            .foregroundStyle(.black)
                            .background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Button {
                        app.library.toggleWatchlist(title.id)
                    } label: {
                        Image(systemName: app.library.isInWatchlist(title.id) ? "checkmark" : "plus")
                            .font(.callout.weight(.semibold))
                            .frame(width: 38, height: 38)
                            .contentTransition(.symbolEffect(.replace))
                            .prismGlass(.dark, in: .circle, interactive: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(app.library.isInWatchlist(title.id) ? "Retirer de Ma liste" : "Ajouter à Ma liste")
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: 480, alignment: .leading)
            .foregroundStyle(.white)
            .padding(.leading, 46)
            .padding(.trailing, 24)
            .padding(.bottom, 56)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 25)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

struct BrowseHeading: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 37, weight: .bold, design: .rounded))
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
    @Environment(NavigationModel.self) private var navigation
    let item: ContinueWatchingItem

    var body: some View {
        WideCard(imageURL: item.episode?.stillURL ?? item.title.backdropURL ?? item.title.posterURL,
                 caption: item.title.title, metadata: metadata, progress: item.progress?.fraction,
                 action: { navigation.push(.title(item.title.id)) })
    }

    private var metadata: String {
        let episode = item.episode.map { "S\($0.season) · É\($0.number)" }
        let remainder = item.progress.map { "\(max(1, Int($0.remaining / 60))) min restantes" }
        return [episode, remainder].compactMap { $0 }.joined(separator: " · ")
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
