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
    @State private var visited: [SidebarItem] = [.home]
    @State private var visibility = NavigationSplitViewVisibility.all
    @State private var isAddingSource = false

    private var mountedSections: [SidebarItem] {
        let selection = navigation.selection
        return visited.contains(selection) ? visited : visited + [selection]
    }

    private var sidebarText: Color { Color(white: colorScheme == .dark ? 0.92 : 0.12) }
    private var sidebarSecondary: Color { Color(white: colorScheme == .dark ? 0.69 : 0.38) }
    private var sidebarAccent: Color {
        colorScheme == .dark ? Color(red: 0.46, green: 0.72, blue: 1) : Color(red: 0.07, green: 0.33, blue: 0.68)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 290)
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
                ToolbarSpacer(.flexible, placement: .automatic)
                ToolbarItem(placement: .automatic) {
                    Button("Ajouter une source IPTV", systemImage: "plus") { isAddingSource = true }
                        .keyboardShortcut("n", modifiers: [.command, .shift])
                        .help("Ajouter une source IPTV")
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
            PrismLogoLockup(size: 20)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 14)

            List {
                Section {
                    row("Accueil", symbol: "house", item: .home)
                    row("Rechercher", symbol: "magnifyingglass", item: .search)
                    row("TV en direct", symbol: "dot.radiowaves.left.and.right", item: .live)
                    row("Sport", symbol: "sportscourt", item: .sports)
                    row("Films", symbol: "film.stack", item: .movies)
                    row("Séries", symbol: "rectangle.stack", item: .series)
                }
                Section {
                    row("Ma liste", symbol: "bookmark", item: .watchlist)
                    row("Chaînes favorites", symbol: "star", item: .favorites)
                    row("Historique", symbol: "clock.arrow.circlepath", item: .history)
                } header: {
                    Text("Bibliothèque").foregroundStyle(sidebarSecondary)
                }
                Section {
                    ForEach(app.sources) { source in
                        let item = SidebarItem.source(source.id)
                        sidebarButton(item) {
                            HStack(spacing: 9) {
                                Image(systemName: source.id == DemoContent.sourceID ? "play.rectangle" : "rectangle.connected.to.line.below")
                                    .foregroundStyle(rowSymbol(item))
                                    .frame(width: 17)
                                    .accessibilityHidden(true)
                                Text(source.name).lineLimit(1).foregroundStyle(sidebarText)
                                    .fontWeight(navigation.selection == item ? .semibold : .regular)
                                Spacer(minLength: 3)
                                if app.isImporting(source.id) {
                                    ProgressView().controlSize(.mini).accessibilityLabel("Importation")
                                } else if app.errors[source.id] != nil {
                                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                                        .accessibilityLabel("Erreur d’actualisation")
                                } else if !source.isEnabled {
                                    Image(systemName: "pause.circle").foregroundStyle(rowSymbol(item))
                                        .accessibilityLabel("Source inactive")
                                }
                            }
                        }
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
                        Label {
                            Text("Ajouter une source…").foregroundStyle(sidebarText)
                        } icon: {
                            Image(systemName: "plus.circle").foregroundStyle(sidebarSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Sources").foregroundStyle(sidebarSecondary)
                }
            }
            .listStyle(.sidebar)

            VStack(alignment: .leading, spacing: 11) {
                Button("Réglages", systemImage: "gearshape") { openSettings() }
            }
            .buttonStyle(.plain)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private func row(_ title: String, symbol: String, item: SidebarItem) -> some View {
        sidebarButton(item) {
            Label {
                Text(title)
                    .foregroundStyle(sidebarText)
                    .fontWeight(navigation.selection == item ? .semibold : .regular)
            } icon: {
                Image(systemName: symbol).foregroundStyle(rowSymbol(item))
            }
        }
    }

    private func sidebarButton(_ item: SidebarItem, @ViewBuilder label: () -> some View) -> some View {
        Button {
            navigation.select(item)
        } label: {
            label()
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(navigation.selection == item ? .isSelected : [])
        .listRowBackground(selectionBackground(item))
    }

    private func rowSymbol(_ item: SidebarItem) -> Color {
        navigation.selection == item ? sidebarAccent : sidebarSecondary
    }

    private func selectionBackground(_ item: SidebarItem) -> some View {
        ZStack {
            if navigation.selection == item {
                Capsule()
                    .fill(sidebarAccent.opacity(colorScheme == .dark ? 0.16 : 0.105))
                    .overlay {
                        Capsule().strokeBorder(sidebarAccent.opacity(colorScheme == .dark ? 0.22 : 0.12), lineWidth: 1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
