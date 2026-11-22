import SwiftUI
import PrismCore
import PrismData
import PrismDesign

struct SearchScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.isPageActive) private var isActive
    @FocusState private var isFocused: Bool
    @State private var query = ""
    @State private var result: SearchResults?
    @State private var resultRequest: SearchRequest?

    var body: some View {
        let request = SearchRequest(
            term: query.trimmingCharacters(in: .whitespacesAndNewlines),
            revision: app.catalogRevision, indexReady: app.searchIndex != nil, active: isActive
        )
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                BrowseHeading(title: "Rechercher")
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Films, séries ou chaînes", text: $query)
                        .textFieldStyle(.plain)
                        .focused($isFocused)
                        .accessibilityLabel("Rechercher dans le catalogue")
                    if !query.isEmpty {
                        Button("Effacer", systemImage: "xmark.circle.fill") { query = "" }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                    }
                }
                .font(.system(size: 16))
                .padding(.horizontal, 16)
                .frame(height: 42)
                .prismGlass(.regular, in: .capsule)
                .frame(maxWidth: 610, alignment: .leading)
                .padding(.horizontal, PrismMetrics.contentMargin)

                if request.term.isEmpty {
                    SearchBrowseGrid(tiles: app.feed(for: .home).genres)
                    TitleShelf(
                        title: "À découvrir",
                        items: app.recommendations.selection(for: app.homeAudioLanguages).highlights
                    )
                } else if let result, resultRequest?.revision == request.revision {
                    if result.isEmpty, resultRequest?.term == request.term {
                        ContentUnavailableView.search(text: request.term)
                    }
                    TitleShelf(title: "Films", items: result.movies)
                    TitleShelf(title: "Séries", items: result.series)
                    if !result.channels.isEmpty {
                        Shelf(title: "Chaînes", items: result.channels, sizing: .wide) { channel in
                            SearchChannelCard(channel: channel)
                        }
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(request.indexReady ? "Recherche en cours" : "Préparation de la recherche")
                        .frame(maxWidth: .infinity)
                        .padding(24)
                }
            }
            .padding(.vertical, 24)
        }
        .task(id: isActive ? app.catalogRevision : nil, priority: .utility) {
            if isActive { app.prepareSearchIndex() }
        }
        .task(id: request) {
            guard request.active, !request.term.isEmpty, let index = app.searchIndex else { return }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let updated = await Self.lookup(request.term, in: index)
            guard !Task.isCancelled else { return }
            result = updated
            resultRequest = request
        }
        .task(id: isActive ? app.curationRequest(for: .home) : nil) {
            // The genre grid comes from the home feed, composed here if Accueil was never opened.
            if isActive { await app.refreshFeed(app.curationRequest(for: .home)) }
        }
        .onChange(of: isActive, initial: true) { _, active in isFocused = active }
        .onChange(of: request.term) { _, term in
            if term.isEmpty {
                result = nil
                resultRequest = nil
            }
        }
    }

    private struct SearchRequest: Equatable {
        let term: String
        let revision: Int
        let indexReady: Bool
        let active: Bool
    }

    @concurrent
    private static func lookup(_ query: String, in index: SearchIndex) async -> SearchResults {
        index.search(query, limit: 50)
    }
}

private struct SearchChannelCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.playPrismItem) private var play
    let channel: ChannelGroup

    var body: some View {
        WideCard(imageURL: nil, caption: channel.name, isLive: true, logoURL: channel.logoURL, action: {
            guard let variant = LivePlayback.preferredVariant(in: channel, library: app.library) else { return }
            play(LivePlayback.makeItem(group: channel, variant: variant, program: nil), .channel(groupID: channel.id), variant.id)
        })
    }
}

/// Apple TV's "Parcourir": portrait genre tiles washed with the genre colour.
private struct SearchBrowseGrid: View {
    @Environment(NavigationModel.self) private var navigation
    @State private var width: CGFloat = 0
    let tiles: [GenreTile]

    var body: some View {
        if !tiles.isEmpty {
            let spacing: CGFloat = 20
            let available = max(0, width - PrismMetrics.contentMargin * 2)
            let columns = max(2, Int((available + spacing) / (150 + spacing)))
            let tileWidth = max(120, ((available - spacing * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down))
            VStack(alignment: .leading, spacing: PrismMetrics.shelfHeaderSpacing) {
                ShelfHeader("Parcourir") { EmptyView() }
                    .padding(.horizontal, PrismMetrics.contentMargin)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(tileWidth), spacing: spacing), count: columns),
                          alignment: .leading, spacing: spacing) {
                    ForEach(tiles.prefix(columns * 2)) { tile in
                        CategoryTile(
                            title: tile.genre.label, imageURL: tile.artworkURL, seed: tile.id, tint: tile.genre.tint,
                            aspect: .poster, width: tileWidth
                        ) {
                            navigation.push(.collection(.curated(CurationQuery(
                                kind: nil, facet: .genre(tile.genre), title: tile.genre.shelfTitle(for: nil)
                            ))))
                        }
                    }
                }
                .padding(.horizontal, PrismMetrics.contentMargin)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
            .opacity(width > 0 ? 1 : 0)
        }
    }
}
