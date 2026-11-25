import SwiftUI
import PrismCore
import PrismData
import PrismDesign

struct SourceDetailView: View {
    @Environment(AppModel.self) private var app
    let sourceID: SourceID
    /// Comptages calculés une fois par publication de catalogue dans `AppModel`
    /// (`countsBySource`) — plus de 3 scans O(catalogue) à chaque visite de page.
    private var counts: ImportCounts { app.sourceCounts[sourceID] ?? ImportCounts() }
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
                            // `importProgress(for:)` ne souscrit qu'à la cellule de
                            // cette source : les ticks des autres imports ne
                            // réévaluent pas cette fiche.
                            if let progress = app.importProgress(for: sourceID) {
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
                                .buttonStyle(.glass)
                            }
                            HStack {
                                Button("Actualiser", systemImage: "arrow.clockwise") { Task { await app.refresh(sourceID) } }
                                    .disabled(!source.isEnabled || app.isImporting(sourceID))
                                Button("Modifier…", systemImage: "pencil") { editing = true }
                                Spacer()
                                Button("Supprimer…", role: .destructive) { removing = true }
                            }
                            .buttonStyle(.glass)
                            .disabled(app.isImporting(sourceID))
                        }
                    }
                    .formStyle(.grouped)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
                }
                .padding(.vertical, 24)
            }
            .prismScrollPhase()
            // Les comptages par source sont calculés à la demande (une passe
            // @concurrent sur tout le catalogue) : cette fiche est leur seule
            // lectrice, on les prépare à l'ouverture et après chaque republication.
            .task(id: app.catalogRevision) { app.prepareSourceCounts() }
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
}

private struct SourceCategorySheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let source: Source
    let categories: [PrismCore.Category]
    @State private var hiddenIDs: Set<String>
    @State private var query = ""
    @State private var filtered: [MediaKind: [PrismCore.Category]]?

    private struct SearchKey: Equatable {
        let term: String
        let catalogRevision: Int
    }

    init(source: Source, categories: [PrismCore.Category], hiddenIDs: Set<String>) {
        self.source = source
        self.categories = categories
        self._hiddenIDs = State(initialValue: hiddenIDs)
    }

    var body: some View {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 0) {
            SourceSheetHeading(title: "Catégories visibles", subtitle: source.name, symbol: "line.3.horizontal.decrease")
            if categories.isEmpty {
                ContentUnavailableView("Catégories indisponibles", systemImage: "line.3.horizontal.decrease")
                    .frame(maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Rechercher une catégorie", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                    if let filtered {
                        if filtered.isEmpty {
                            ContentUnavailableView.search(text: term)
                                .frame(maxHeight: .infinity)
                        } else {
                            results(filtered)
                        }
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityLabel("Chargement des catégories")
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 12)
            }
            SourceSheetFooter {
                Button("Tout afficher") { hiddenIDs.removeAll() }
                    .buttonStyle(.glass)
                    .disabled(hiddenIDs.isEmpty)
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Appliquer") {
                    app.setHiddenCategoryIDs(hiddenIDs, for: source.id)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 552, height: 490)
        .task(id: SearchKey(term: term, catalogRevision: app.catalogRevision)) {
            if !term.isEmpty { try? await Task.sleep(for: .milliseconds(130)) }
            guard !Task.isCancelled else { return }
            let groups = await Self.matchingCategories(categories, term: term)
            if !Task.isCancelled { filtered = groups }
        }
    }

    private func results(_ groups: [MediaKind: [PrismCore.Category]]) -> some View {
        List {
            ForEach([MediaKind.live, .movie, .series], id: \.self) { kind in
                if let categories = groups[kind] {
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
        .clipShape(.rect(cornerRadius: PrismMetrics.panelRadius))
    }

    @concurrent private static func matchingCategories(
        _ categories: [PrismCore.Category], term: String
    ) async -> [MediaKind: [PrismCore.Category]] {
        Dictionary(grouping: categories.lazy.filter { term.isEmpty || $0.name.localizedStandardContains(term) }, by: \.kind)
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
    @State private var saveFailed = false

    private func httpURL(_ value: String) -> URL? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host?.isEmpty == false else { return nil }
        return url
    }

    var body: some View {
        VStack(spacing: 0) {
            SourceSheetHeading(title: "Modifier la source", subtitle: source.kind.displayLabel, symbol: "pencil")
            Form {
                Section("Source") {
                    TextField("Nom", text: $source.name)
                    if source.kind != .m3uFile {
                        TextField(source.kind == .xtream ? "Adresse du serveur" : "URL de la liste M3U", text: $server)
                            .autocorrectionDisabled()
                    }
                    if source.kind == .xtream {
                        TextField("Identifiant", text: Binding(get: { source.username ?? "" }, set: { source.username = $0 }))
                            .autocorrectionDisabled()
                        SecureField("Nouveau mot de passe (facultatif)", text: $password)
                    }
                }
                Section("Options avancées") {
                    TextField("URL du guide XMLTV", text: $guideURL).autocorrectionDisabled()
                    TextField("User-Agent", text: $userAgent).autocorrectionDisabled()
                    if source.kind == .xtream {
                        Toggle("Préférer le flux HLS en direct", isOn: $source.preferHLSForLive)
                    }
                    Stepper("Décalage du guide · \(source.epgTimeShiftHours.formatted()) h",
                            value: $source.epgTimeShiftHours, in: -12...14, step: 0.5)
                }
            }
            .formStyle(.grouped)
            SourceSheetFooter {
                if app.isImporting(source.id) {
                    Text("Actualisation en cours…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Enregistrer") {
                    source.name = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if source.kind != .m3uFile { source.serverURL = httpURL(server) }
                    source.epgURL = httpURL(guideURL)
                    source.username = source.username?.trimmingCharacters(in: .whitespacesAndNewlines)
                    source.userAgent = userAgent.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    if app.update(source, password: password.nilIfEmpty) {
                        dismiss()
                    } else {
                        saveFailed = true
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(app.isImporting(source.id) ||
                          source.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          (source.kind != .m3uFile && httpURL(server) == nil) ||
                          (source.kind == .xtream && source.username?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false) ||
                          (!guideURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && httpURL(guideURL) == nil))
            }
        }
        .frame(width: 552, height: 490)
        .alert("Impossible d’enregistrer la source", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        }
        .onAppear {
            server = source.serverURL?.absoluteString ?? ""
            guideURL = source.epgURL?.absoluteString ?? ""
            userAgent = source.userAgent ?? ""
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
