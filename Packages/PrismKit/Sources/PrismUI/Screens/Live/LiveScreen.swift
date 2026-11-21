import Foundation
import SwiftUI
import PrismCore
import PrismData
import PrismDesign

public struct LiveScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.playPrismItem) private var playItem
    @Environment(\.isPageActive) private var isPageActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var mode: Mode = .channels
    @State private var category = Selection.all
    @State private var query = ""
    @State private var results: [ChannelGroup]?
    @State private var guideStart: Date?

    private let favoritesOnly: Bool

    public init(favoritesOnly: Bool = false) {
        self.favoritesOnly = favoritesOnly
    }

    private enum Mode: String, Hashable {
        case channels, guide
    }

    private nonisolated enum Selection {
        static let all = "live.all"
        static let favorites = "live.favorites"
    }

    private nonisolated struct Filter: Hashable, Sendable {
        let category: String?
        let favorites: [String]?
        let query: String
        let revision: Int
        let isActive: Bool
    }

    private var filter: Filter {
        let favoriteIDs = favoritesOnly || category == Selection.favorites ? model.library.favoriteChannels : nil
        let groupID = category != Selection.all && category != Selection.favorites ? category : nil
        return Filter(
            category: groupID, favorites: favoriteIDs,
            query: query.trimmingCharacters(in: .whitespacesAndNewlines),
            revision: model.catalogRevision, isActive: isPageActive
        )
    }

    private var channels: [ChannelGroup] {
        if let results { return results }
        if let favorites = filter.favorites { return favorites.compactMap { model.catalog.channelGroup($0) } }
        return model.catalog.channels
    }

    public var body: some View {
        let request = filter
        VStack(alignment: .leading, spacing: 0) {
            header
            if !model.catalog.channels.isEmpty, !favoritesOnly {
                ChipBar(items: chips, selection: Binding(get: { category }, set: { category = $0 ?? Selection.all }))
                    .padding(.vertical, 8)
                    .transaction { if reduceMotion { $0.animation = nil } }
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: request) {
            guard request.isActive else { return }
            if !request.query.isEmpty {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            let matches = await Self.filteredChannels(in: model.catalog, request: request)
            if !Task.isCancelled { results = matches }
        }
        .onChange(of: model.catalogRevision) {
            if let categoryID = filter.category, model.catalog.categoryGroup(categoryID) == nil {
                category = Selection.all
            }
        }
    }

    private var chips: [ChipItem] {
        [ChipItem(id: Selection.all, title: "Toutes les chaînes"),
         ChipItem(id: Selection.favorites, title: "Favorites", systemImage: "star")] + model.catalog.liveCategories.map {
            ChipItem(id: $0.id, title: $0.name)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(favoritesOnly ? "Chaînes favorites" : "TV en direct")
                    .font(.system(size: 34, weight: .bold))
                    .tracking(-1)
                    .accessibilityAddTraits(.isHeader)
                if !channels.isEmpty {
                    Text(channels.count == 1 ? "1 chaîne" : "\(channels.count.formatted()) chaînes")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 10)

            if !model.catalog.channels.isEmpty {
                Picker("Mode d’affichage", selection: $mode) {
                    Label("Chaînes", systemImage: "square.grid.2x2").tag(Mode.channels)
                    Label("Guide TV", systemImage: "calendar").tag(Mode.guide)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.large)
                .fixedSize()

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Nom ou numéro", text: $query)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Rechercher une chaîne")
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Effacer la recherche")
                    }
                }
                .padding(.horizontal, 11)
                .frame(width: 166, height: 34)
                .background(.quaternary, in: .capsule)
            }
        }
        .padding(.horizontal, PrismMetrics.contentMargin)
        .padding(.top, 28)
        .padding(.bottom, 14)
    }

    @ViewBuilder private var content: some View {
        if channels.isEmpty {
            emptyState
        } else {
            ZStack {
                if mode == .channels {
                    grid
                        .transition(.opacity)
                } else if model.guide.isEmpty {
                    EmptyStateView(
                        symbol: "calendar.badge.exclamationmark", title: "Aucun programme disponible",
                        message: "Vérifiez l’adresse XMLTV dans les réglages de votre source ou actualisez le guide.",
                        actionTitle: model.isRefreshingGuide ? nil : "Actualiser le guide"
                    ) { Task { await refreshGuide() } }
                    .overlay(alignment: .bottom) {
                        if model.isRefreshingGuide { ProgressView().controlSize(.small).padding(32) }
                    }
                    .transition(.opacity)
                } else {
                    LiveGuide(
                        channels: channels, guide: model.guide, start: $guideStart,
                        isRefreshing: model.isRefreshingGuide, onRefresh: { Task { await refreshGuide() } },
                        onPlay: { play($0, program: $1) },
                        onReplay: replayAction,
                        channelMenu: { group, program in channelMenu(group, program: program) }
                    )
                    .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : PrismMotion.quickFade, value: mode)
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.isImportingAnything, model.catalog.channels.isEmpty {
            ProgressView("Importation des chaînes…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !filter.query.isEmpty {
            EmptyStateView(symbol: "magnifyingglass", title: "Aucune chaîne trouvée",
                           message: "Essayez un nom de chaîne ou son numéro.", actionTitle: "Effacer la recherche") { query = "" }
        } else if favoritesOnly || category == Selection.favorites {
            EmptyStateView(symbol: "star", title: "Aucune chaîne favorite",
                           message: "Ajoutez une chaîne à vos favoris depuis son menu.", actionTitle: "Parcourir les chaînes") {
                if favoritesOnly { navigation.select(.live) } else { category = Selection.all }
            }
        } else if category != Selection.all {
            EmptyStateView(symbol: "play.tv", title: "Aucune chaîne dans cette catégorie",
                           actionTitle: "Afficher toutes les chaînes") { category = Selection.all }
        } else {
            EmptyStateView(symbol: "play.tv", title: "Aucune chaîne disponible",
                           message: "Les chaînes de vos sources actives apparaîtront ici après leur importation.")
        }
    }

    private var grid: some View {
        GeometryReader { geometry in
            let margin = PrismMetrics.contentMargin
            let spacing = PrismMetrics.cardSpacing
            let available = max(1, geometry.size.width - margin * 2)
            let cardWidth = max(1, PrismMetrics.columnWidth(available: available, minWidth: 184, spacing: spacing))
            let columnCount = max(1, Int((available + spacing) / (184 + spacing)))
            let columns = Array(repeating: GridItem(.fixed(cardWidth), spacing: spacing, alignment: .top), count: columnCount)
            LiveClock(active: isPageActive) { now in
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                        ForEach(channels) { channel in
                            tile(channel, width: cardWidth, now: now)
                        }
                    }
                    .padding(.horizontal, margin)
                    .padding(.top, 12)
                    .padding(.bottom, 36)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
        }
    }

    private func tile(_ group: ChannelGroup, width: CGFloat, now: Date) -> some View {
        let program = model.guide.resolveEPGID(for: group).flatMap { model.guide.nowAndNext(forEPGID: $0, at: now).now }
        let tint = group.primary.flatMap { model.catalog.source($0.sourceID) }.flatMap { PrismTint(rawValue: $0.tint.rawValue) }
        return ChannelTile(
            logoURL: group.logoURL, name: group.name, number: group.number, programTitle: program?.title,
            progress: program?.progress(at: now), tint: tint, width: width,
            action: { play(group, program: program) }
        ) { channelMenu(group, program: program) }
    }

    @ViewBuilder private func channelMenu(_ group: ChannelGroup, program: EPGProgram?) -> some View {
        let favorite = model.library.isFavorite(group.id)
        Button {
            model.library.toggleFavorite(group.id)
        } label: {
            Label(favorite ? "Retirer des favorites" : "Ajouter aux favorites", systemImage: favorite ? "star.slash" : "star")
        }
        if group.variants.count > 1 {
            let preferred = LivePlayback.preferredVariant(in: group, library: model.library)
            Menu("Choisir la source") {
                ForEach(group.variants) { variant in
                    let description = [model.catalog.source(variant.sourceID)?.name, variant.quality.badge]
                        .compactMap { $0 }.joined(separator: " · ")
                    let title = description.isEmpty ? variant.name : description
                    Button {
                        model.library.setPreferredChannelVariant(variant.id, for: group.id)
                        play(group, variant: variant, program: program)
                    } label: {
                        if variant.id == preferred?.id { Label(title, systemImage: "checkmark") }
                        else { Text(title) }
                    }
                }
            }
        }
    }

    private func play(_ group: ChannelGroup, variant: Channel? = nil, program: EPGProgram?) {
        guard let variant = variant ?? LivePlayback.preferredVariant(in: group, library: model.library) else { return }
        playItem(LivePlayback.makeItem(group: group, variant: variant, program: program), .channel(groupID: group.id), variant.id)
    }

    private func replayAction(for channel: ChannelGroup, program: EPGProgram, at now: Date) -> (() -> Void)? {
        guard let replay = LivePlayback.replayItem(group: channel, program: program, at: now, model: model) else { return nil }
        return { playItem(replay.item, .channel(groupID: channel.id), replay.variant.id) }
    }

    private func refreshGuide() async {
        for source in model.sources where source.isEnabled {
            guard !Task.isCancelled else { return }
            await model.refreshGuide(for: source.id)
        }
    }

    @concurrent private static func filteredChannels(in catalog: Catalog, request: Filter) async -> [ChannelGroup] {
        let channels: [ChannelGroup]
        if let favorites = request.favorites {
            channels = favorites.compactMap(catalog.channelGroup)
        } else if let categoryID = request.category, let category = catalog.categoryGroup(categoryID) {
            channels = catalog.channels(in: category)
        } else {
            channels = catalog.channels
        }
        guard !request.query.isEmpty else { return channels }
        let key = TitleNormalizer.key(request.query)
        guard !key.isEmpty else { return channels }
        let terms = key.split(separator: " ")
        let number = Int(key)
        var matches: [ChannelGroup] = []
        for (index, channel) in channels.enumerated() {
            if index.isMultiple(of: 256), Task.isCancelled { return [] }
            if let number, channel.number == number {
                matches.append(channel)
                continue
            }
            let name = TitleNormalizer.key(channel.name)
            if terms.allSatisfy({ name.contains($0) }) { matches.append(channel) }
        }
        return matches
    }
}

/// A single wall clock for the tiles/rows currently visible on a live page, paused offscreen.
struct LiveClock<Content: View>: View {
    let active: Bool
    @ViewBuilder let content: (Date) -> Content
    @State private var now = Date.now

    var body: some View {
        content(now)
            .task(id: active) {
                guard active else { return }
                while !Task.isCancelled {
                    now = .now
                    try? await Task.sleep(for: .seconds(30))
                }
            }
    }
}
