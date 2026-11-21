import Foundation
import PrismCore
import PrismData
import PrismDesign
import SwiftUI
import UniformTypeIdentifiers

/// Shared by first launch and the Sources section of the sidebar.
struct AddSourceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var kind: SourceKind?
    @State private var draftID = SourceID.generate()
    @State private var name = ""
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var guideAddress = ""
    @State private var userAgent = ""
    @State private var file: SelectedFile?
    @State private var showsFileImporter = false
    @State private var advanced = false
    @State private var showsValidation = false
    @State private var error: String?
    @State private var progress: ImportProgress?
    @State private var importTask: Task<Void, Never>?
    @State private var started = false
    @FocusState private var focus: Field?

    var allowsDemo = false
    var startsDemo = false
    let onImported: @MainActor () -> Void

    private struct SelectedFile {
        let url: URL
        let bookmark: Data
    }

    private enum Field: Hashable {
        case name, address, username, password, guide, userAgent
    }

    private static let locale = Locale(identifier: "fr_FR")
    private static let allowedFiles = [UTType(filenameExtension: "m3u"), UTType(filenameExtension: "m3u8")].compactMap { $0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Group {
                if let progress {
                    importStatus(progress)
                } else if let kind {
                    sourceForm(kind)
                } else {
                    choices
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 22)
            .transition(.opacity)
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityAddTraits(.updatesFrequently)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 12)
            }
            footer
        }
        .frame(width: 552, height: 470)
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: Self.allowedFiles, onCompletion: importFile)
        .interactiveDismissDisabled(importTask != nil || progress?.stage == .finished)
        .onDisappear { importTask?.cancel() }
        .task {
            guard startsDemo, !started else { return }
            started = true
            runImport { model.importDemo() }
        }
    }

    private var header: some View {
        let finished = progress?.stage == .finished
        let importing = progress != nil && !finished
        return SourceSheetHeading(
            title: finished ? "Tout est prêt" : importing ? "Importation de la source" : kind?.setupTitle ?? "Ajouter une source",
            subtitle: progress == nil ? kind?.setupHelp ?? "Choisissez le format fourni par votre service IPTV." : nil,
            symbol: finished ? "checkmark.seal.fill" : importing ? "arrow.down.circle" : kind?.setupIcon ?? "rectangle.connected.to.line.below"
        )
    }

    private var choices: some View {
        VStack(spacing: 0) {
            ForEach(SourceKind.allCases, id: \.self) { option in
                Button {
                    changeStep { kind = option }
                } label: {
                    HStack(spacing: 13) {
                        Image(systemName: option.setupIcon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 22)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.setupTitle).font(.callout.weight(.semibold))
                            Text(option.setupHelp).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .contentShape(.rect(cornerRadius: PrismMetrics.listRowRadius))
                }
                .buttonStyle(.plain)
                if option != SourceKind.allCases.last {
                    Divider().padding(.leading, 49).padding(.trailing, 14)
                }
            }
        }
        .padding(4)
        .background(PrismColors.panelFill, in: .rect(cornerRadius: PrismMetrics.panelRadius))
    }

    private func sourceForm(_ kind: SourceKind) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                if kind == .m3uFile {
                    HStack(spacing: 10) {
                        Button("Choisir le fichier…", systemImage: "folder") { showsFileImporter = true }
                            .buttonStyle(.glass)
                        if let file {
                            Text(file.url.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if showsValidation, file == nil { validationText("Sélectionnez une playlist M3U sur votre Mac.") }
                } else {
                    formField(kind == .xtream ? "Adresse du serveur" : "URL de la playlist") {
                        TextField(kind == .xtream ? "https://iptv.exemple.com:8080" : "https://exemple.com/playlist.m3u", text: $address)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .address)
                    }
                    if showsValidation, sourceURL == nil { validationText("Saisissez une adresse HTTP ou HTTPS valide.") }
                }
                if kind == .xtream {
                    HStack(alignment: .top, spacing: 12) {
                        formField("Identifiant") {
                            TextField("Nom d’utilisateur", text: $username)
                                .autocorrectionDisabled()
                                .focused($focus, equals: .username)
                        }
                        formField("Mot de passe") {
                            SecureField("Mot de passe", text: $password)
                                .focused($focus, equals: .password)
                        }
                    }
                    if showsValidation, trimmed(username).isEmpty || password.isEmpty { validationText("Indiquez vos identifiants Xtream.") }
                    HStack(spacing: 10) {
                        PasteButton(payloadType: String.self) { values in
                            guard let message = values.first else { return }
                            fillXtreamFields(from: message)
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Coller les codes Xtream")
                        Text("Depuis un lien ou un message de votre fournisseur")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                formField("Nom de la source · facultatif") {
                    TextField("Ma source", text: $name)
                        .focused($focus, equals: .name)
                }
                DisclosureGroup("Options avancées", isExpanded: $advanced) {
                    VStack(alignment: .leading, spacing: 13) {
                        formField("Guide TV XMLTV · facultatif") {
                            TextField("https://exemple.com/guide.xml", text: $guideAddress)
                                .autocorrectionDisabled()
                                .focused($focus, equals: .guide)
                        }
                        if showsValidation, !trimmed(guideAddress).isEmpty, remoteURL(guideAddress) == nil {
                            validationText("Indiquez une URL HTTP ou HTTPS pour le guide.")
                        }
                        formField("User-Agent · facultatif") {
                            TextField("Agent utilisateur du lecteur", text: $userAgent)
                                .focused($focus, equals: .userAgent)
                        }
                        if showsValidation, !validUserAgent { validationText("Le User-Agent doit tenir sur une seule ligne.") }
                    }
                    .padding(.top, 11)
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(PrismColors.panelFill, in: .rect(cornerRadius: PrismMetrics.panelRadius))
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 12)
        }
        .defaultFocus($focus, kind == .m3uFile ? .name : .address)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .onSubmit(startSelectedImport)
    }

    private func formField(_ title: String, @ViewBuilder entry: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .accessibilityHidden(true)
            entry()
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func validationText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.red)
    }

    private func importStatus(_ progress: ImportProgress) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            if progress.stage != .finished {
                VStack(alignment: .leading, spacing: 8) {
                    Text(progress.stage.statusLabel)
                        .font(.callout.weight(.semibold))
                        .accessibilityAddTraits(.updatesFrequently)
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .accessibilityLabel("Progression de l’importation")
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: progress.fraction)
                }
            }
            VStack(spacing: 1) {
                countRow("Chaînes", count: progress.counts.channels, icon: "play.tv")
                Divider()
                countRow("Films", count: progress.counts.movies, icon: "film")
                Divider()
                countRow("Séries", count: progress.counts.series, icon: "tv")
                Divider()
                countRow("Programmes du guide", count: progress.counts.programs, icon: "calendar")
            }
            .padding(.horizontal, 13)
            .background(PrismColors.panelFill, in: .rect(cornerRadius: PrismMetrics.panelRadius))
        }
        .padding(.top, 4)
    }

    private func countRow(_ title: String, count: Int, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(title)
            Spacer(minLength: 8)
            Text(count.formatted(.number.locale(Self.locale)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(reduceMotion ? .identity : .numericText(value: Double(count)))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: count)
        }
        .font(.callout)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        SourceSheetFooter {
            if progress?.stage == .finished {
                Spacer()
                Button(allowsDemo ? "Ouvrir Prism" : "Terminer", action: onImported)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            } else if importTask != nil {
                Button("Annuler l’importation") { importTask?.cancel() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Spacer()
            } else if kind != nil {
                Button("Retour") {
                    changeStep {
                        kind = nil
                        showsValidation = false
                        error = nil
                        address = ""
                        username = ""
                        password = ""
                    }
                }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Se connecter", systemImage: "arrow.right", action: startSelectedImport)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Annuler", role: .cancel, action: { dismiss() })
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if allowsDemo {
                    Button("Essayer la démo") { runImport { model.importDemo() } }
                        .buttonStyle(.glass)
                }
            }
        }
    }

    private var sourceURL: URL? {
        kind == .xtream ? XtreamCredentials.normalizeServer(address) : remoteURL(address)
    }

    private var validUserAgent: Bool { !trimmed(userAgent).contains(where: \.isNewline) }

    private func fillXtreamFields(from message: String) {
        guard let credentials = XtreamCredentials.fromProviderMessage(message) else {
            error = "Codes introuvables. Collez le lien Xtream complet ou renseignez les trois champs."
            return
        }
        address = credentials.server.absoluteString
        username = credentials.username
        password = credentials.password
        error = nil
        focus = nil
    }

    private func startSelectedImport() {
        guard let kind, importTask == nil else { return }
        error = nil
        showsValidation = true
        if kind == .xtream, trimmed(username).isEmpty, password.isEmpty,
           let credentials = XtreamCredentials.fromProviderMessage(address) {
            address = credentials.server.absoluteString
            username = credentials.username
            password = credentials.password
        }
        if !trimmed(guideAddress).isEmpty, remoteURL(guideAddress) == nil {
            advanced = true
            focus = .guide
            return
        }
        if !validUserAgent {
            advanced = true
            focus = .userAgent
            return
        }
        if kind == .m3uFile, file == nil { return }
        if kind != .m3uFile, sourceURL == nil { focus = .address; return }
        if kind == .xtream, trimmed(username).isEmpty || password.isEmpty {
            focus = trimmed(username).isEmpty ? .username : .password
            return
        }
        let proposedName = trimmed(name)
        let defaultName = kind == .m3uFile ? file?.url.deletingPathExtension().lastPathComponent : sourceURL?.host()
        let guideURL = remoteURL(guideAddress)
        let agent = trimmed(userAgent)
        let source = Source(
            id: draftID,
            name: proposedName.isEmpty ? defaultName ?? kind.setupTitle : proposedName,
            kind: kind,
            serverURL: kind == .m3uFile ? file?.url : sourceURL,
            username: kind == .xtream ? trimmed(username) : nil,
            fileBookmark: kind == .m3uFile ? file?.bookmark : nil,
            epgURL: guideURL,
            userAgent: agent.isEmpty ? nil : agent,
            tint: SourceTint.allCases[model.sources.count % SourceTint.allCases.count]
        )
        let password = kind == .xtream ? self.password : nil
        runImport { model.importSource(source, password: password) }
    }

    private func runImport(_ stream: @escaping @MainActor () -> AsyncThrowingStream<ImportProgress, any Error>) {
        guard importTask == nil else { return }
        changeStep {
            error = nil
            progress = ImportProgress(stage: .connecting, fraction: 0)
        }
        importTask = Task {
            defer { importTask = nil }
            do {
                for try await value in stream() {
                    try Task.checkCancellation()
                    progress = value
                }
                try Task.checkCancellation()
                if progress?.stage != .finished { throw SourceError.emptyPlaylist }
            } catch is CancellationError {
                changeStep { progress = nil }
            } catch {
                changeStep {
                    progress = nil
                    self.error = displayError(error)
                }
            }
        }
    }

    private func importFile(_ result: Result<URL, any Error>) {
        do {
            let selected = try result.get()
            let hasScope = selected.startAccessingSecurityScopedResource()
            defer { if hasScope { selected.stopAccessingSecurityScopedResource() } }
            let bookmark = try selected.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            file = SelectedFile(url: selected, bookmark: bookmark)
            error = nil
        } catch let cancelled as CocoaError where cancelled.code == .userCancelled {
            return
        } catch {
            self.error = "Prism n’a pas pu ouvrir ce fichier. Sélectionnez une playlist M3U accessible."
        }
    }

    private func changeStep(_ update: () -> Void) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22), update)
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func remoteURL(_ text: String) -> URL? {
        let candidate = trimmed(text)
        guard !candidate.isEmpty, !candidate.contains(where: \.isWhitespace),
              let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = url.host(), !host.isEmpty,
              url.port.map({ (1...65_535).contains($0) }) ?? true else { return nil }
        return url
    }

    private func displayError(_ error: any Error) -> String {
        if let error = error as? KeychainError { return error.localizedDescription }
        if let error = error as? SourceError {
            if case .network = error { return "Connexion à la source impossible. Vérifiez l’adresse et réessayez." }
            return error.localizedDescription
        }
        if let error = error as? XtreamError {
            if case .network = error { return "Connexion au serveur impossible. Vérifiez l’adresse et réessayez." }
            return error.localizedDescription
        }
        return "L’importation a échoué. Vérifiez les informations de la source et réessayez."
    }
}

private extension SourceKind {
    var setupTitle: String {
        switch self {
        case .xtream: "Xtream Codes"
        case .m3uURL: "URL M3U"
        case .m3uFile: "Fichier M3U"
        }
    }

    var setupHelp: String {
        switch self {
        case .xtream: "Serveur, identifiant et mot de passe."
        case .m3uURL: "Adresse d’une playlist M3U ou M3U8."
        case .m3uFile: "Playlist enregistrée sur votre Mac."
        }
    }

    var setupIcon: String {
        switch self {
        case .xtream: "server.rack"
        case .m3uURL: "link"
        case .m3uFile: "doc.text"
        }
    }
}

private extension ImportStage {
    var statusLabel: String {
        switch self {
        case .connecting: "Connexion à la source…"
        case .account: "Vérification du compte…"
        case .downloading: "Téléchargement de la playlist…"
        case .parsing: "Lecture de la playlist…"
        case .channels: "Organisation des chaînes…"
        case .movies: "Regroupement des films…"
        case .series: "Regroupement des séries…"
        case .guide: "Mise à jour du guide TV…"
        case .finished: "Importation terminée"
        }
    }
}
