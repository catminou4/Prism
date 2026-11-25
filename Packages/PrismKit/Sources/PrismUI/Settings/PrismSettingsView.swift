import SwiftUI
import AppKit
import PrismCore
import PrismData
import PrismDesign
import PrismPlayer

/// The Prism settings window (`⌘,`), in the macOS 26 grouped-settings idiom: toolbar tabs,
/// rounded cards of hairline-separated rows with tinted icon tiles, semibold section headers
/// and secondary footnotes. Purely declarative — no timers, no redraw-prone state.
struct PrismSettingsView: View {
    enum Page: Hashable { case general, home, player, services }

    @Environment(AppModel.self) private var app
    @State private var page: Page
    @State private var metadataKey = ""
    @State private var sportsAPIKey = ""
    @State private var sportsKeySaved = false
    @State private var sportsKeyError: String?
    @State private var showAddSource = false
    @State private var preferences = PlayerPreferences.standard

    private static let tmdbLogo: NSImage? = Bundle.module.url(forResource: "TMDBLogo", withExtension: "svg")
        .flatMap { NSImage(contentsOf: $0) }

    init(initialPage: Page = .general) {
        _page = State(initialValue: initialPage)
    }

    var body: some View {
        TabView(selection: $page) {
            Tab("Général", systemImage: "gearshape", value: .general) { generalPage }
            Tab("Accueil", systemImage: "house", value: .home) { HomeSettingsPage() }
            Tab("Lecteur", systemImage: "play.rectangle", value: .player) { playerPage }
            Tab("Services", systemImage: "network", value: .services) { servicesPage }
        }
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

    // MARK: - Général

    private var generalPage: some View {
        @Bindable var app = app
        return SettingsPage {
            SettingsGroup("Catalogue") {
                SettingsRow(symbol: "hand.raised", tint: .red, title: "Masquer les contenus pour adultes") {
                    SettingsToggle("Masquer les contenus pour adultes", isOn: $app.hideAdultContent)
                }
            }
            SettingsGroup("Sources") {
                SettingsRow(
                    symbol: "arrow.clockwise", tint: .blue,
                    title: "Toutes les sources",
                    subtitle: app.isImportingAnything ? "Actualisation en cours…" : nil
                ) {
                    SettingsCapsuleButton(title: "Actualiser") {
                        Task { await app.refreshAll() }
                    }
                    .accessibilityLabel("Actualiser toutes les sources")
                    .disabled(app.sources.isEmpty || app.isImportingAnything)
                }
                SettingsRow(symbol: "plus", tint: .green, title: "Nouvelle source") {
                    SettingsCapsuleButton(title: "Ajouter…") {
                        showAddSource = true
                    }
                    .accessibilityLabel("Ajouter une source…")
                }
            }
            SettingsGroup(
                "Recommandations",
                footer: "Langues audio des titres suggérés dans Accueil, Films et Séries. « Pas intéressé » masque un titre des sélections ; il reste accessible dans la recherche et les catégories."
            ) {
                SettingsRow(symbol: "speaker.wave.2", tint: .purple, title: "Langues audio") {
                    Picker("Langues audio", selection: Binding(
                        get: { app.homeAudioLanguages },
                        set: { app.setHomeAudioLanguages($0) }
                    )) {
                        Text("Français").tag(Set([HomeAudioLanguage.french]))
                        Text("Anglais").tag(Set([HomeAudioLanguage.english]))
                        Text("Français et anglais").tag(HomeAudioLanguage.defaults)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow(symbol: "eye.slash", tint: .teal, title: "Titres masqués") {
                    HStack(spacing: 10) {
                        Text(app.library.dismissed.count, format: .number)
                            .font(SettingsMetrics.rowFont)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        SettingsCapsuleButton(title: "Tout proposer à nouveau") { app.library.clearDismissed() }
                            .disabled(app.library.dismissed.isEmpty)
                    }
                }
            }
        }
    }

    // MARK: - Lecteur

    private var playerPage: some View {
        @Bindable var preferences = preferences
        return SettingsPage {
            SettingsGroup(
                "Lecture",
                footer: "« Automatique » choisit le moteur selon le format du flux, avec repli sur l’autre moteur en cas d’échec."
            ) {
                SettingsRow(symbol: "film", tint: .blue, title: "Moteur vidéo") {
                    Picker("Moteur vidéo", selection: $preferences.defaultEngine) {
                        ForEach(PlaybackEngineKind.allCases, id: \.self) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow(symbol: "aspectratio", tint: .purple, title: "Conserver les proportions de la fenêtre") {
                    SettingsToggle("Conserver les proportions de la fenêtre", isOn: $preferences.keepsWindowAspectRatio)
                }
            }
            SettingsGroup(
                "Langues",
                footer: "Les langues préférées s’appliquent lorsque le flux propose plusieurs pistes audio ou de sous-titres."
            ) {
                SettingsRow(symbol: "speaker.wave.2", tint: .orange, title: "Audio préféré") {
                    Picker("Audio préféré", selection: $preferences.preferredAudioLanguage) {
                        Text("Par défaut").tag(nil as String?)
                        Text("Français").tag("fr" as String?)
                        Text("Anglais").tag("en" as String?)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow(symbol: "captions.bubble", tint: .blue, title: "Activer les sous-titres") {
                    SettingsToggle("Activer les sous-titres", isOn: $preferences.subtitlesEnabled)
                }
                SettingsRow(symbol: "globe", tint: .teal, title: "Langue des sous-titres") {
                    Picker("Langue des sous-titres", selection: $preferences.preferredSubtitleLanguage) {
                        Text("Par défaut").tag(nil as String?)
                        Text("Français").tag("fr" as String?)
                        Text("Anglais").tag("en" as String?)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                .disabled(!preferences.subtitlesEnabled)
            }
        }
    }

    // MARK: - Services

    private var servicesPage: some View {
        SettingsPage {
            SettingsGroup(
                "Films et séries",
                footer: "TMDB enrichit les fiches et affiche les tendances disponibles dans vos sources.",
                separatorInset: SettingsMetrics.separatorInsetPlain
            ) {
                SettingsKeyRow(
                    symbol: "movieclapper", tint: .blue,
                    title: "Clé TMDB", text: $metadataKey,
                    saveTitle: "Enregistrer", saveAccessibilityLabel: "Enregistrer la clé TMDB"
                ) {
                    app.setTMDBKey(metadataKey)
                }
            }
            SettingsGroup(
                "Scores sportifs",
                footer: "Pour suivre les scores en direct, ajoutez une clé TheSportsDB Premium."
            ) {
                SettingsKeyRow(
                    symbol: "sportscourt", tint: .green,
                    title: "Clé TheSportsDB", text: $sportsAPIKey,
                    saveTitle: "Enregistrer", saveAccessibilityLabel: "Enregistrer la clé TheSportsDB",
                    saveEnabled: !sportsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    saveSportsKey(sportsAPIKey)
                }
                if let sportsKeyError {
                    HStack(spacing: SettingsMetrics.iconSpacing) {
                        SettingsIconTile(symbol: "exclamationmark.circle", tint: .red)
                        Text(sportsKeyError)
                            .font(SettingsMetrics.rowFont)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, SettingsMetrics.rowPadding)
                    .padding(.vertical, 7)
                    .accessibilityElement(children: .combine)
                }
                if sportsKeySaved {
                    SettingsActionRow(symbol: "trash", tint: .red, title: "Retirer la clé", destructive: true) {
                        saveSportsKey(nil)
                    }
                }
            }
            SettingsGroup(
                "Crédits",
                footer: "This product uses the TMDB API but is not endorsed or certified by TMDB.",
                separatorInset: SettingsMetrics.separatorInsetPlain
            ) {
                HStack {
                    if let website = URL(string: "https://www.themoviedb.org") {
                        Link(destination: website) {
                            if let logo = Self.tmdbLogo {
                                Image(nsImage: logo)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 110)
                                    .accessibilityLabel("TMDB")
                            } else {
                                Text("TMDB")
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, SettingsMetrics.rowPadding)
                .padding(.vertical, 10)
            }
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

/// A settings tab page: stacked groups with the page margins of the macOS settings idiom.
private struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        VStack(spacing: SettingsMetrics.groupSpacing) {
            content()
        }
        .padding(.horizontal, SettingsMetrics.pageMargin)
        .padding(.vertical, SettingsMetrics.pageMargin)
        .frame(width: 600)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Accueil

/// Home page sections and automatic previews (`HomeSections` keys, shared with the shell).
private struct HomeSettingsPage: View {
    @AppStorage(HomeSections.hero) private var hero = true
    @AppStorage(HomeSections.continueWatching) private var continueWatching = true
    @AppStorage(HomeSections.sport) private var sport = true
    @AppStorage(HomeSections.watchlist) private var watchlist = true
    @AppStorage(HomeSections.recommendations) private var recommendations = true
    @AppStorage(HomeSections.genres) private var genres = true
    @AppStorage(HomeSections.previews) private var previews = true

    var body: some View {
        SettingsPage {
            SettingsGroup(
                "Sections de l’accueil",
                footer: "Choisissez les sections affichées sur la page Accueil."
            ) {
                SettingsRow(symbol: "sparkles", tint: .orange, title: "Grandes recommandations") {
                    SettingsToggle("Grandes recommandations", isOn: $hero)
                }
                SettingsRow(symbol: "play.rectangle", tint: .blue, title: "Reprendre la lecture") {
                    SettingsToggle("Reprendre la lecture", isOn: $continueWatching)
                }
                SettingsRow(symbol: "sportscourt", tint: .green, title: "Sport") {
                    SettingsToggle("Sport", isOn: $sport)
                }
                SettingsRow(symbol: "plus.circle", tint: .pink, title: "Ma liste") {
                    SettingsToggle("Ma liste", isOn: $watchlist)
                }
                SettingsRow(symbol: "rectangle.stack", tint: .purple, title: "Sélections et recommandations") {
                    SettingsToggle("Sélections et recommandations", isOn: $recommendations)
                }
                SettingsRow(symbol: "tag", tint: .teal, title: "Genres") {
                    SettingsToggle("Genres", isOn: $genres)
                }
            }
            SettingsGroup(
                "Aperçus",
                footer: "Les aperçus démarrent sans son et peuvent utiliser le flux de votre source."
            ) {
                SettingsRow(symbol: "play.rectangle.on.rectangle", tint: .blue, title: "Aperçus vidéo automatiques") {
                    SettingsToggle("Aperçus vidéo automatiques", isOn: $previews)
                }
            }
        }
    }
}
