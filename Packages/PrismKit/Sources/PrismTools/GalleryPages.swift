import PrismDesign
import SwiftUI

/// Gallery pages rendered by `prism-tools gallery`. Each page renders in dark and light.
enum GalleryPages {
    static func all(assets: GalleryAssets) -> [GalleryPage] {
        [
            GalleryPage(name: "controls", size: CGSize(width: 900, height: 330)) { AnyView(ControlsPage()) },
            GalleryPage(name: "badges-text", size: CGSize(width: 900, height: 300), schemes: [.dark]) { AnyView(BadgesPage()) },
            GalleryPage(name: "cards-wide", size: CGSize(width: 1000, height: 520)) { AnyView(WideCardsPage(assets: assets)) },
            GalleryPage(name: "cards-poster", size: CGSize(width: 1000, height: 600)) { AnyView(PosterCardsPage(assets: assets)) },
            GalleryPage(name: "cards-detail", size: CGSize(width: 1000, height: 940)) { AnyView(DetailCardsPage(assets: assets)) },
            GalleryPage(name: "shelves", size: CGSize(width: 1000, height: 640)) { AnyView(ShelvesPage(assets: assets)) },
            GalleryPage(name: "shelves-hover", size: CGSize(width: 1000, height: 640), schemes: [.light]) {
                AnyView(ShelvesPage(assets: assets).environment(\.prismSnapshotHover, true))
            },
            GalleryPage(name: "hero-detail", size: CGSize(width: 1000, height: 561), schemes: [.dark]) { AnyView(HeroDetailPage(assets: assets)) },
            GalleryPage(name: "hero-home", size: CGSize(width: 1000, height: 400), schemes: [.dark]) { AnyView(HeroHomePage(assets: assets)) },
            GalleryPage(name: "hero-poster", size: CGSize(width: 1000, height: 561), schemes: [.dark]) { AnyView(HeroPosterPage(assets: assets)) },
            GalleryPage(name: "brand", size: CGSize(width: 1000, height: 560), backend: .imageRenderer) { AnyView(BrandPage()) },
            GalleryPage(name: "onboarding", size: CGSize(width: 1220, height: 720), schemes: [.dark], backend: .imageRenderer) { AnyView(OnboardingPage()) },
            GalleryPage(
                name: "posterwall-hero", size: CGSize(width: 1000, height: 561), schemes: [.dark], backend: .imageRenderer,
                prewarm: assets.posters.map { ($0, CGSize(width: 140, height: 210)) }
            ) { AnyView(PosterWallHeroPage(assets: assets)) },
            GalleryPage(name: "misc", size: CGSize(width: 1000, height: 900)) { AnyView(MiscPage()) },
        ]
    }
}

// MARK: - Pages

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

struct ControlsPage: View {
    @State private var chip: String? = "all"

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Section(title: "Hero buttons (on black)") {
                HStack(spacing: 12) {
                    PrimaryCapsuleButton("Lecture", systemImage: "play.fill") {}
                    PrimaryCapsuleButton("33 min", systemImage: "play.fill", progress: 0.4) {}
                    WatchlistButton(isAdded: false) {}
                    WatchlistButton(isAdded: true) {}
                    GlassCapsuleButton(title: "Source A · 4K", tint: PrismTint.purple.color) {}
                }
                .padding(16)
                .background(.black, in: .rect(cornerRadius: 12))
            }
            Section(title: "Glass circles") {
                HStack(spacing: 8) {
                    GlassCircleButton(systemName: "chevron.left") {}
                    GlassCircleButton(systemName: "speaker.slash") {}
                    GlassCircleButton(systemName: "arrow.up.left.and.arrow.down.right") {}
                    GlassCircleButton(systemName: "square.and.arrow.up") {}
                    GlassCircleButton(systemName: "chevron.right", size: PrismMetrics.shelfChevronSize) {}
                    PrimaryCapsuleButton("Continuer", style: .accent, height: PrismMetrics.largeButtonHeight, minWidth: 220) {}
                }
            }
            Section(title: "Chips") {
                ChipBar(
                    items: [
                        ChipItem(id: "all", title: "Toutes", count: 12_453),
                        ChipItem(id: "fav", title: "Favorites", systemImage: "star.fill"),
                        ChipItem(id: "sport", title: "Sport"),
                        ChipItem(id: "news", title: "Info"),
                        ChipItem(id: "kids", title: "Jeunesse"),
                        ChipItem(id: "cinema", title: "Cinéma"),
                        ChipItem(id: "docs", title: "Documentaires"),
                    ],
                    selection: $chip,
                    horizontalMargin: 0
                )
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PrismColors.pageBackground)
    }
}

struct BadgesPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                LabelPill("Nouveau")
                LabelPill("Ajouté récemment")
                LiveBadge()
                LiveBadge("LIVE", pulsing: false, compact: true)
                AgeRatingBadge("16+")
                AgeRatingBadge("18+")
            }
            MetadataLine(items: ["Série TV", "Thriller", "Mystère"], leadingGlyph: Image(systemName: "play.tv.fill")) {
                AgeRatingBadge("16+")
            }
            .foregroundStyle(.white.opacity(0.86))
            TechLine(items: ["2022", "57 min"], badges: [.init("4K", style: .filled), .init("HDR", style: .filled), .init("CC", style: .outlined), .init("SDH", style: .outlined), .init("AD", style: .outlined), .init(automatic: "VOSTFR")])
                .foregroundStyle(.white.opacity(0.78))
            ExpandableText(
                "Mark est promu à la tête d'une équipe d'employés dont les souvenirs ont été chirurgicalement divisés entre leur travail et leur vie privée.",
                emphasis: "S1, É1 · Bonne nouvelle sur l'enfer :"
            )
            .foregroundStyle(.white.opacity(0.82))
            .frame(width: PrismMetrics.heroTextMaxWidth)
            ExpandableText("Une description courte qui tient sur une ligne.")
                .foregroundStyle(.white.opacity(0.82))
                .frame(width: PrismMetrics.heroTextMaxWidth)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.black)
    }
}

struct WideCardsPage: View {
    let assets: GalleryAssets

    var body: some View {
        VStack(alignment: .leading, spacing: PrismMetrics.shelfHeaderSpacing) {
            ShelfHeader("Continuer", action: {})
            HStack(alignment: .top, spacing: 20) {
                WideCard(imageURL: assets.wides[safe: 0], caption: "Dans Ma liste", showsPlayGlyph: false) {} menu: { Button("Retirer") {} }
                WideCard(imageURL: assets.wides[safe: 1], caption: "Dans Ma liste", showsPlayGlyph: false) {} menu: { Button("Retirer") {} }
                WideCard(imageURL: assets.wides[safe: 2], caption: "S1, É1 · 23 min", progress: 0.3) {} menu: { Button("Retirer") {} }
                WideCard(imageURL: nil, seed: "Split", caption: "Dans Ma liste", showsPlayGlyph: false, placeholderTitle: "Split") {} menu: { Button("Retirer") {} }
            }
            .prismCardWidth(215)
            ShelfMenuHeader("Saison 1") {
                Button("Saison 1") {}
                Button("Saison 2") {}
            }
            .padding(.top, 20)
            HStack(alignment: .top, spacing: 20) {
                EpisodeCard(
                    stillURL: assets.stills[safe: 0], eyebrow: "Épisode 1", title: "Pilot",
                    synopsis: "American football coach Ted Lasso is hired by a wealthy divorcée to coach the English Premier League.",
                    duration: "30 min"
                ) {} menu: { Button("Marquer comme vu") {} }
                EpisodeCard(
                    stillURL: assets.stills[safe: 1], eyebrow: "Épisode 2", title: "Biscuits",
                    synopsis: "It's Ted's first day of coaching, and fans aren't happy. He makes little headway but remains upbeat.",
                    duration: "29 min", progress: 0.45
                ) {} menu: { Button("Marquer comme vu") {} }
                EpisodeCard(
                    stillURL: assets.stills[safe: 2], eyebrow: "Épisode 3", title: "Trent Crimm: The Independent",
                    synopsis: "To arrange an in-depth exposé, Rebecca pairs cynical journalist Trent Crimm with Ted for a day.",
                    duration: "30 min", isWatched: true
                ) {} menu: { Button("Marquer comme vu") {} }
                EpisodeCard(
                    stillURL: nil, seed: "ep4", eyebrow: "Épisode 4", title: "For the Children",
                    synopsis: "Rebecca hosts the team's annual charity benefit, where Ted stages a reconciliation between Roy and Jamie.",
                    duration: "33 min"
                ) {} menu: { Button("Marquer comme vu") {} }
            }
            .prismCardWidth(215)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PrismColors.pageBackground)
    }
}

struct PosterCardsPage: View {
    let assets: GalleryAssets
    private let titles = ["Hijack", "Defending Jacob", "Masters of the Air", "Platonic", "Black Bird", "Pluribus"]

    var body: some View {
        VStack(alignment: .leading, spacing: PrismMetrics.shelfHeaderSpacing) {
            ShelfHeader("À ne pas manquer", subtitle: "Disponible en VF.", action: {})
            HStack(alignment: .top, spacing: 20) {
                ForEach(0..<6, id: \.self) { i in
                    if i < 4 {
                        PosterCard(imageURL: assets.posters[safe: i], title: titles[i], badge: i == 1 ? "4K" : nil)
                    } else {
                        PosterCard(imageURL: nil, seed: titles[i], title: titles[i], progress: i == 5 ? 0.4 : nil)
                    }
                }
            }
            .prismCardWidth(137)
            ShelfHeader("Top 10 des séries", action: {}).padding(.top, 14)
            HStack(alignment: .top, spacing: 20) {
                ForEach(0..<6, id: \.self) { i in
                    RankedPosterCard(rank: i + 1, imageURL: i < 3 ? assets.posters[safe: i + 3] : nil, seed: "rank\(i)", title: titles[5 - i], genre: ["Crime", "Thriller", "Drame", "Science-fiction", "Comédie", "Thriller"][i])
                }
            }
            .prismCardWidth(137)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PrismColors.pageBackground)
    }
}

struct DetailCardsPage: View {
    let assets: GalleryAssets

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ShelfHeader("Parcourir")
            HStack(alignment: .top, spacing: 20) {
                CategoryTile(title: "4K HDR", seed: "4k", tint: .blue)
                CategoryTile(title: "Action", imageURL: assets.posters[safe: 0])
                CategoryTile(title: "Comédie", imageURL: assets.posters[safe: 3])
                CategoryTile(title: "Drame", imageURL: assets.stills[safe: 1], seed: "drame")
                ChannelTile(logoURL: nil, name: "France 2", number: 2, programTitle: "Journal de 20 heures", progress: 0.42, tint: .blue)
            }
            .prismCardWidth(137)
            HStack(alignment: .top, spacing: 20) {
                PersonCircle(name: "Adam Scott", role: "Mark", imageURL: assets.portrait)
                PersonCircle(name: "Britt Lower", role: "Helly")
                PersonCircle(name: "Patricia Arquette", role: "Harmony Cobel")
                ChannelTile(logoURL: nil, name: "Canal+ Sport", number: 45, programTitle: "Ligue 1 : PSG – OM", progress: 0.7, tint: .red, width: 260)
                ChannelTile(logoURL: nil, name: "Arte", number: 7, tint: .orange, width: 260)
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    ShelfHeader("Comment regarder ?")
                    SourceCard(name: "Source A", detail: "4K · VF · MKV", tint: .purple, isSelected: true)
                    SourceCard(name: "IPTV Premium", detail: "HD · VOSTFR · MP4", tint: .orange)
                }
                VStack(alignment: .leading, spacing: 12) {
                    ShelfHeader("À propos")
                    AboutCard(
                        title: "Severance", subtitle: "Thriller, Mystère, Drame",
                        text: "Mark dirige une équipe d'employés de bureau dont les souvenirs ont été chirurgicalement séparés entre leur travail et leur vie privée. Lorsqu'une mystérieuse collègue apparaît en dehors du travail, commence un voyage pour découvrir la vérité.",
                        width: 420
                    )
                }
            }
            HStack(alignment: .top, spacing: 40) {
                InfoColumn(title: "Informations", rows: [("Sortie", "2022"), ("Durée", "57 min"), ("Genre", "Thriller")])
                InfoColumn(title: "Technique", rows: [("Vidéo", "4K HDR"), ("Audio", "Dolby Atmos, 5.1"), ("Conteneur", "MKV")])
                InfoColumn(title: "Source", rows: [("Fournisseur", "Source A"), ("Catégorie", "Séries US"), ("Ajouté le", "21 nov. 2026")])
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PrismColors.pageBackground)
    }
}

struct ShelvesPage: View {
    let assets: GalleryAssets
    struct Item: Identifiable { let id: Int }

    var body: some View {
        VStack(alignment: .leading, spacing: PrismMetrics.shelfSpacing) {
            Shelf(title: "Continuer", items: (0..<8).map(Item.init), sizing: .wide, onHeaderTap: {}) { item in
                WideCard(imageURL: assets.wides[safe: item.id], seed: "w\(item.id)", caption: "S1, É\(item.id + 1) · 23 min", progress: 0.2 + Double(item.id) * 0.1, placeholderTitle: "Série \(item.id + 1)") {} menu: {
                    Button("Retirer") {}
                }
            }
            Shelf(title: "Films populaires", subtitle: "Les plus regardés cette semaine.", items: (0..<14).map(Item.init), onHeaderTap: {}) { item in
                PosterCard(imageURL: assets.posters[safe: item.id], seed: "p\(item.id)", title: "Film \(item.id + 1)")
            }
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PrismColors.pageBackground)
    }
}

struct HeroDetailPage: View {
    let assets: GalleryAssets

    var body: some View {
        ZStack {
            HeroBackdrop(imageURL: assets.backdrop, seed: "Severance")
            HeroContent(
                title: "Severance",
                logoURL: assets.logo,
                metadata: ["Série TV", "Thriller", "Mystère"],
                metadataGlyph: Image(systemName: "play.tv.fill"),
                rating: "16+",
                description: "Mark est promu à la tête d'une équipe d'employés dont les souvenirs ont été chirurgicalement divisés.",
                descriptionEmphasis: "S1, É1 · Bonne nouvelle sur l'enfer :",
                techItems: ["2022", "57 min"],
                badges: [.init("4K", style: .filled), .init("CC", style: .outlined), .init("SDH", style: .outlined), .init("AD", style: .outlined)],
                credits: [HeroCredit("Avec", "Adam Scott, Britt Lower et Patricia Arquette")]
            ) {
                PrimaryCapsuleButton("Lecture", systemImage: "play.fill") {}
                WatchlistButton(isAdded: false) {}
                GlassCapsuleButton(title: "Source A · 4K", tint: PrismTint.purple.color) {}
            }
        }
        .overlay(alignment: .top) {
            HStack(spacing: 8) {
                GlassCircleButton(systemName: "chevron.left") {}
                Spacer()
                GlassCircleButton(systemName: "speaker.slash") {}
                GlassCircleButton(systemName: "arrow.up.left.and.arrow.down.right") {}
                GlassCircleButton(systemName: "square.and.arrow.up") {}
            }
            .padding(8)
        }
    }
}

struct HeroHomePage: View {
    let assets: GalleryAssets
    struct Page: Identifiable { let id: Int; let title: String }

    var body: some View {
        HeroCarousel(items: [Page(id: 0, title: "Disclosure Day"), Page(id: 1, title: "Silo"), Page(id: 2, title: "Pluribus")] + (3..<10).map { Page(id: $0, title: "Page \($0)") }) { page in
            ZStack {
                HeroBackdrop(imageURL: page.id == 0 ? assets.backdrop : nil, seed: page.title)
                HeroContent(
                    label: "Nouveau",
                    title: page.title,
                    metadata: ["Film", "Science-fiction", "Thriller"],
                    rating: "12+",
                    description: "Steven Spielberg revient avec une nouvelle rencontre du troisième type, avec Emily Blunt en météorologue prise dans une affaire d'OVNI.",
                    descriptionLineLimit: 3
                ) {
                    PrimaryCapsuleButton("En savoir plus", systemImage: "info.circle") {}
                    WatchlistButton(isAdded: false) {}
                }
            }
        }
    }
}

struct HeroPosterPage: View {
    let assets: GalleryAssets

    var body: some View {
        ZStack {
            HeroBackdrop(imageURL: nil, seed: "Platonic", fallbackPosterURL: assets.posters[safe: 3])
            HeroContent(
                title: "Platonic",
                metadata: ["Série TV", "Comédie"],
                rating: "12+",
                description: "Deux anciens meilleurs amis se retrouvent à la quarantaine et rattrapent le temps perdu.",
                techItems: ["2023", "30 min"],
                badges: [.init("HD", style: .filled), .init("VOSTFR", style: .outlined)],
                credits: [HeroCredit("Avec", "Seth Rogen et Rose Byrne")]
            ) {
                PrimaryCapsuleButton("Reprendre", systemImage: "play.fill", progress: 0.35) {}
                WatchlistButton(isAdded: true) {}
            }
        }
    }
}

struct BrandPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .center, spacing: 28) {
                AppIconArtwork(size: 256)
                AppIconArtwork(size: 128)
                AppIconArtwork(size: 64)
                AppIconArtwork(size: 32)
                AppIconArtwork(size: 16)
            }
            HStack(spacing: 24) {
                PrismLogoLockup(size: 34, wordmarkColor: .white)
                    .padding(24)
                    .background(.black, in: .rect(cornerRadius: 16))
                PrismLogoLockup(size: 34, style: .onLight, wordmarkColor: .black)
                    .padding(24)
                    .background(.white, in: .rect(cornerRadius: 16))
                PrismLogoMark(size: 64, style: .monochrome(.gray))
                    .padding(12)
                PrismLogoMark(size: 28)
                    .padding(8)
                    .background(.black, in: .rect(cornerRadius: 8))
            }
            HStack(spacing: 24) {
                ForEach([0.3, 0.6, 0.9, 1.25, 1.6], id: \.self) { t in
                    AnimatedPrismLogoFrame(time: t)
                        .frame(width: 160, height: 150)
                        .background(.black, in: .rect(cornerRadius: 12))
                }
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PrismColors.pageBackground)
    }
}

struct OnboardingPage: View {
    var body: some View {
        PosterWall(vignette: 0.75, isAnimating: false, startTime: 40)
            .overlay {
                VStack(spacing: 26) {
                    AnimatedPrismLogoFrame(time: 2, size: 44)
                    Text("Toutes vos chaînes, films et séries.\nAu même endroit.")
                        .font(PrismFont.onboardingHeadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                    PrimaryCapsuleButton("Commencer", height: PrismMetrics.largeButtonHeight, minWidth: 220) {}
                }
            }
    }
}

struct PosterWallHeroPage: View {
    let assets: GalleryAssets

    var body: some View {
        let tiles = assets.posters.enumerated().map { PosterWallTile(id: $0.offset, title: "Poster \($0.offset)", imageURL: $0.element) }
            + [PosterWallTile].procedural(count: 24).map { PosterWallTile(id: $0.id + 100, title: $0.title) }
        ZStack {
            PosterWall(tiles: tiles, tileWidth: 140, vignette: 0.35, isAnimating: false, startTime: 12)
            LinearGradient(stops: [.init(color: .black.opacity(0.75), location: 0), .init(color: .clear, location: 0.6)], startPoint: .leading, endPoint: .trailing)
            HeroContent(title: "Regardez Prism", description: "Des milliers d'heures de séries et de films, avec de nouveautés chaque semaine.", descriptionLineLimit: 3) {
                PrimaryCapsuleButton("Commencer") {}
            }
        }
    }
}

struct MiscPage: View {
    @State private var toast: ToastMessage? = ToastMessage("Ajouté à Ma liste", systemImage: "checkmark.circle.fill")

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 24) {
                EmptyStateView(title: "Ajouter à la bibliothèque", message: "Les films et séries que vous ajoutez à Ma liste s'afficheront ici.", actionTitle: "Parcourir l'accueil") {}
                    .frame(width: 460, height: 260)
                    .background(PrismColors.panelFill, in: .rect(cornerRadius: 12))
                EmptyStateView(symbol: "star", title: "Aucune chaîne favorite", message: "Ajoutez des chaînes depuis TV en direct.")
                    .frame(width: 420, height: 260)
                    .background(PrismColors.panelFill, in: .rect(cornerRadius: 12))
            }
            HStack(spacing: 16) {
                Monogram(text: "Louis Faust")
                Monogram(text: "Source A", tint: .purple, size: 40)
                Monogram(text: "Canal+", tint: .orange, size: 56)
                ToastView("Source actualisée · 12 453 chaînes", systemImage: "arrow.clockwise")
                GlassPanel {
                    Text("Glass panel").font(.headline)
                }
            }
            ShelfSkeleton(style: .wide, count: 4)
                .padding(.horizontal, -40)
            ShelfSkeleton(style: .posters, count: 8)
                .padding(.horizontal, -40)
            HStack(spacing: 20) {
                ProgressCapsule(fraction: 0.3)
                ProgressCapsule(fraction: 0.7, width: 60, tint: .primary, track: .primary.opacity(0.2))
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PrismColors.pageBackground)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
