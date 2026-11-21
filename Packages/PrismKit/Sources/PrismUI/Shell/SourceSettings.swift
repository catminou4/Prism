import SwiftUI
import PrismCore
import PrismData
import PrismDesign
import PrismPlayer

struct SourceDetailView: View {
    @Environment(AppModel.self) private var app
    let sourceID: SourceID
    @State private var counts = ImportCounts()
    @State private var editing = false
    @State private var filteringCategories = false
    @State private var removing = false

    var body: some View {
        if let source = app.source(sourceID) {
            let categories = app.sourceCategories(for: sourceID)
            let hiddenIDs = app.hiddenCategoryIDs(for: sourceID)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    BrowseHeading(title: source.name, subtitle: source.kind.displayLabel)
                    HStack(spacing: 0) {
                        metric("Chaînes", count: counts.channels, symbol: "dot.radiowaves.left.and.right")
                        Divider().frame(height: 42)
                        metric("Films", count: counts.movies, symbol: "film")
                        Divider().frame(height: 42)
                        metric("Séries", count: counts.series, symbol: "rectangle.stack")
                    }
                    .background(PrismColors.panelFill, in: .rect(cornerRadius: PrismMetrics.panelRadius))
                    .padding(.horizontal, PrismMetrics.contentMargin)
                    Form {
                        Section("État") {
                            Toggle("Source active", isOn: Binding(get: { source.isEnabled }, set: { app.setEnabled($0, for: sourceID) }))
                                .disabled(app.isImporting(sourceID))
                            if let refreshed = source.lastRefreshedAt {
                                LabeledContent("Dernière actualisation") { Text(refreshed, format: .dateTime) }
                            }
                            if let account = app.account(for: sourceID), let date = account.expiresAt {
                                LabeledContent("Expiration de l’abonnement") { Text(date, format: .dateTime.day().month(.wide).year()) }
                            }
                            if let progress = app.imports[sourceID] {
                                ProgressView(value: progress.fraction)
                                    .accessibilityLabel("Actualisation de la source")
                            }
                            if let error = app.errors[sourceID] {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                        }
                        Section {
                            if !categories.isEmpty || !hiddenIDs.isEmpty {
                                Button("Filtrer les catégories…", systemImage: "line.3.horizontal.decrease") {
                                    filteringCategories = true
                                }
                            }
                            HStack {
                                Button("Actualiser", systemImage: "arrow.clockwise") { Task { await app.refresh(sourceID) } }
                                    .disabled(!source.isEnabled || app.isImporting(sourceID))
                                Button("Modifier…", systemImage: "pencil") { editing = true }
                                Spacer()
                                Button("Supprimer…", role: .destructive) { removing = true }
                            }
                            .disabled(app.isImporting(sourceID))
                        }
                    }
                    .formStyle(.grouped)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
                }
                .padding(.vertical, 24)
            }
            .task(id: app.catalogRevision) { counts = await Self.counts(for: sourceID, in: app.catalog) }
            .sheet(isPresented: $editing) { EditSourceSheet(source: source) }
            .sheet(isPresented: $filteringCategories) {
                SourceCategorySheet(
                    source: source, categories: categories, hiddenIDs: hiddenIDs
                )
            }
            .confirmationDialog("Supprimer « \(source.name) » ?", isPresented: $removing) {
                Button("Supprimer la source", role: .destructive) { app.remove(sourceID) }
            }
        } else {
            ContentUnavailableView("Source indisponible", systemImage: "antenna.radiowaves.left.and.right.slash")
        }
    }

    private func metric(_ name: String, count: Int, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.tint)
            Text(count.formatted()).font(.system(size: 26, weight: .semibold).monospacedDigit())
            Text(name).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .accessibilityElement(children: .combine)
    }

    @concurrent
    private static func counts(for id: SourceID, in catalog: Catalog) async -> ImportCounts {
        catalog.counts(for: id)
    }
}

private struct SourceCategorySheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let source: Source
    let categories: [PrismCore.Category]
    @State private var hiddenIDs: Set<String>
    @State private var query = ""

    init(source: Source, categories: [PrismCore.Category], hiddenIDs: Set<String>) {
        self.source = source
        self.categories = categories
        self._hiddenIDs = State(initialValue: hiddenIDs)
    }

    var body: some View {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = categories.filter { term.isEmpty || $0.name.localizedStandardContains(term) }
        let groups = Dictionary(grouping: matches, by: \.kind)
        VStack(alignment: .leading, spacing: 12) {
            Text("Catégories de \(source.name)").font(.title2.bold())
            if categories.isEmpty {
                ContentUnavailableView("Catégories indisponibles", systemImage: "line.3.horizontal.decrease")
                    .frame(maxHeight: .infinity)
            } else {
                Text("Cochez les catégories à afficher dans votre catalogue.")
                    .foregroundStyle(.secondary)
                TextField("Rechercher une catégorie", text: $query)
                    .textFieldStyle(.roundedBorder)
                if matches.isEmpty {
                    ContentUnavailableView.search(text: term)
                        .frame(maxHeight: .infinity)
                } else {
                    List {
                        ForEach([MediaKind.live, .movie, .series], id: \.self) { kind in
                            if let categories = groups[kind], !categories.isEmpty {
                                Section(kind.sectionTitle) {
                                    ForEach(categories) { category in
                                        Toggle(category.name, isOn: visibility(for: category.id))
                                            .toggleStyle(.checkbox)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            HStack {
                Button("Tout afficher") { hiddenIDs.removeAll() }
                    .disabled(hiddenIDs.isEmpty)
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Appliquer") {
                    app.setHiddenCategoryIDs(hiddenIDs, for: source.id)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500, height: 490)
    }

    private func visibility(for id: String) -> Binding<Bool> {
        Binding {
            !hiddenIDs.contains(id)
        } set: { isVisible in
            if isVisible {
                hiddenIDs.remove(id)
            } else {
                hiddenIDs.insert(id)
            }
        }
    }
}

private struct EditSourceSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var source: Source
    @State private var server = ""
    @State private var password = ""
    @State private var guideURL = ""
    @State private var userAgent = ""

    private func httpURL(_ value: String) -> URL? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host?.isEmpty == false else { return nil }
        return url
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Source") {
                    TextField("Nom", text: $source.name)
                    if source.kind != .m3uFile {
                        TextField(source.kind == .xtream ? "Adresse du serveur" : "URL de la liste M3U", text: $server)
                            .autocorrectionDisabled()
                    }
                    if source.kind == .xtream {
                        TextField("Identifiant", text: Binding(get: { source.username ?? "" }, set: { source.username = $0 }))
                        SecureField("Nouveau mot de passe (facultatif)", text: $password)
                    }
                    TextField("URL du guide XMLTV", text: $guideURL)
                    TextField("User-Agent", text: $userAgent)
                    if source.kind == .xtream {
                        Toggle("Préférer le flux HLS en direct", isOn: $source.preferHLSForLive)
                    }
                    Stepper("Décalage du guide · \(source.epgTimeShiftHours.formatted()) h",
                            value: $source.epgTimeShiftHours, in: -12...14, step: 0.5)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Enregistrer") {
                    source.name = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if source.kind != .m3uFile { source.serverURL = httpURL(server) }
                    source.epgURL = httpURL(guideURL)
                    source.username = source.username?.trimmingCharacters(in: .whitespacesAndNewlines)
                    source.userAgent = userAgent.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    app.update(source, password: password.nilIfEmpty)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(source.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          (source.kind != .m3uFile && httpURL(server) == nil) ||
                          (source.kind == .xtream && source.username?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false) ||
                          (!guideURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && httpURL(guideURL) == nil))
            }
            .padding()
        }
        .frame(width: 500, height: source.kind == .xtream ? 430 : 320)
        .onAppear {
            server = source.serverURL?.absoluteString ?? ""
            guideURL = source.epgURL?.absoluteString ?? ""
            userAgent = source.userAgent ?? ""
        }
    }
}

struct PrismSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var metadataKey = ""
    @State private var sportsAPIKey = ""
    @State private var sportsKeySaved = false
    @State private var sportsKeyError: String?
    @State private var showAddSource = false
    @State private var preferences = PlayerPreferences.standard

    var body: some View {
        @Bindable var app = app
        @Bindable var preferences = preferences
        TabView {
            Form {
                Section("Catalogue") {
                    Toggle("Masquer les contenus pour adultes", isOn: $app.hideAdultContent)
                    Button("Actualiser toutes les sources") { Task { await app.refreshAll() } }
                        .disabled(app.sources.isEmpty || app.isImportingAnything)
                    Button("Ajouter une source…", systemImage: "plus.circle") { showAddSource = true }
                }
                Section {
                    Picker("Langues audio", selection: Binding(
                        get: { app.homeAudioLanguages },
                        set: { app.setHomeAudioLanguages($0) }
                    )) {
                        Text("Français").tag(Set([HomeAudioLanguage.french]))
                        Text("Anglais").tag(Set([HomeAudioLanguage.english]))
                        Text("Français et anglais").tag(HomeAudioLanguage.defaults)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Recommandations de l’accueil")
                } footer: {
                    Text("Langues audio des films et séries suggérés à l’accueil.")
                }
                Section("Métadonnées") {
                    SecureField("Clé TMDB", text: $metadataKey)
                    Button("Enregistrer la clé") { app.setTMDBKey(metadataKey) }
                    Text("La clé enrichit les fiches de vos films et séries avec les visuels et les informations de TMDB.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    SecureField("Clé TheSportsDB", text: $sportsAPIKey)
                    Button("Enregistrer la clé") { saveSportsKey(sportsAPIKey) }
                        .disabled(sportsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if sportsKeySaved {
                        Button("Retirer la clé", role: .destructive) { saveSportsKey(nil) }
                    }
                    if let sportsKeyError {
                        Text(sportsKeyError).foregroundStyle(.red)
                    }
                } header: {
                    Text("Scores sportifs")
                } footer: {
                    Text("Pour suivre les scores en direct, ajoutez une clé TheSportsDB Premium.")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Général", systemImage: "gearshape") }

            Form {
                Section("Lecture") {
                    Picker("Moteur vidéo", selection: $preferences.defaultEngine) {
                        ForEach(PlaybackEngineKind.allCases, id: \.self) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    Toggle("Conserver les proportions de la fenêtre", isOn: $preferences.keepsWindowAspectRatio)
                }
                Section("Langues") {
                    Picker("Audio préféré", selection: $preferences.preferredAudioLanguage) {
                        Text("Par défaut").tag(nil as String?)
                        Text("Français").tag("fr" as String?)
                        Text("Anglais").tag("en" as String?)
                    }
                    Toggle("Activer les sous-titres", isOn: $preferences.subtitlesEnabled)
                    Picker("Langue des sous-titres", selection: $preferences.preferredSubtitleLanguage) {
                        Text("Par défaut").tag(nil as String?)
                        Text("Français").tag("fr" as String?)
                        Text("Anglais").tag("en" as String?)
                    }
                    .disabled(!preferences.subtitlesEnabled)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Lecteur", systemImage: "play.rectangle") }
        }
        .frame(width: 500, height: 365)
        .task {
            metadataKey = app.tmdbKey ?? ""
            sportsKeySaved = app.hasSportsAPIKey
        }
        .sheet(isPresented: $showAddSource) {
            AddSourceView(onImported: {
                app.completeOnboarding()
                showAddSource = false
            })
        }
    }

    private func saveSportsKey(_ value: String?) {
        do {
            try app.setSportsAPIKey(value)
            sportsAPIKey = ""
            sportsKeySaved = app.hasSportsAPIKey
            sportsKeyError = nil
        } catch {
            sportsKeyError = error.localizedDescription
        }
    }
}

private extension SourceKind {
    var displayLabel: String {
        switch self {
        case .xtream: "Xtream Codes"
        case .m3uURL: "Liste M3U en ligne"
        case .m3uFile: "Fichier M3U"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
