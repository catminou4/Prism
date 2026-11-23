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
    @State private var results: FilteredChannels?
    @State private var guideStart: Date?
    @State private var guideRefreshTask: Task<Void, Never>?

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
        /// Fingerprint of `favorites`: `LibraryStore` exposes no favorites revision,
        /// so the hash memoizes identity — task-id comparisons stay O(1) instead of
        /// rescanning the whole array on every body evaluation.
        let favoritesKey: Int
        let favorites: [String]?
        let query: String
        let revision: Int
        let isActive: Bool

        init(category: String?, favorites: [String]?, query: String, revision: Int, isActive: Bool) {
            self.category = category
            self.favoritesKey = favorites.hashValue
            self.favorites = favorites
            self.query = query
            self.revision = revision
            self.isActive = isActive
        }

        var isUnfiltered: Bool { category == nil && favorites == nil && query.isEmpty }

        func hasSameScope(as other: Self) -> Bool {
            revision == other.revision && category == other.category && favoritesKey == other.favoritesKey
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.category == rhs.category && lhs.favoritesKey == rhs.favoritesKey
                && lhs.query == rhs.query && lhs.revision == rhs.revision && lhs.isActive == rhs.isActive
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(category)
            hasher.combine(favoritesKey)
            hasher.combine(query)
            hasher.combine(revision)
            hasher.combine(isActive)
        }
    }

    private struct FilteredChannels {
        let request: Filter
        let channels: [ChannelGroup]
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

    private func channels(for request: Filter) -> [ChannelGroup]? {
        if request.isUnfiltered { return model.catalog.channels }
        guard let results, results.request.hasSameScope(as: request) else { return nil }
        if results.request.query == request.query { return results.channels }
        return results.channels.isEmpty ? nil : results.channels
    }

    public var body: some View {
        let request = filter
        let channels = channels(for: request)
        VStack(alignment: .leading, spacing: 0) {
            header(channelCount: channels?.count)
            if !model.catalog.channels.isEmpty, !favoritesOnly {
                categoryRail
            }
            content(channels: channels)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: request) {
            guard request.isActive else { return }
            guard !request.isUnfiltered else {
                results = nil
                return
            }
            let catalog = model.catalog
            if !request.query.isEmpty {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            let matches = await Self.filteredChannels(in: catalog, request: request)
            if !Task.isCancelled { results = FilteredChannels(request: request, channels: matches) }
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

    private var categoryRail: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 6) {
                ForEach(chips) { chip in
                    let selected = chip.id == category
                    Button {
                        category = chip.id
                    } label: {
                        HStack(spacing: 5) {
                            if let symbol = chip.systemImage { Image(systemName: symbol).accessibilityHidden(true) }
                            Text(chip.title).lineLimit(1)
                        }
                        .font(.subheadline.weight(selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: PrismMetrics.compactButtonSize)
                        .background {
                            if selected { Capsule().fill(PrismColors.panelFill) }
                        }
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.vertical, 6)
        }
        .fixedSize(horizontal: false, vertical: true)
        .scrollIndicators(.never)
        .contentMargins(.horizontal, PrismMetrics.contentMargin, for: .scrollContent)
        .accessibilityLabel("Catégories de chaînes")
        .prismScrollPhase()
    }

    private func header(channelCount: Int?) -> some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(favoritesOnly ? "Chaînes favorites" : "TV en direct")
                    .font(.system(size: 34, weight: .bold))
                    .tracking(-1)
                    .accessibilityAddTraits(.isHeader)
                Text(channelCount == 1 ? "1 chaîne" : "\((channelCount ?? 0).formatted()) chaînes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .opacity(channelCount.map { $0 > 0 } == true ? 1 : 0)
                    .accessibilityHidden(channelCount.map { $0 > 0 } != true)
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
                .frame(width: 166, height: PrismMetrics.compactButtonSize)
                .prismGlass(.regular, in: .capsule)
            }
        }
        .padding(.horizontal, PrismMetrics.contentMargin)
        .padding(.top, 28)
        .padding(.bottom, 14)
    }

    @ViewBuilder private func content(channels: [ChannelGroup]?) -> some View {
        if let channels, !channels.isEmpty {
            ZStack {
                if mode == .channels {
                    grid(channels: channels)
                        .transition(.opacity)
                } else if model.guide.isEmpty {
                    EmptyStateView(
                        symbol: "calendar.badge.exclamationmark", title: "Aucun programme disponible",
                        message: "Vérifiez l’adresse XMLTV dans les réglages de votre source ou actualisez le guide.",
                        actionTitle: model.isRefreshingGuide ? nil : "Actualiser le guide"
                    ) { refreshGuide() }
                    .overlay(alignment: .bottom) {
                        if model.isRefreshingGuide { ProgressView().controlSize(.small).padding(32) }
                    }
                    .transition(.opacity)
                } else {
                    LiveGuide(
                        channels: channels, guide: model.guide, start: $guideStart,
                        isRefreshing: model.isRefreshingGuide, onRefresh: { refreshGuide() },
                        onPlay: { play($0, program: $1) },
                        onReplay: replayAction,
                        channelMenu: { group, program in channelMenu(group, program: program) }
                    )
                    .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : PrismMotion.quickFade, value: mode)
        } else if channels == nil {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Chargement des chaînes")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            emptyState
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

    private func grid(channels: [ChannelGroup]) -> some View {
        GeometryReader { geometry in
            let margin = PrismMetrics.contentMargin
            let spacing = PrismMetrics.cardSpacing
            let available = max(1, geometry.size.width - margin * 2)
            let cardWidth = max(1, PrismMetrics.columnWidth(available: available, minWidth: 184, spacing: spacing))
            let columnCount = max(1, Int((available + spacing) / (184 + spacing)))
            let columns = Array(repeating: GridItem(.fixed(cardWidth), spacing: spacing, alignment: .top), count: columnCount)
            LiveClock(active: isPageActive && !model.guide.isEmpty) { now in
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
                .prismScrollPhase()
            }
        }
    }

    private func tile(_ group: ChannelGroup, width: CGFloat, now: Date) -> some View {
        let program = model.guide.resolveEPGID(for: group).flatMap { model.guide.nowAndNext(forEPGID: $0, at: now).now }
        return ChannelTile(
            logoURL: group.logoURL, name: group.name, number: group.number, programTitle: program?.title,
            progress: program?.progress(at: now), width: width,
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

    /// One guide refresh at a time per screen: the task handle is assigned
    /// synchronously so rapid taps cannot start overlapping per-source loops.
    private func refreshGuide() {
        guard guideRefreshTask == nil, !model.isRefreshingGuide else { return }
        guideRefreshTask = Task {
            defer { guideRefreshTask = nil }
            for source in model.sources where source.isEnabled {
                guard !Task.isCancelled else { return }
                await model.refreshGuide(for: source.id)
            }
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
        var exact: [ChannelGroup] = []
        var prefixes: [ChannelGroup] = []
        var other: [ChannelGroup] = []
        for (index, channel) in channels.enumerated() {
            if index.isMultiple(of: 256), Task.isCancelled { return [] }
            // The catalog already uses the normalized channel name as its group ID.
            if channel.id == key || (number != nil && channel.number == number) {
                exact.append(channel)
            } else if channel.id.hasPrefix(key) {
                prefixes.append(channel)
            } else if channel.id.first != "#", terms.allSatisfy({ channel.id.contains($0) }) {
                other.append(channel)
            }
        }
        return exact + prefixes + other
    }
}

/// A single wall clock for the tiles/rows currently visible on a live page, paused offscreen.
struct LiveClock<Content: View>: View {
    let active: Bool
    @ViewBuilder let content: (Date) -> Content
    @Environment(\.appearsActive) private var appearsActive
    @State private var now = Date.now

    var body: some View {
        let running = active && appearsActive
        content(now)
            .task(id: running) {
                guard running else { return }
                while !Task.isCancelled {
                    now = .now
                    try? await Task.sleep(for: .seconds(30), tolerance: .seconds(3))
                }
            }
    }
}
