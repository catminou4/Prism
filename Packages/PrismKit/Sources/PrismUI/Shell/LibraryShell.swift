import SwiftUI
import PrismCore
import PrismData
import PrismDesign

struct LibraryShell: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var navigation = NavigationModel()
    @State private var visited: [SidebarItem] = [.home]
    @State private var visibility = NavigationSplitViewVisibility.all
    @State private var isAddingSource = false

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 228, max: 290)
        } detail: {
            ZStack {
                ForEach(visited, id: \.self) { section in
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
            .environment(navigation)
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
            if !visited.contains(selection) { visited.append(selection) }
        }
        .onChange(of: app.sources.map(\.id)) { old, new in
            for id in Set(old).subtracting(new) {
                navigation.removeRoutes(for: id)
                visited.removeAll { $0 == .source(id) }
            }
        }
        .background(alignment: .bottomLeading) {
            Button("Rechercher") { navigation.select(.search) }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .sheet(isPresented: $isAddingSource) {
            AddSourceView(onImported: { isAddingSource = false })
                .frame(minWidth: 540, minHeight: 460)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            PrismLogoLockup(size: 23)
                .padding(.horizontal, 17)
                .padding(.top, 12)
                .padding(.bottom, 14)

            List(selection: Binding<SidebarItem?>(
                get: { navigation.selection },
                set: { if let item = $0, item != navigation.selection { navigation.select(item) } }
            )) {
                Section("Explorer") {
                    row("Accueil", symbol: "sparkle.tv", item: .home)
                    row("Rechercher", symbol: "magnifyingglass", item: .search)
                    row("TV en direct", symbol: "dot.radiowaves.left.and.right", item: .live)
                    row("Films", symbol: "film.stack", item: .movies)
                    row("Séries", symbol: "rectangle.stack", item: .series)
                }
                Section("Bibliothèque") {
                    row("Ma liste", symbol: "bookmark", item: .watchlist)
                    row("Chaînes favorites", symbol: "star", item: .favorites)
                    row("Historique", symbol: "clock.arrow.circlepath", item: .history)
                }
                Section("Sources") {
                    ForEach(app.sources) { source in
                        HStack(spacing: 9) {
                            Circle()
                                .fill((PrismTint(rawValue: source.tint.rawValue) ?? .blue).gradient)
                                .frame(width: 10, height: 10)
                                .accessibilityHidden(true)
                            Text(source.name).lineLimit(1)
                            Spacer(minLength: 3)
                            if app.isImporting(source.id) {
                                ProgressView().controlSize(.mini).accessibilityLabel("Importation")
                            } else if app.errors[source.id] != nil {
                                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                                    .accessibilityLabel("Erreur d’actualisation")
                            } else if !source.isEnabled {
                                Image(systemName: "pause.circle").foregroundStyle(.secondary)
                                    .accessibilityLabel("Source inactive")
                            }
                        }
                        .tag(SidebarItem.source(source.id))
                        .contextMenu {
                            Button(source.isEnabled ? "Désactiver" : "Activer") {
                                app.setEnabled(!source.isEnabled, for: source.id)
                            }
                            .disabled(app.isImporting(source.id))
                            Button("Actualiser") { Task { await app.refresh(source.id) } }
                                .disabled(!source.isEnabled || app.isImporting(source.id))
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            VStack(alignment: .leading, spacing: 11) {
                Button("Ajouter une source…", systemImage: "plus.circle") { isAddingSource = true }
                Button("Réglages", systemImage: "gearshape") { openSettings() }
            }
            .buttonStyle(.plain)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private func row(_ title: String, symbol: String, item: SidebarItem) -> some View {
        Label(title, systemImage: symbol).tag(item)
    }

    @ViewBuilder private func root(for section: SidebarItem) -> some View {
        switch section {
        case .home: BrowseScreen(kind: nil)
        case .search: SearchScreen()
        case .live: LiveScreen()
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
