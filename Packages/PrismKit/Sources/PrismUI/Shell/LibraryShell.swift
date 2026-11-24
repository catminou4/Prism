import SwiftUI
import PrismCore
import PrismData
import PrismDesign

struct LibraryShell: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var navigation = NavigationModel()
    @State private var sports = SportsPresentation()
    /// Sections kept mounted, least-recently-used first. Each owns a full page
    /// stack: beyond `maxMountedSections` the oldest is unmounted (its routes stay
    /// in `NavigationModel`, only scroll/view state is lost) so buried pages stop
    /// observing `AppModel` — progress ticks, feed refreshes…
    @State private var visited: [SidebarItem] = [.home]
    private static let maxMountedSections = 6
    @State private var visibility = NavigationSplitViewVisibility.all
    @State private var isAddingSource = false
    @State private var playbackOverlay = PlaybackOverlayModel()

    private var mountedSections: [SidebarItem] {
        let selection = navigation.selection
        return visited.contains(selection) ? visited : visited + [selection]
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: PrismMetrics.sidebarWidth, max: 290)
        } detail: {
            GeometryReader { layout in
                ZStack {
                    ForEach(mountedSections, id: \.self) { section in
                        if let sourceID = section.sourceID, app.source(sourceID) == nil {
                            Color.clear
                        } else {
                            let active = section == navigation.selection
                            PageStack(section: section) { root(for: section) }
                                .opacity(active ? 1 : 0)
                                .allowsHitTesting(active)
                                .accessibilityHidden(!active)
                                .environment(\.isPageActive, active)
                                .zIndex(active ? 1 : 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.prismShelfViewportWidth, layout.size.width)
            }
            .environment(navigation)
            .environment(sports)
            .transaction { transaction in
                if reduceMotion { transaction.animation = nil }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    if navigation.canGoBack {
                        Button("Retour", systemImage: "chevron.left") { navigation.pop() }
                            .keyboardShortcut("[", modifiers: .command)
                            .help("Retour")
                    }
                }

            }
        }
        .onChange(of: navigation.selection) { _, selection in
            // Ordre = récence (le plus récent en dernier) pour l'éviction LRU.
            visited.removeAll { $0 == selection }
            visited.append(selection)
            if visited.count > Self.maxMountedSections {
                visited.removeFirst(visited.count - Self.maxMountedSections)
            }
        }
        .onChange(of: app.sources.map(\.id)) { old, new in
            for id in Set(old).subtracting(new) {
                navigation.removeRoutes(for: id)
                visited.removeAll { $0 == .source(id) }
            }
        }
        .environment(\.playbackOverlay, playbackOverlay)
        // The page underneath stays put (no scroll, no clicks) while the playback sheet is up.
        .allowsHitTesting(!playbackOverlay.isPresented)
        .overlay { PlaybackOverlayHost(model: playbackOverlay) }
        .background(alignment: .bottomLeading) { sectionShortcuts }
        .sheet(isPresented: $isAddingSource) {
            AddSourceView(onImported: { isAddingSource = false })
        }
    }

    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(get: { navigation.selection }, set: { item in
            if let item { navigation.select(item) }
        })
    }

    /// `List(selection:)` ne re-notifie pas toujours la valeur identique : un clic
    /// sur la section déjà affichée doit quand même remonter sa pile à la racine
    /// (comportement Apple TV). Le garde-fou sur `lastSelectionChange` évite de
    /// vider la pile d'une section qu'on vient de choisir — la sélection et le
    /// geste `onEnded` arrivent quasi ensemble, la sélection gagnant la course.
    private func popToRootOnRetap(_ item: SidebarItem) -> some Gesture {
        TapGesture().onEnded {
            guard navigation.selection == item,
                  Date.now.timeIntervalSince(navigation.lastSelectionChange) > 0.5
            else { return }
            navigation.popToRoot()
        }
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section {
                ForEach(Self.mainItems, id: \.item) { entry in
                    Label(entry.title, systemImage: entry.symbol)
                        .tag(entry.item)
                        .simultaneousGesture(popToRootOnRetap(entry.item))
                }
            }
            Section("Bibliothèque") {
                ForEach(Self.libraryItems, id: \.item) { entry in
                    Label(entry.title, systemImage: entry.symbol)
                        .tag(entry.item)
                        .simultaneousGesture(popToRootOnRetap(entry.item))
                }
            }
            Section("Sources") {
                ForEach(app.sources) { source in
                    SourceSidebarRow(source: source)
                        .tag(SidebarItem.source(source.id))
                        .simultaneousGesture(popToRootOnRetap(.source(source.id)))
                        .contextMenu {
                            Button(source.isEnabled ? "Désactiver" : "Activer") {
                                app.setEnabled(!source.isEnabled, for: source.id)
                            }
                            .disabled(app.isImporting(source.id))
                            Button("Actualiser") { Task { await app.refresh(source.id) } }
                                .disabled(!source.isEnabled || app.isImporting(source.id))
                        }
                }
                Button {
                    isAddingSource = true
                } label: {
                    Label("Ajouter une source…", systemImage: "plus.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                openSettings()
            } label: {
                HStack(spacing: 10) {
                    PrismLogoMark(size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Prism").font(.system(size: 13, weight: .semibold))
                        Text("Réglages").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Ouvrir les réglages de Prism (⌘,)")
        }
    }

    private struct SidebarEntry {
        let title: String
        let symbol: String
        let item: SidebarItem
    }

    private static let mainItems = [
        SidebarEntry(title: "Rechercher", symbol: "magnifyingglass", item: .search),
        SidebarEntry(title: "Accueil", symbol: "house", item: .home),
        SidebarEntry(title: "TV en direct", symbol: "play.tv", item: .live),
        SidebarEntry(title: "Sport", symbol: "sportscourt", item: .sports),
        SidebarEntry(title: "Films", symbol: "film", item: .movies),
        SidebarEntry(title: "Séries", symbol: "tv", item: .series),
    ]

    private static let libraryItems = [
        SidebarEntry(title: "Ma liste", symbol: "plus.circle", item: .watchlist),
        SidebarEntry(title: "Chaînes favorites", symbol: "star", item: .favorites),
        SidebarEntry(title: "Historique", symbol: "clock.arrow.circlepath", item: .history),
    ]

    /// ⌘1…⌘6 jump between the main sections, ⌘F searches.
    private var sectionShortcuts: some View {
        ZStack {
            ForEach(Array(Self.mainItems.enumerated()), id: \.offset) { offset, entry in
                Button(entry.title) { navigation.select(entry.item) }
                    .keyboardShortcut(KeyEquivalent(Character(String(offset + 1))), modifiers: .command)
            }
            Button("Rechercher") { navigation.select(.search) }
                .keyboardShortcut("f", modifiers: .command)
            Button("Ajouter une source IPTV") { isAddingSource = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func root(for section: SidebarItem) -> some View {
        switch section {
        case .home: BrowseScreen(kind: nil)
        case .search: SearchScreen()
        case .live: LiveScreen()
        case .sports: SportsScreen()
        case .movies: BrowseScreen(kind: .movie)
        case .series: BrowseScreen(kind: .series)
        case .watchlist: CollectionView(collection: .watchlist)
        case .favorites: LiveScreen(favoritesOnly: true)
        case .history: HistoryScreen()
        case .source(let id): SourceDetailView(sourceID: id)
        }
    }
}

private extension SidebarItem {
    var sourceID: SourceID? {
        if case .source(let id) = self { id } else { nil }
    }
}

/// A source in the sidebar: tinted monogram and live status.
private struct SourceSidebarRow: View {
    @Environment(AppModel.self) private var app
    let source: Source

    var body: some View {
        Label {
            Text(source.name).lineLimit(1)
        } icon: {
            Monogram(text: source.name, tint: PrismTint(rawValue: source.tint.rawValue), size: 18)
        }
        .badge(status)
    }

    private var status: Text? {
        if app.isImporting(source.id) { return Text(Image(systemName: "arrow.triangle.2.circlepath")) }
        if app.errors[source.id] != nil { return Text(Image(systemName: "exclamationmark.circle")).foregroundStyle(.orange) }
        if !source.isEnabled { return Text("Inactive") }
        return nil
    }
}
