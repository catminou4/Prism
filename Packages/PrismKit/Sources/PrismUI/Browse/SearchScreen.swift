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
        let request = SearchRequest(term: query.trimmingCharacters(in: .whitespacesAndNewlines),
                                    revision: app.catalogRevision, active: isActive)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                BrowseHeading(title: "Rechercher")
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
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
                .padding(14)
                .background(.fill.tertiary, in: .rect(cornerRadius: 13))
                .padding(.horizontal, PrismMetrics.contentMargin)

                if request.term.isEmpty {
                    TitleShelf(title: "À découvrir", items: app.recommendations.highlights)
                } else if let result, resultRequest == request {
                    if result.isEmpty {
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
                        .frame(maxWidth: .infinity)
                        .padding(24)
                }
            }
            .padding(.vertical, 24)
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
        .onChange(of: isActive, initial: true) { _, active in isFocused = active }
    }

    private struct SearchRequest: Equatable {
        let term: String
        let revision: Int
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
