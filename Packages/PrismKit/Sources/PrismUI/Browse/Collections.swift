import SwiftUI
import PrismCore
import PrismData
import PrismDesign

struct TitleGrid: View {
    let items: [MediaTitle]
    var availableWidth: CGFloat
    /// Numbers posters 1, 2, 3… (Top lists).
    var ranked = false

    var body: some View {
        let spacing: CGFloat = 20
        let contentWidth = max(140, availableWidth - 2 * PrismMetrics.contentMargin)
        let count = max(1, Int((contentWidth + spacing) / (145 + spacing)))
        let width = (contentWidth - CGFloat(count - 1) * spacing) / CGFloat(count)
        let rowCount = (items.count + count - 1) / count
        // Materialize whole rows rather than individual grid cells. Every card in a row has
        // the same vertical geometry, so one row-level entrance is pixel-identical to six
        // identical card-level transitions while keeping far less transition/layout state.
        LazyVStack(alignment: .leading, spacing: 28) {
            ForEach(0..<rowCount, id: \.self) { row in
                TitleGridRow(
                    items: items, row: row, columns: count, width: width,
                    contentWidth: contentWidth, spacing: spacing, ranked: ranked
                )
            }
        }
        .padding(.horizontal, PrismMetrics.contentMargin)
    }
}

/// One fixed-width row of `TitleGrid`. Cards keep their item identity inside the row; only
/// the row container is indexed, matching the stable row-major geometry of the old grid.
private struct TitleGridRow: View {
    let items: [MediaTitle]
    let row: Int
    let columns: Int
    let width: CGFloat
    let contentWidth: CGFloat
    let spacing: CGFloat
    let ranked: Bool

    var body: some View {
        let start = row * columns
        let end = min(items.count, start + columns)
        HStack(alignment: .top, spacing: spacing) {
            if ranked {
                // Rank is the global title position, not the row-local offset.
                ForEach(Array(items[start..<end].enumerated()), id: \.element.id) { localOffset, item in
                    BrowsePoster(item: item, width: width, rank: start + localOffset + 1, showsTitle: true)
                }
            } else {
                ForEach(items[start..<end]) { item in
                    BrowsePoster(item: item, width: width)
                }
            }
        }
        .frame(width: contentWidth, alignment: .leading)
        .rowEntrance()
    }
}

/// Keeps the last shelf visible while a playback checkpoint is resolved in the background.
struct ContinueWatchingContent<Content: View>: View {
    @Environment(AppModel.self) private var app
    @Environment(\.isPageActive) private var isActive
    @State private var items: [ContinueWatchingItem]?
    @State private var loadedRequest: Request?
    let limit: Int
    @ViewBuilder let content: ([ContinueWatchingItem]?) -> Content

    private struct Request: Equatable {
        let catalog: Int
        let library: Int
    }

    var body: some View {
        let catalogRevision = app.catalogRevision
        let request = isActive ? Request(catalog: catalogRevision, library: app.library.continueWatchingRevision) : nil
        content(loadedRequest?.catalog == catalogRevision ? items : nil)
            .task(id: request, priority: .utility) {
                guard let request, request != loadedRequest else { return }
                let updated = await app.library.loadContinueWatching(in: app.catalog, limit: limit)
                guard !Task.isCancelled, request.catalog == app.catalogRevision,
                      request.library == app.library.continueWatchingRevision else { return }
                loadedRequest = request
                items = updated
            }
    }
}

/// How a "Voir tout" page orders its titles.
enum CollectionSort: String, CaseIterable, Identifiable, Sendable {
    case relevance, rating, newest, recentlyAdded, title

    var id: String { rawValue }

    var label: String {
        switch self {
        case .relevance: "Pertinence"
        case .rating: "Mieux notés"
        case .newest: "Plus récents"
        case .recentlyAdded: "Derniers ajouts"
        case .title: "Titre (A à Z)"
        }
    }

    var systemImage: String {
        switch self {
        case .relevance: "sparkles"
        case .rating: "star"
        case .newest: "calendar"
        case .recentlyAdded: "clock"
        case .title: "textformat"
        }
    }
}

struct CollectionView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.isPageActive) private var isActive
    @State private var resolved: ResolvedItems?
    @State private var sort: CollectionSort = .relevance
    @State private var genre: String? = Self.allGenres
    @State private var arranged: Arranged?
    let collection: CollectionRoute

    nonisolated private static let allGenres = "all"

    private enum Request: Equatable {
        case catalog(Int)
        case recent(catalog: Int, curation: Int)
        case curated(CurationRequest)
    }

    private struct ResolvedItems {
        let request: Request
        let titles: [MediaTitle]
        let genres: [ChipItem]
    }

    /// The source list after sorting and filtering, tagged with what produced it.
    private struct Arranged {
        let key: ArrangeKey
        let titles: [MediaTitle]
    }

    private struct ArrangeKey: Equatable {
        let source: Int
        let sort: CollectionSort
        let genre: String?
    }

    var body: some View {
        if collection == .continueWatching {
            ContinueWatchingContent(limit: 80) { items in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        header(count: items?.count)
                        if let items {
                            if items.isEmpty {
                                emptyMessage
                            } else {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 20)], spacing: 20) {
                                    ForEach(items) { ResumeCard(item: $0).rowEntrance() }
                                }
                                .padding(.horizontal, PrismMetrics.contentMargin)
                            }
                        } else {
                            loadingIndicator
                        }
                    }
                    .padding(.vertical, 24)
                    .padding(.bottom, 28)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .prismScrollPhase()
            }
        } else {
            titlesPage
        }
    }

    private var titlesPage: some View {
        let request = isActive ? loadRequest : nil
        let source = items
        let key = source.map { ArrangeKey(source: sourceRevision($0), sort: sort, genre: genre) }
        let visible: [MediaTitle]? = if let source, let key {
            key.sort == .relevance && key.genre == Self.allGenres ? source : (arranged?.key == key ? arranged?.titles : nil)
        } else {
            nil
        }
        return GeometryReader { geometry in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    header(count: visible?.count)
                    if let genres = resolved?.genres, genres.count > 2 {
                        ChipBar(items: genres, selection: $genre)
                    }
                    if let titles = visible {
                        if titles.isEmpty {
                            emptyMessage
                        } else {
                            TitleGrid(items: titles, availableWidth: geometry.size.width, ranked: isRanking && sort == .relevance)
                                .id(key.map { "\($0.sort.rawValue)|\($0.genre ?? "")" })
                                .transition(.opacity)
                        }
                    } else {
                        loadingIndicator
                    }
                }
                .padding(.vertical, 24)
                .padding(.bottom, 28)
                .animation(PrismMotion.standard, value: key?.sort)
                .animation(PrismMotion.standard, value: key?.genre)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .prismScrollPhase()
        }
        .task(id: request) {
            guard let request, resolved?.request != request else { return }
            let titles: [MediaTitle]
            if case .curated(let query) = collection {
                titles = await app.collection(query)
            } else {
                titles = await Self.collect(collection, in: app.catalog, index: app.curationIndex)
            }
            guard !Task.isCancelled else { return }
            let genres = await Self.genreChips(for: titles, index: app.curationIndex, catalog: app.catalog)
            guard !Task.isCancelled else { return }
            resolved = ResolvedItems(request: request, titles: isRanking ? Array(titles.prefix(100)) : titles, genres: genres)
        }
        .task(id: key) {
            guard let source, let key, key.sort != .relevance || key.genre != Self.allGenres, arranged?.key != key else { return }
            let titles = await Self.arrange(
                source, sort: key.sort, genre: key.genre.flatMap { Int($0) }.flatMap(CanonicalGenre.init(rawValue:)),
                index: app.curationIndex, catalog: app.catalog
            )
            guard !Task.isCancelled else { return }
            arranged = Arranged(key: key, titles: titles)
        }
        .onChange(of: resolved?.genres.map(\.id)) { _, ids in
            if let genre, genre != Self.allGenres, ids?.contains(genre) != true { self.genre = Self.allGenres }
        }
    }

    private var loadingIndicator: some View {
        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 40)
    }

    private func header(count: Int?) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            BrowseHeading(title: title, subtitle: count.map(Self.countLabel))
            if collection != .continueWatching, (items?.count ?? 0) > 1 {
                Menu {
                    Picker("Trier par", selection: $sort) {
                        ForEach(CollectionSort.allCases) { option in
                            Label(option.label, systemImage: option.systemImage).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    GlassCapsuleLabel(title: sort.label, systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(GlassCapsuleStyle(style: .regular))
                .fixedSize()
                .help("Trier")
                .padding(.trailing, PrismMetrics.contentMargin)
            }
        }
    }

    private static func countLabel(_ count: Int) -> String {
        count == 1 ? "1 titre" : "\(count.formatted()) titres"
    }

    /// A Top list keeps its numbers while it is shown in its own order.
    private var isRanking: Bool {
        if case .curated(let query) = collection, query.facet == .top { return true }
        return false
    }

    /// Cheap identity of the source list: the arrangement is recomputed when the list changes.
    private func sourceRevision(_ titles: [MediaTitle]) -> Int {
        var hasher = Hasher()
        hasher.combine(titles.count)
        hasher.combine(titles.first?.id)
        hasher.combine(titles.last?.id)
        hasher.combine(app.catalogRevision)
        return hasher.finalize()
    }

    private var loadRequest: Request? {
        switch collection {
        case .category, .topRated, .related, .all, .watchlist:
            .catalog(app.catalogRevision)
        case .recentlyAdded:
            .recent(catalog: app.catalogRevision, curation: app.curationRevision)
        case .curated(let query):
            .curated(app.curationRequest(for: query.kind == .movie ? .movies : query.kind == .series ? .series : .home))
        case .continueWatching:
            nil
        }
    }

    private var title: String {
        switch collection {
        case .category(let id): app.catalog.categoryGroup(id)?.name ?? "Catégorie"
        case .recentlyAdded: "Ajouts récents"
        case .all(let kind): kind.sectionTitle
        case .topRated: "Les mieux notés"
        case .continueWatching: "Reprendre"
        case .watchlist: "Ma liste"
        case .related: "À voir aussi"
        case .curated(let query): query.facet == .top ? query.title.replacingOccurrences(of: "Top 10 des", with: "Classement des") : query.title
        }
    }

    private var items: [MediaTitle]? {
        switch collection {
        case .all(let kind): kind == .movie ? app.catalog.movies : app.catalog.series
        case .watchlist: app.library.watchlist.compactMap(app.catalog.title)
        case .continueWatching: []
        case .category, .recentlyAdded, .topRated, .related, .curated: resolved?.titles
        }
    }

    @concurrent private static func collect(_ collection: CollectionRoute, in catalog: Catalog, index: CurationIndex) async -> [MediaTitle] {
        switch collection {
        case .category(let id):
            catalog.categoryGroup(id).map(catalog.titles(in:)) ?? []
        case .recentlyAdded(let kind):
            // Newest first, without clips, cams and listings in scripts the user cannot read.
            (kind == .movie ? catalog.movies : catalog.series).prefix(3_000)
                .filter { index.signals(for: $0, in: catalog)?.isEligible ?? true }
        case .topRated(let kind):
            catalog.topRated(kind, limit: 200)
        case .related(let id):
            catalog.title(id).map { catalog.related(to: $0, limit: 80) } ?? []
        case .all(let kind):
            kind == .movie ? catalog.movies : catalog.series
        case .watchlist, .continueWatching, .curated: []
        }
    }

    /// Genre chips with counts, most common first. Lists too small or too uniform get none.
    @concurrent private static func genreChips(for titles: [MediaTitle], index: CurationIndex, catalog: Catalog) async -> [ChipItem] {
        guard titles.count >= 24 else { return [] }
        var counts = [Int](repeating: 0, count: CanonicalGenre.allCases.count)
        for (offset, title) in titles.enumerated() {
            if offset.isMultiple(of: 4_096), Task.isCancelled { return [] }
            guard let bits = index.signals(for: title, in: catalog)?.genres.rawValue else { continue }
            var remaining = bits
            while remaining != 0 {
                counts[remaining.trailingZeroBitCount] += 1
                remaining &= remaining - 1
            }
        }
        let minimum = max(4, titles.count / 50)
        let genres = CanonicalGenre.allCases
            .filter { $0 != .sport && counts[$0.rawValue] >= minimum && counts[$0.rawValue] < titles.count }
            .sorted { counts[$0.rawValue] > counts[$1.rawValue] }
            .prefix(12)
        guard genres.count >= 2 else { return [] }
        return [ChipItem(id: allGenres, title: "Tous")]
            + genres.map { ChipItem(id: String($0.rawValue), title: $0.label, count: counts[$0.rawValue]) }
    }

    /// Sorting compares precomputed keys: a localized comparison over 100 000 names takes seconds.
    @concurrent private static func arrange(
        _ titles: [MediaTitle], sort: CollectionSort, genre: CanonicalGenre?, index: CurationIndex, catalog: Catalog
    ) async -> [MediaTitle] {
        var pool = titles
        if let genre {
            pool = pool.filter { index.signals(for: $0, in: catalog)?.genres.contains(genre) == true }
        }
        guard !Task.isCancelled else { return [] }
        switch sort {
        case .relevance:
            return pool
        case .rating:
            let keys = pool.map { title -> Float in
                // Calibrated quality: perfect provider ratings with no audience behind them sink.
                if let quality = index.signals(for: title, in: catalog)?.quality, quality > 0 { return quality }
                return Float(title.rating ?? 0) * 0.6
            }
            return sorted(pool, keys: keys, by: >)
        case .newest:
            let keys = pool.map { title in (title.year ?? 0) * 1_000_000 + Int((title.addedAt?.timeIntervalSince1970 ?? 0) / 86_400) % 1_000_000 }
            return sorted(pool, keys: keys, by: >)
        case .recentlyAdded:
            let keys = pool.map { $0.addedAt?.timeIntervalSince1970 ?? 0 }
            return sorted(pool, keys: keys, by: >)
        case .title:
            let keys = pool.map { title -> String in
                let key = TitleNormalizer.key(title.title)
                // Names that start with digits or symbols go after the alphabet, as in Apple TV.
                return key.first.map { $0.isLetter } == true ? key : "~" + key
            }
            return sorted(pool, keys: keys, by: <)
        }
    }

    nonisolated private static func sorted<Key: Comparable>(_ titles: [MediaTitle], keys: [Key], by order: (Key, Key) -> Bool) -> [MediaTitle] {
        let indices = titles.indices.sorted { lhs, rhs in
            keys[lhs] != keys[rhs] ? order(keys[lhs], keys[rhs]) : lhs < rhs
        }
        return indices.map { titles[$0] }
    }

    private var emptyMessage: some View {
        ContentUnavailableView(
            collection == .watchlist ? "Votre liste est vide" : "Aucun titre disponible",
            systemImage: collection == .watchlist ? "bookmark" : "rectangle.stack",
            description: collection == .watchlist ? Text("Ajoutez des films et des séries depuis leur fiche.") : nil
        )
    }
}

struct HistoryScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.playPrismItem) private var play
    @State private var confirmingClear = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                HStack {
                    BrowseHeading(title: "Historique")
                    if !app.library.history.isEmpty {
                        Button("Effacer…", role: .destructive) { confirmingClear = true }
                            .padding(.trailing, PrismMetrics.contentMargin)
                    }
                }
                if app.library.history.isEmpty {
                    ContentUnavailableView("Aucune lecture récente", systemImage: "clock.arrow.circlepath",
                                           description: Text("Les programmes que vous lancez apparaîtront ici."))
                }
                ForEach(app.library.history) { entry in
                    if let item = item(entry) {
                        Button {
                            open(entry)
                        } label: {
                            HStack(spacing: 14) {
                                RemoteImage(url: item.artwork, size: CGSize(width: 80, height: 46),
                                            contentMode: item.isLive ? .fit : .fill,
                                            placeholderSeed: item.title, placeholderStyle: .monogram)
                                    .clipShape(.rect(cornerRadius: PrismMetrics.smallArtworkRadius))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).font(.headline)
                                    Text(entry.watchedAt, format: .dateTime.day().month(.wide).hour().minute())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: item.isLive ? "play.fill" : "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(9)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, PrismMetrics.contentMargin)
                    }
                }
            }
            .padding(.vertical, 24)
        }
        .prismScrollPhase()
        .confirmationDialog("Effacer l’historique de lecture ?", isPresented: $confirmingClear) {
            Button("Effacer l’historique", role: .destructive) { app.library.clearHistory() }
        }
    }

    private func item(_ entry: HistoryEntry) -> (title: String, artwork: URL?, isLive: Bool)? {
        switch entry.target {
        case .title(let id):
            app.catalog.title(id).map { ($0.title, $0.backdropURL ?? $0.posterURL, false) }
        case .channel(let id):
            app.catalog.channelGroup(id).map { ($0.name, $0.logoURL, true) }
        }
    }

    private func open(_ entry: HistoryEntry) {
        switch entry.target {
        case .title(let id): navigation.push(.title(id))
        case .channel(let id):
            guard let group = app.catalog.channelGroup(id),
                  let variant = group.variants.first(where: { $0.id == entry.lastContentID })
                    ?? LivePlayback.preferredVariant(in: group, library: app.library) else { return }
            play(LivePlayback.makeItem(group: group, variant: variant), entry.target, variant.id)
        }
    }
}
