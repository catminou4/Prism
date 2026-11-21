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
    @State private var removing = false

    var body: some View {
        if let source = app.source(sourceID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    BrowseHeading(title: source.name, subtitle: source.kind.displayLabel)
                    HStack(spacing: 14) {
                        metric("Chaînes", count: counts.channels, symbol: "dot.radiowaves.left.and.right")
                        metric("Films", count: counts.movies, symbol: "film")
                        metric("Séries", count: counts.series, symbol: "rectangle.stack")
                    }
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
            Text(count.formatted()).font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
            Text(name).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.fill.tertiary, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    @concurrent
    private static func counts(for id: SourceID, in catalog: Catalog) async -> ImportCounts {
        catalog.counts(for: id)
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
                Section("Métadonnées") {
                    SecureField("Clé TMDB", text: $metadataKey)
                    Button("Enregistrer la clé") { app.setTMDBKey(metadataKey) }
                    Text("La clé enrichit les fiches de vos films et séries avec les visuels et les informations de TMDB.")
                        .font(.caption).foregroundStyle(.secondary)
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
        .task { metadataKey = app.tmdbKey ?? "" }
        .sheet(isPresented: $showAddSource) {
            AddSourceView(onImported: {
                app.completeOnboarding()
                showAddSource = false
            })
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
