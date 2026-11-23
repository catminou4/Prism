import Observation
import SwiftUI
import PrismCore
import PrismData
import PrismDesign

struct BrowseScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(NavigationModel.self) private var navigation
    @State private var motion = BrowseScrollActivity()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let kind: MediaKind?

    private var scope: CurationScope {
        switch kind {
        case .movie: .movies
        case .series: .series
        default: .home
        }
    }

    var body: some View {
        let feed = app.feed(for: scope)
        GeometryReader { geometry in
            let heroHeight = Self.heroHeight(for: geometry.size, home: kind == nil)
            let artworkSize = CGSize(width: max(1, geometry.size.width), height: heroHeight)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: PrismMetrics.shelfSpacing) {
                    if !feed.highlights.isEmpty {
                        // The carousel owns its page index: advancing it must not re-evaluate every shelf.
                        BrowseHero(highlights: feed.highlights, height: heroHeight, artworkSize: artworkSize, motion: motion)
                    } else {
                        HStack(alignment: .firstTextBaseline) {
                            BrowseHeading(title: kind?.sectionTitle ?? "Accueil")
                            HomeLanguageMenu().padding(.trailing, PrismMetrics.contentMargin)
                        }
                        .padding(.top, 52)
                    }

                    if kind == nil { HomeLibraryShelves() }
                    if app.catalog.isEmpty {
                        ContentUnavailableView("Catalogue vide", systemImage: "rectangle.stack",
                                               description: Text("Ajoutez ou actualisez une source pour retrouver vos programmes."))
                            .frame(maxWidth: .infinity)
                    } else if !app.hasFeed(for: scope) {
                        CurationPlaceholder()
                            .transition(.opacity)
                    }
                    curatedShelves(feed)
                    if !feed.genres.isEmpty {
                        GenreTileShelf(tiles: feed.genres, kind: kind)
                    }
                    if let kind { providerShelves(kind) }
                }
                .padding(.bottom, 48)
                // A new composition (first load, languages, a day later) cross-fades row by row
                // instead of popping.
                .animation(reduceMotion ? nil : PrismMotion.entrance, value: feed.shelves.map(\.id))
            }
            .scrollContentBackground(.hidden)
            .onScrollGeometryChange(for: Bool.self) { scroll in
                scroll.contentOffset.y + scroll.contentInsets.top <= 1
            } action: { _, atTop in
                motion.isAtTop = atTop
            }
            .prismScrollPhase { motion.isScrolling = $0 }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .background(alignment: .top) {
                BrowseOverscrollBackground(highlights: feed.highlights, motion: motion)
                    .frame(height: heroHeight)
            }
            .ignoresSafeArea(.container, edges: feed.highlights.isEmpty ? [] : .top)
        }
        .modifier(BrowseFeedRefresh(scope: scope))
    }

    /// Apple TV keeps the hero cinematic: most of the window on wide screens, never a letterbox.
    static func heroHeight(for size: CGSize, home: Bool) -> CGFloat {
        let ratio: CGFloat = home ? 0.66 : 0.7
        return min(max(size.height * ratio, 420, size.width * 0.36), 760)
    }

    @ViewBuilder private func curatedShelves(_ feed: CuratedFeed) -> some View {
        ForEach(feed.shelves) { shelf in
            CuratedShelfView(shelf: shelf)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 18)),
                    removal: .opacity.animation(PrismMotion.quickFade)
                ))
        }
    }

    @ViewBuilder private func providerShelves(_ kind: MediaKind) -> some View {
        let categories = app.catalog.categoryGroups(kind).filter { !$0.isAdult }
        if !categories.isEmpty {
            Shelf(title: "Catégories de vos sources", items: categories, sizing: .fixed(158), onHeaderTap: {
                navigation.push(.collection(.all(kind)))
            }) { category in
                CategoryShortcut(category: category)
            }
        }
    }

}

private struct BrowseFeedRefresh: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.isPageActive) private var isActive
    let scope: CurationScope

    func body(content: Content) -> some View {
        let request = isActive ? app.curationRequest(for: scope) : nil
        content.task(id: request) {
            if let request { await app.refreshFeed(request) }
        }
    }
}

private struct HomeLibraryShelves: View {
    @Environment(AppModel.self) private var app
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        ContinueWatchingContent(limit: 14) { watching in
            if let watching, !watching.isEmpty {
                Shelf(title: "Reprendre", items: watching, sizing: .wide, onHeaderTap: {
                    navigation.push(.collection(.continueWatching))
                }) { item in
                    ResumeCard(item: item)
                }
            }
        }
        SportsHomeShelf()
        let watchlist = app.library.watchlist.prefix(24).compactMap(app.catalog.title)
        if !watchlist.isEmpty {
            TitleShelf(title: "Ma liste", items: watchlist, action: { navigation.push(.collection(.watchlist)) })
        }
    }
}

@Observable private final class BrowseScrollActivity {
    var isScrolling = false
    var isAtTop = true
    var heroIndex = 0
}

private struct BrowseOverscrollBackground: View {
    let highlights: [CuratedHighlight]
    let motion: BrowseScrollActivity

    var body: some View {
        if motion.isAtTop, !highlights.isEmpty {
            let title = highlights[min(max(motion.heroIndex, 0), highlights.count - 1)].title
            BrowseHeroBackground(title: title)
        }
    }
}

private struct BrowseHeroBackground: View {
    @Environment(AppModel.self) private var app
    let title: MediaTitle

    var body: some View {
        HeroOverscrollBackground(
            backdropURLs: app.heroArtwork.backdropURLs(for: title),
            fallbackPosterURLs: app.heroArtwork.posterURLs(for: title), seed: title.id.rawValue
        )
        .id(title.id)
    }
}

/// Hero carousel of a browse page, with the next page's artwork decoded ahead of time.
private struct BrowseHero: View {
    @Environment(AppModel.self) private var app
    @Environment(\.isPageActive) private var isActive
    @Environment(\.displayScale) private var scale
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: Int? = 0
    @State private var isVisible = true
    let highlights: [CuratedHighlight]
    let height: CGFloat
    let artworkSize: CGSize
    let motion: BrowseScrollActivity

    var body: some View {
        let canAnimate = isActive && isVisible && !motion.isScrolling
        let preload = canAnimate && appearsActive && !reduceMotion ? nextArtwork : nil
        HeroCarousel(
            items: highlights, interval: canAnimate ? PrismMotion.heroInterval + 2 : 0,
            height: height, index: $selected, isInteractive: isActive, extendsUnderSidebar: true
        ) { highlight in
            HighlightPage(highlight: highlight, size: artworkSize, isActive: isActive && isVisible)
        }
        .background(alignment: .leading) {
            if isActive, isVisible, let title = currentTitle {
                // The sidebar samples only a static leading strip. Compositing the entire
                // carousel here would pull its text, transitions and controls into the effect.
                BrowseHeroBackground(title: title)
                    .frame(width: artworkSize.width, height: height)
                    .frame(width: min(artworkSize.width, PrismMetrics.sidebarWidth), alignment: .leading)
                    .clipped()
                    .backgroundExtensionEffect()
            }
        }
        .overlay(alignment: .topTrailing) {
            HomeLanguageMenu()
                .environment(\.colorScheme, .dark)
                .padding(.top, 14)
                .padding(.trailing, 18)
        }
        .onScrollVisibilityChange(threshold: 0.15) { isVisible = $0 }
        .onChange(of: selected, initial: true) { _, index in motion.heroIndex = index ?? 0 }
        .task(id: preload, priority: .utility) {
            guard let preload else { return }
            // Give visible artwork first use of network and decode slots after a gesture.
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await app.heroArtwork.resolve(preload.title, app: app)
            guard !Task.isCancelled, let url = app.heroArtwork.backdropURLs(for: preload.title).first else { return }
            _ = await ImagePipeline.shared.image(for: url, pixelSize: preload.size, fitting: .landscapeFill)
        }
        .onChange(of: app.homeAudioLanguages) { _, _ in selected = 0 }
    }

    private var pixelSize: CGSize { RemoteImage.pixelSize(forPointSize: artworkSize, scale: scale) }

    private var currentTitle: MediaTitle? {
        guard !highlights.isEmpty else { return nil }
        return highlights[min(max(selected ?? 0, 0), highlights.count - 1)].title
    }

    private struct Preload: Equatable {
        let title: MediaTitle
        let size: CGSize
        let enrichment: Bool

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.title.id == rhs.title.id && lhs.size == rhs.size && lhs.enrichment == rhs.enrichment
        }
    }

    private var nextArtwork: Preload? {
        guard highlights.count > 1 else { return nil }
        let current = min(max(selected ?? 0, 0), highlights.count - 1)
        let next = highlights[(current + 1) % highlights.count].title
        return Preload(title: next, size: pixelSize, enrichment: app.isMetadataEnabled)
    }
}

/// Shown while the first feed is composed (a fraction of a second on large catalogues).
private struct CurationPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PrismMetrics.shelfHeaderSpacing) {
            ShimmerPlaceholder().frame(width: 180, height: 18).clipShape(.capsule)
            HStack(spacing: PrismMetrics.cardSpacing) {
                ForEach(0..<7, id: \.self) { _ in
                    ShimmerPlaceholder()
                        .frame(width: 150, height: 225)
                        .clipShape(.rect(cornerRadius: PrismMetrics.posterRadius))
                }
            }
        }
        .padding(.horizontal, PrismMetrics.contentMargin)
        .accessibilityLabel("Préparation de la sélection")
    }
}

/// A shelf composed by `Curator`.
struct CuratedShelfView: View {
    @Environment(NavigationModel.self) private var navigation
    let shelf: CuratedShelf

    var body: some View {
        let open: (() -> Void)? = shelf.seeAll.map { query in { navigation.push(.collection(.curated(query))) } }
        switch shelf.style {
        case .ranked:
            RankedTitleShelf(title: shelf.title, subtitle: shelf.subtitle, items: shelf.items, action: open)
        case .poster:
            TitleShelf(title: shelf.title, subtitle: shelf.subtitle, items: shelf.items, action: open)
        }
    }
}

/// "Parcourir par genre": colourful tiles opening the genre's full ranking.
private struct GenreTileShelf: View {
    @Environment(NavigationModel.self) private var navigation
    let tiles: [GenreTile]
    let kind: MediaKind?

    var body: some View {
        Shelf(title: "Parcourir par genre", items: tiles, sizing: .columns(minWidth: 200)) { tile in
            CategoryTile(title: tile.genre.label, imageURL: tile.artworkURL, seed: tile.id, tint: tile.genre.tint, aspect: .wide) {
                navigation.push(.collection(.curated(CurationQuery(
                    kind: kind, facet: .genre(tile.genre), title: tile.genre.shelfTitle(for: kind)
                ))))
            }
        }
    }
}

extension CanonicalGenre {
    /// Stable tile colour per genre (artwork is washed with it).
    var tint: Color {
        switch self {
        case .action: Color(red: 0.78, green: 0.22, blue: 0.16)
        case .adventure: Color(red: 0.85, green: 0.47, blue: 0.12)
        case .animation, .family: Color(red: 0.16, green: 0.55, blue: 0.86)
        case .anime: Color(red: 0.86, green: 0.22, blue: 0.47)
        case .comedy: Color(red: 0.93, green: 0.62, blue: 0.1)
        case .crime: Color(red: 0.25, green: 0.27, blue: 0.36)
        case .documentary: Color(red: 0.18, green: 0.55, blue: 0.42)
        case .drama: Color(red: 0.45, green: 0.22, blue: 0.55)
        case .fantasy: Color(red: 0.42, green: 0.3, blue: 0.82)
        case .scienceFiction: Color(red: 0.1, green: 0.42, blue: 0.68)
        case .horror: Color(red: 0.36, green: 0.06, blue: 0.08)
        case .thriller: Color(red: 0.16, green: 0.2, blue: 0.3)
        case .romance: Color(red: 0.86, green: 0.3, blue: 0.42)
        case .war: Color(red: 0.38, green: 0.4, blue: 0.24)
        case .western: Color(red: 0.62, green: 0.38, blue: 0.18)
        case .history: Color(red: 0.55, green: 0.42, blue: 0.24)
        case .music: Color(red: 0.6, green: 0.2, blue: 0.72)
        case .reality: Color(red: 0.92, green: 0.36, blue: 0.3)
        case .standup: Color(red: 0.95, green: 0.5, blue: 0.2)
        case .sport: Color(red: 0.12, green: 0.5, blue: 0.3)
        }
    }
}

/// Recommendation languages, shown as a glass circle like Apple TV's hero controls.
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
            Picker("Proposer des titres en", selection: Binding(
                get: { app.homeAudioLanguages },
                set: { app.setHomeAudioLanguages($0) }
            )) {
                Text("Français et anglais").tag(HomeAudioLanguage.defaults)
                Text("Français").tag(Set([HomeAudioLanguage.french]))
                Text("Anglais").tag(Set([HomeAudioLanguage.english]))
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "character.bubble")
                .font(.system(size: 14, weight: .medium))
                .frame(width: PrismMetrics.toolbarButtonSize, height: PrismMetrics.toolbarButtonSize)
                .contentShape(.circle)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Langues des recommandations")
        .accessibilityValue(languageLabel)
        .help("Langues des recommandations : \(languageLabel)")
    }
}

/// One page of the curated hero: full-bleed artwork, label pill, title, facts, synopsis, actions.
private struct HighlightPage: View {
    @Environment(AppModel.self) private var app
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.playPrismItem) private var playItem
    let highlight: CuratedHighlight
    let size: CGSize
    let isActive: Bool
    /// Copy settles shortly after the artwork, one line after the other.
    @State private var revealed = false

    private var title: MediaTitle { highlight.title }
    private var resolved: HeroArtworkStore.Entry? { app.heroArtwork.entry(for: title.id) }
    private var metadata: TMDBMetadata? { resolved?.metadata }
    private var providerDetail: MovieDetail? { resolved?.providerDetail }
    private var synopsis: String? { resolved?.synopsis }

    private var facts: [String] {
        let genres: [String]
        if let named = metadata?.genres ?? providerDetail?.genres, !named.isEmpty {
            genres = named.prefix(2).map(DetailPresentation.genreLabel)
        } else if let signals = app.signals(for: title) {
            genres = signals.genres.genres.filter { $0 != .family }.prefix(2).map(\.label)
        } else {
            genres = title.genres.prefix(2).map(DetailPresentation.genreLabel)
        }
        return [title.kind == .series ? "Série" : "Film"] + (title.year.map { [String($0)] } ?? []) + genres
    }

    var body: some View {
        let quickPlay = title.kind == .movie ? QuickPlay.option(for: title, app: app) : nil
        ZStack(alignment: .bottomLeading) {
            HeroBackdrop(
                backdropURLs: app.heroArtwork.backdropURLs(for: title), seed: title.id.rawValue,
                fallbackPosterURLs: app.heroArtwork.posterURLs(for: title),
                leadingScrim: 0.72, artSize: size
            )
            VStack(alignment: .leading, spacing: 10) {
                if let label = highlight.label { LabelPill(label).staggeredReveal(revealed, order: 0) }
                TitleLogo(
                    url: metadata?.images.logoURL, fallbackTitle: title.title,
                    maxSize: CGSize(width: min(420, size.width * 0.4), height: min(120, size.height * 0.2))
                )
                .staggeredReveal(revealed, order: 1, distance: 18)
                HStack(spacing: 6) {
                    Text(facts.joined(separator: " · "))
                    if let rating = title.rating, rating > 0, rating < 9.6 {
                        Text("·")
                        Label(rating.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(PrismFont.heroMeta.weight(.medium))
                .foregroundStyle(PrismColors.onArtworkSecondary)
                .staggeredReveal(revealed, order: 2)
                if let synopsis {
                    Text(synopsis)
                        .font(PrismFont.heroBody)
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(3)
                        .lineSpacing(PrismFont.heroLineSpacing)
                        .transition(.opacity)
                        .staggeredReveal(revealed, order: 3)
                }
                HStack(spacing: PrismMetrics.heroButtonSpacing) {
                    if let quickPlay {
                        // `latestProgress` lit `library.progress` : on ne s'y
                        // abonne que quand la page est réellement visible, sinon
                        // chaque tick de lecture réévaluerait le héros caché.
                        let progress = isActive ? app.library.latestProgress(forTitle: title.id) : nil
                        let resumable = progress.map { !$0.isFinished && $0.position >= 5 } ?? false
                        PrimaryCapsuleButton(
                            resumable ? "Reprendre" : "Lecture", systemImage: "play.fill",
                            progress: resumable ? progress?.fraction : nil, minWidth: 150
                        ) {
                            QuickPlay.play(quickPlay, title: title, app: app, playItem: playItem)
                        }
                    } else {
                        PrimaryCapsuleButton(title.kind == .series ? "Voir les épisodes" : "En savoir plus",
                                             systemImage: title.kind == .series ? "play.rectangle" : "info.circle", minWidth: 150) {
                            navigation.push(.title(title.id))
                        }
                    }
                    WatchlistButton(isAdded: app.library.isInWatchlist(title.id)) {
                        app.library.toggleWatchlist(title.id)
                    }
                    if quickPlay != nil {
                        GlassCircleButton(systemName: "info", size: PrismMetrics.circleButtonSize, style: .dark,
                                          accessibilityLabel: "Voir la fiche") {
                            navigation.push(.title(title.id))
                        }
                        .help("Voir la fiche")
                    }
                }
                .padding(.top, 6)
                .staggeredReveal(revealed, order: 4)
            }
            .frame(maxWidth: min(460, size.width * 0.44), alignment: .leading)
            .foregroundStyle(.white)
            .padding(.leading, PrismMetrics.contentMargin)
            .padding(.trailing, 24)
            .padding(.bottom, 56)
        }
        .contentShape(.rect)
        .contextMenu { TitleContextMenu(title: title) }
        .onAppear { revealed = true }
        .task(id: ArtworkRequest(active: isActive, enrichmentEnabled: app.isMetadataEnabled)) {
            guard isActive else { return }
            await app.heroArtwork.resolve(title, app: app)
        }
    }

    private struct ArtworkRequest: Equatable {
        let active: Bool
        let enrichmentEnabled: Bool
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
    @Environment(\.isPageActive) private var isActive
    let title: String
    var subtitle: String? = nil
    let items: [MediaTitle]
    var action: (() -> Void)? = nil

    var body: some View {
        if !items.isEmpty {
            Shelf(title: title, subtitle: subtitle, items: items, posterCaptionHeight: PrismMetrics.posterCaptionHeight, onHeaderTap: action,
                  posterArtwork: isActive ? \.posterURL : nil) { item in
                BrowsePoster(item: item)
            }
        }
    }
}

/// Apple TV "Top 10" row: posters with large rank numerals.
struct RankedTitleShelf: View {
    @Environment(\.isPageActive) private var isActive
    let title: String
    var subtitle: String? = nil
    let items: [MediaTitle]
    var action: (() -> Void)? = nil

    private struct Entry: Identifiable {
        let rank: Int
        let title: MediaTitle
        var id: TitleID { title.id }
        var posterURL: URL? { title.posterURL }
    }

    var body: some View {
        Shelf(
            title: title, subtitle: subtitle,
            items: items.prefix(10).enumerated().map { Entry(rank: $0.offset + 1, title: $0.element) },
            posterCaptionHeight: 0, onHeaderTap: action, posterArtwork: isActive ? \.posterURL : nil
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
    /// Shelves of ranked posters hide names; ranked grids keep them.
    var showsTitle: Bool? = nil

    var body: some View {
        let name = app.recommendations.named(item).title
        PosterCard(imageURL: item.posterURL, seed: name, title: name,
                   subtitle: subtitle, showsTitle: showsTitle ?? (rank == nil), rank: rank, width: width,
                   action: { navigation.push(.title(item.id)) }) {
            TitleContextMenu(title: item)
        }
    }

    private var subtitle: String {
        let genres = app.signals(for: item)?.genres ?? []
        let genre = CanonicalGenre.allCases.first { $0 != .family && genres.contains($0) }?.label
        switch (item.year, genre) {
        case let (year?, genre?): return "\(year) · \(genre)"
        case let (year?, nil): return String(year)
        case let (nil, genre): return genre ?? ""
        }
    }
}

/// Shared actions for any title card: play, Ma liste, mark as seen, not interested.
struct TitleContextMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.playPrismItem) private var playItem
    let title: MediaTitle

    var body: some View {
        if QuickPlay.canPlay(title, app: app) {
            Button("Lecture", systemImage: "play.fill") {
                guard let option = QuickPlay.option(for: title, app: app) else { return }
                QuickPlay.play(option, title: title, app: app, playItem: playItem)
            }
        }
        Button("Voir la fiche", systemImage: "info.circle") { navigation.push(.title(title.id)) }
        Divider()
        if app.library.isInWatchlist(title.id) {
            Button("Retirer de Ma liste", systemImage: "minus.circle") { app.library.removeFromWatchlist(title.id) }
        } else {
            Button("Ajouter à Ma liste", systemImage: "plus.circle") { app.library.addToWatchlist(title.id) }
        }
        if title.kind == .movie, let variant = title.primary {
            let watched = title.variants.contains { app.library.isWatched($0.id) }
            Button(watched ? "Marquer comme non vu" : "Marquer comme vu", systemImage: watched ? "eye.slash" : "checkmark.circle") {
                if watched {
                    for variant in title.variants { app.library.markUnwatched(variant.id) }
                } else {
                    app.library.markWatched(variant.id, titleID: title.id)
                }
            }
        }
        Divider()
        if app.library.isDismissed(title.id) {
            Button("Proposer à nouveau", systemImage: "arrow.uturn.backward") { app.library.undismiss(title.id) }
        } else {
            Button("Pas intéressé", systemImage: "hand.thumbsdown") {
                withAnimation(PrismMotion.standard) { app.library.dismiss(title.id) }
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
