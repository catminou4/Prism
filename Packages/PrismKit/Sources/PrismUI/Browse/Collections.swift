import SwiftUI
import PrismCore
import PrismData
import PrismDesign

struct TitleGrid: View {
    let items: [MediaTitle]
    var availableWidth: CGFloat

    var body: some View {
        let spacing: CGFloat = 20
        let contentWidth = max(140, availableWidth - 2 * PrismMetrics.contentMargin)
        let count = max(1, Int((contentWidth + spacing) / (145 + spacing)))
        let width = (contentWidth - CGFloat(count - 1) * spacing) / CGFloat(count)
        let columns = Array(repeating: GridItem(.fixed(width), spacing: spacing), count: count)
        LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
            ForEach(items) { item in
                BrowsePoster(item: item, width: width)
            }
        }
        .padding(.horizontal, PrismMetrics.contentMargin)
    }
}

struct CollectionView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.isPageActive) private var isActive
    @State private var resolved: ResolvedItems?
    let collection: CollectionRoute

    private enum Request: Equatable {
        case catalog(Int)
        case recent(catalog: Int, curation: Int)
        case curated(CurationRequest)
    }

    private struct ResolvedItems {
        let request: Request
        let titles: [MediaTitle]
    }

    var body: some View {
        let request = isActive ? loadRequest : nil
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    BrowseHeading(title: title)
                    if collection == .continueWatching {
                        let items = app.library.continueWatching(in: app.catalog, limit: 80)
                        if items.isEmpty {
                            emptyMessage
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 20)], spacing: 20) {
                                ForEach(items) { ResumeCard(item: $0) }
                            }
                            .padding(.horizontal, PrismMetrics.contentMargin)
                        }
                    } else if let titles = items {
                        if titles.isEmpty {
                            emptyMessage
                        } else {
                            TitleGrid(items: titles, availableWidth: geometry.size.width)
                        }
                    } else {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding(.vertical, 24)
                .padding(.bottom, 28)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
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
            resolved = ResolvedItems(request: request, titles: titles)
        }
    }

    private var loadRequest: Request? {
        switch collection {
        case .category, .topRated, .related:
            .catalog(app.catalogRevision)
        case .recentlyAdded:
            .recent(catalog: app.catalogRevision, curation: app.curationRevision)
        case .curated(let query):
            .curated(app.curationRequest(for: query.kind == .movie ? .movies : query.kind == .series ? .series : .home))
        case .all, .watchlist, .continueWatching:
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
        case .curated(let query): query.title
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
        case .all, .watchlist, .continueWatching, .curated: []
        }
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
