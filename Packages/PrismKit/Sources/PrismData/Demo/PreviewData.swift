import Foundation
import PrismCore

/// Deterministic fake data for SwiftUI previews and offscreen snapshot tests.
///
/// Three sources (Xtream "Atlas TV", M3U "Nova IPTV" and the demo), ~40 French channels in six
/// categories, ~60 movies with cross-source/quality duplicates (4K + HD + VOSTFR variants), ~20
/// series with seasons and episodes, and a guide covering `now − 3 h … now + 12 h`.
public enum PreviewData {
    public static let atlasID: SourceID = "preview-atlas"
    public static let novaID: SourceID = "preview-nova"

    /// Fixed reference for `addedAt` values.
    public static let referenceDate = Date(timeIntervalSince1970: 1_793_500_000)

    public static let sources: [Source] = [
        Source(id: atlasID, name: "Atlas TV", kind: .xtream, serverURL: URL(string: "http://atlas-tv.example:8080"),
               username: "demo", tint: .blue, createdAt: referenceDate, lastRefreshedAt: referenceDate),
        Source(id: novaID, name: "Nova IPTV", kind: .m3uURL, serverURL: URL(string: "https://nova-iptv.example/playlist.m3u"),
               tint: .orange, createdAt: referenceDate, lastRefreshedAt: referenceDate),
        DemoContent.makeSource(createdAt: referenceDate),
    ]

    public static let catalogs: [SourceCatalog] = [atlasCatalog, novaCatalog, DemoContent.makeCatalog(fetchedAt: referenceDate)]

    public static func catalog() async -> Catalog {
        await CatalogBuilder.build(sources: sources, catalogs: catalogs)
    }

    /// Programmes for every preview channel, `now − 3 h … now + 12 h` (computed once).
    public static let guide: EPGGuide = makeGuide(now: .now)

    /// A library with a few watchlist entries, favourites and resume points.
    @MainActor
    public static func makeLibrary(for catalog: Catalog) -> LibraryStore {
        let library = LibraryStore.inMemory()
        for title in catalog.movies.prefix(4) { library.addToWatchlist(title.id) }
        for group in catalog.channels.prefix(5) { library.toggleFavorite(group.id) }
        for (offset, title) in catalog.movies.dropFirst(4).prefix(3).enumerated() {
            guard let variant = title.primary else { continue }
            library.updateProgress(PlaybackProgress(
                contentID: variant.id, titleID: title.id, position: Double(900 + offset * 1_200), duration: 6_600,
                updatedAt: Date.now.addingTimeInterval(TimeInterval(-offset * 3_600))
            ))
        }
        if let series = catalog.series.first(where: { $0.variants.first?.series?.seasons?.isEmpty == false }),
           let episode = series.variants.first?.series?.seasons?.first?.episodes.first {
            library.updateProgress(PlaybackProgress(contentID: episode.id, titleID: series.id, position: 1_100, duration: 2_700, updatedAt: .now))
        }
        return library
    }

    // MARK: - Guide

    static func makeGuide(now: Date) -> EPGGuide {
        let calendar = Calendar(identifier: .gregorian)
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        components.minute = (components.minute ?? 0) < 30 ? 0 : 30
        let anchor = calendar.date(from: components) ?? now
        let start = anchor.addingTimeInterval(-3 * 3_600)
        let end = anchor.addingTimeInterval(12 * 3_600)
        var programs: [EPGProgram] = []
        for spec in channelSpecs {
            let pool = programmePool[spec.category] ?? programmePool["generalistes"] ?? []
            guard !pool.isEmpty else { continue }
            var cursor = start
            var index = Int(SafeFileName.stableHash(spec.id) % UInt64(pool.count))
            while cursor < end {
                let item = pool[index % pool.count]
                let next = cursor.addingTimeInterval(TimeInterval(item.minutes * 60))
                programs.append(EPGProgram(
                    channelID: spec.epgID, start: cursor, end: next, title: item.title, subtitle: item.subtitle,
                    summary: item.summary, category: item.category, isNew: index % 5 == 0
                ))
                cursor = next
                index += 1
            }
        }
        let channels = channelSpecs.map { XMLTVChannel(id: $0.epgID, displayNames: [$0.name], iconURL: nil) }
        return EPGGuide(programs: programs, channels: channels)
    }

    // MARK: - Channels

    struct ChannelSpec {
        var id: String
        var name: String
        var number: Int
        var category: String
        var inAtlas: Bool
        var inNova: Bool
        var epgID: String { "\(id).fr" }
    }

    static let liveCategories: [(id: String, name: String)] = [
        ("generalistes", "Généralistes"), ("info", "Info"), ("sport", "Sport"),
        ("cinema", "Cinéma"), ("jeunesse", "Jeunesse"), ("documentaires", "Documentaires"),
    ]

    static let channelSpecs: [ChannelSpec] = [
        .init(id: "tf1", name: "TF1", number: 1, category: "generalistes", inAtlas: true, inNova: true),
        .init(id: "france2", name: "France 2", number: 2, category: "generalistes", inAtlas: true, inNova: true),
        .init(id: "france3", name: "France 3", number: 3, category: "generalistes", inAtlas: true, inNova: true),
        .init(id: "canalplus", name: "Canal+", number: 4, category: "generalistes", inAtlas: true, inNova: false),
        .init(id: "france5", name: "France 5", number: 5, category: "documentaires", inAtlas: true, inNova: true),
        .init(id: "m6", name: "M6", number: 6, category: "generalistes", inAtlas: true, inNova: true),
        .init(id: "arte", name: "Arte", number: 7, category: "generalistes", inAtlas: true, inNova: true),
        .init(id: "c8", name: "C8", number: 8, category: "generalistes", inAtlas: true, inNova: false),
        .init(id: "w9", name: "W9", number: 9, category: "generalistes", inAtlas: true, inNova: true),
        .init(id: "tmc", name: "TMC", number: 10, category: "generalistes", inAtlas: true, inNova: true),
        .init(id: "tfx", name: "TFX", number: 11, category: "generalistes", inAtlas: true, inNova: false),
        .init(id: "nrj12", name: "NRJ 12", number: 12, category: "generalistes", inAtlas: false, inNova: true),
        .init(id: "lcp", name: "LCP", number: 13, category: "info", inAtlas: true, inNova: false),
        .init(id: "france4", name: "France 4", number: 14, category: "jeunesse", inAtlas: true, inNova: true),
        .init(id: "bfmtv", name: "BFM TV", number: 15, category: "info", inAtlas: true, inNova: true),
        .init(id: "cnews", name: "CNews", number: 16, category: "info", inAtlas: true, inNova: false),
        .init(id: "cstar", name: "CStar", number: 17, category: "generalistes", inAtlas: false, inNova: true),
        .init(id: "gulli", name: "Gulli", number: 18, category: "jeunesse", inAtlas: true, inNova: true),
        .init(id: "tf1seriesfilms", name: "TF1 Séries Films", number: 20, category: "cinema", inAtlas: true, inNova: true),
        .init(id: "lequipe", name: "L’Équipe", number: 21, category: "sport", inAtlas: true, inNova: true),
        .init(id: "6ter", name: "6ter", number: 22, category: "generalistes", inAtlas: true, inNova: false),
        .init(id: "rmcstory", name: "RMC Story", number: 23, category: "documentaires", inAtlas: false, inNova: true),
        .init(id: "rmcdecouverte", name: "RMC Découverte", number: 24, category: "documentaires", inAtlas: true, inNova: true),
        .init(id: "cherie25", name: "Chérie 25", number: 25, category: "generalistes", inAtlas: true, inNova: false),
        .init(id: "lci", name: "LCI", number: 26, category: "info", inAtlas: true, inNova: true),
        .init(id: "franceinfo", name: "franceinfo:", number: 27, category: "info", inAtlas: true, inNova: true),
        .init(id: "canalplussport", name: "Canal+ Sport", number: 41, category: "sport", inAtlas: true, inNova: false),
        .init(id: "canalpluscinema", name: "Canal+ Cinéma", number: 42, category: "cinema", inAtlas: true, inNova: false),
        .init(id: "beinsports1", name: "beIN Sports 1", number: 51, category: "sport", inAtlas: true, inNova: true),
        .init(id: "beinsports2", name: "beIN Sports 2", number: 52, category: "sport", inAtlas: false, inNova: true),
        .init(id: "eurosport1", name: "Eurosport 1", number: 53, category: "sport", inAtlas: true, inNova: true),
        .init(id: "eurosport2", name: "Eurosport 2", number: 54, category: "sport", inAtlas: true, inNova: false),
        .init(id: "ocsmax", name: "OCS Max", number: 61, category: "cinema", inAtlas: true, inNova: true),
        .init(id: "cinepluspremier", name: "Ciné+ Premier", number: 62, category: "cinema", inAtlas: false, inNova: true),
        .init(id: "tcmcinema", name: "TCM Cinéma", number: 63, category: "cinema", inAtlas: true, inNova: false),
        .init(id: "disneychannel", name: "Disney Channel", number: 70, category: "jeunesse", inAtlas: true, inNova: true),
        .init(id: "canalj", name: "Canal J", number: 71, category: "jeunesse", inAtlas: false, inNova: true),
        .init(id: "tiji", name: "Tiji", number: 72, category: "jeunesse", inAtlas: true, inNova: false),
        .init(id: "nationalgeographic", name: "National Geographic", number: 80, category: "documentaires", inAtlas: true, inNova: true),
        .init(id: "ushuaiatv", name: "Ushuaïa TV", number: 81, category: "documentaires", inAtlas: true, inNova: false),
        .init(id: "histoiretv", name: "Histoire TV", number: 82, category: "documentaires", inAtlas: false, inNova: true),
        .init(id: "planeteplus", name: "Planète+", number: 83, category: "documentaires", inAtlas: true, inNova: true),
    ]

    // MARK: - Movies

    struct MovieSpec {
        var title: String
        var year: Int
        var genres: [String]
        var category: String
        var rating: Double
        var minutes: Int
        var plot: String
    }

    static let movieCategories: [(id: String, name: String)] = [
        ("action", "Action & aventure"), ("drame", "Drame"), ("comedie", "Comédie"),
        ("thriller", "Thriller"), ("scifi", "Science-fiction"), ("animation", "Animation"), ("docu", "Documentaires"),
    ]

    static let movieSpecs: [MovieSpec] = [
        .init(title: "Les Ombres de Lisbonne", year: 2023, genres: ["Thriller", "Drame"], category: "thriller", rating: 7.4, minutes: 118, plot: "Une interprète découvre qu’un message chiffré glissé dans un roman d’occasion la relie à la disparition d’un diplomate."),
        .init(title: "Horizon perdu", year: 2022, genres: ["Science-fiction", "Aventure"], category: "scifi", rating: 7.9, minutes: 142, plot: "Un équipage échoué sur une lune glacée doit choisir entre attendre les secours et suivre un mystérieux signal."),
        .init(title: "La Dernière Récolte", year: 2021, genres: ["Drame"], category: "drame", rating: 7.1, minutes: 104, plot: "Dans le Bordelais, trois sœurs se retrouvent pour sauver le domaine familial lors d’une vendange décisive."),
        .init(title: "Plan B comme Bretagne", year: 2024, genres: ["Comédie"], category: "comedie", rating: 6.3, minutes: 95, plot: "Un banquier parisien muté à Douarnenez tente de faire fermer la conserverie locale… et tombe sous le charme du port."),
        .init(title: "Nuit blanche à Marseille", year: 2020, genres: ["Action", "Thriller"], category: "action", rating: 6.9, minutes: 108, plot: "Un ex-policier a une nuit pour retrouver la cargaison volée qui pourrait innocenter son frère."),
        .init(title: "Le Jardin des glaces", year: 2019, genres: ["Animation", "Familial"], category: "animation", rating: 7.6, minutes: 88, plot: "Une petite renarde polaire part à la recherche de l’aurore boréale qui a cessé de briller."),
        .init(title: "Océans profonds", year: 2023, genres: ["Documentaire"], category: "docu", rating: 8.2, minutes: 92, plot: "Une plongée inédite dans les abysses, à la rencontre d’espèces jamais filmées."),
        .init(title: "L’Affaire Vermont", year: 2018, genres: ["Policier", "Drame"], category: "thriller", rating: 7.2, minutes: 121, plot: "Une juge d’instruction rouvre un dossier classé et met au jour un réseau de corruption au cœur de la préfecture."),
        .init(title: "Station Orbitale 9", year: 2025, genres: ["Science-fiction", "Thriller"], category: "scifi", rating: 6.8, minutes: 115, plot: "Quand l’IA de la station refuse d’ouvrir les sas, l’ingénieure de maintenance devient le dernier rempart de l’équipage."),
        .init(title: "Mon voisin le chef", year: 2022, genres: ["Comédie", "Romance"], category: "comedie", rating: 6.5, minutes: 99, plot: "Une critique gastronomique redoutée emménage à côté du chef qu’elle vient d’éreinter."),
        .init(title: "Les Gardiens du phare", year: 2017, genres: ["Aventure", "Familial"], category: "action", rating: 7.0, minutes: 101, plot: "Deux enfants découvrent que le vieux phare de l’île cache une carte menant au trésor d’un corsaire."),
        .init(title: "Ligne de front", year: 2021, genres: ["Guerre", "Drame"], category: "drame", rating: 7.8, minutes: 136, plot: "Hiver 1916 : un jeune télégraphiste doit traverser les lignes pour transmettre un ordre de repli."),
        .init(title: "Pixel & Plume", year: 2023, genres: ["Animation", "Comédie"], category: "animation", rating: 7.3, minutes: 90, plot: "Un robot aspirateur et un pigeon parisien font équipe pour retrouver le chat de la maison."),
        .init(title: "Le Grand Saut", year: 2016, genres: ["Drame", "Sport"], category: "drame", rating: 6.7, minutes: 112, plot: "Une ancienne championne de saut à ski entraîne une adolescente rebelle pour les Jeux d’hiver."),
        .init(title: "Fréquence fantôme", year: 2024, genres: ["Horreur", "Thriller"], category: "thriller", rating: 6.1, minutes: 97, plot: "Une animatrice de radio nocturne reçoit des appels d’auditeurs qui décrivent des crimes… avant qu’ils ne surviennent."),
        .init(title: "Les Routes de la soie", year: 2020, genres: ["Documentaire", "Histoire"], category: "docu", rating: 7.9, minutes: 104, plot: "De Xi’an à Venise, sur les traces des caravanes qui ont relié l’Orient et l’Occident."),
        .init(title: "Course contre la nuit", year: 2019, genres: ["Action"], category: "action", rating: 6.4, minutes: 103, plot: "Une coursière à vélo se retrouve en possession d’une clé USB convoitée par toute la pègre lyonnaise."),
        .init(title: "Amour, café et malentendus", year: 2021, genres: ["Comédie", "Romance"], category: "comedie", rating: 6.2, minutes: 94, plot: "Un barista dyslexique et une linguiste pointilleuse s’écrivent des mots doux… à travers les commandes de café."),
        .init(title: "Exode", year: 2022, genres: ["Science-fiction", "Drame"], category: "scifi", rating: 7.5, minutes: 128, plot: "Sur une Terre devenue hostile, une famille embarque à bord du dernier vaisseau-arche."),
        .init(title: "Le Silence des loups", year: 2018, genres: ["Thriller"], category: "thriller", rating: 7.0, minutes: 110, plot: "Dans un village du Vercors, la disparition d’un garde forestier réveille une vieille rivalité."),
        .init(title: "Petits Héros", year: 2024, genres: ["Animation", "Aventure", "Familial"], category: "animation", rating: 7.1, minutes: 86, plot: "Des jouets oubliés au grenier montent une expédition pour retrouver leur propriétaire."),
        .init(title: "Sous le ciel de Kyoto", year: 2023, genres: ["Romance", "Drame"], category: "drame", rating: 7.3, minutes: 109, plot: "Une architecte française et un artisan japonais restaurent ensemble une maison de thé centenaire."),
        .init(title: "Opération Mistral", year: 2025, genres: ["Action", "Espionnage"], category: "action", rating: 6.6, minutes: 124, plot: "Une agente de la DGSE doit exfiltrer un scientifique pendant le festival de Cannes."),
        .init(title: "Les Génies du vivant", year: 2021, genres: ["Documentaire", "Nature"], category: "docu", rating: 8.0, minutes: 90, plot: "Comment les plantes communiquent, se défendent et s’entraident : la science révèle un monde insoupçonné."),
        .init(title: "La Fête de trop", year: 2017, genres: ["Comédie"], category: "comedie", rating: 5.9, minutes: 92, plot: "Pour ses quarante ans, Julien organise une soirée surprise… pour lui-même. Rien ne se passe comme prévu."),
        .init(title: "Résonance", year: 2020, genres: ["Science-fiction", "Mystère"], category: "scifi", rating: 7.2, minutes: 117, plot: "Une physicienne capte un écho de sa propre voix venu de vingt ans dans le futur."),
        .init(title: "Le Prix du silence", year: 2019, genres: ["Drame", "Thriller"], category: "thriller", rating: 7.1, minutes: 113, plot: "Un lanceur d’alerte de l’industrie pharmaceutique doit choisir entre sa famille et la vérité."),
        .init(title: "Cap au Sud", year: 2022, genres: ["Aventure", "Drame"], category: "action", rating: 6.9, minutes: 106, plot: "Un père et sa fille traversent l’Atlantique à la voile après un deuil."),
        .init(title: "Bulle d’orage", year: 2024, genres: ["Animation", "Fantastique"], category: "animation", rating: 7.4, minutes: 89, plot: "Une apprentie météorologue capable de parler aux nuages doit empêcher une tempête éternelle."),
        .init(title: "Les Années vinyle", year: 2018, genres: ["Drame", "Musique"], category: "drame", rating: 7.0, minutes: 115, plot: "Paris, 1979 : un disquaire de Barbès devient le refuge d’une génération de musiciens."),
        .init(title: "Mission Antarctique", year: 2023, genres: ["Documentaire", "Aventure"], category: "docu", rating: 7.7, minutes: 95, plot: "Six mois avec les scientifiques de la base Concordia, isolés au cœur de la nuit polaire."),
        .init(title: "Double Jeu", year: 2016, genres: ["Thriller", "Policier"], category: "thriller", rating: 6.8, minutes: 107, plot: "Un flic infiltré découvre que son contact au sein du gang est un autre policier infiltré."),
        .init(title: "Tempête sur Avignon", year: 2021, genres: ["Comédie", "Drame"], category: "comedie", rating: 6.6, minutes: 98, plot: "Une troupe de théâtre amateur se retrouve, par erreur, programmée dans le In du festival."),
        .init(title: "Gravité zéro", year: 2019, genres: ["Science-fiction", "Action"], category: "scifi", rating: 6.5, minutes: 111, plot: "Lors d’une mission de ravitaillement, deux astronautes rivaux doivent coopérer pour survivre."),
        .init(title: "Le Chant des baleines", year: 2022, genres: ["Documentaire", "Nature"], category: "docu", rating: 8.1, minutes: 88, plot: "Des Açores au Groenland, des chercheurs tentent de déchiffrer le langage des baleines à bosse."),
        .init(title: "Frères d’armes", year: 2020, genres: ["Action", "Guerre"], category: "action", rating: 7.0, minutes: 131, plot: "Deux légionnaires que tout oppose sont envoyés en mission de sauvetage au Sahel."),
        .init(title: "La Petite Boulangerie", year: 2023, genres: ["Comédie", "Familial"], category: "comedie", rating: 6.8, minutes: 93, plot: "Une adolescente reprend la boulangerie de sa grand-mère et se lance dans un concours national."),
        .init(title: "Les Murmures de la forêt", year: 2024, genres: ["Animation", "Fantastique"], category: "animation", rating: 7.8, minutes: 94, plot: "Un garçon découvre que les arbres de sa forêt natale abritent un peuple minuscule menacé par les bulldozers."),
        .init(title: "Mémoires d’un faussaire", year: 2018, genres: ["Drame", "Biographie"], category: "drame", rating: 7.4, minutes: 119, plot: "Le destin romanesque d’un peintre raté devenu le plus grand faussaire du XXᵉ siècle."),
        .init(title: "Altitude", year: 2025, genres: ["Thriller", "Aventure"], category: "thriller", rating: 6.7, minutes: 102, plot: "Bloqués dans un téléphérique en pleine tempête, six inconnus découvrent que l’un d’eux n’est pas là par hasard."),
        .init(title: "Le Cercle des Poètes Libres", year: 2016, genres: ["Drame"], category: "drame", rating: 7.6, minutes: 116, plot: "Un professeur de lettres insuffle à une classe de terminale le goût de la rébellion poétique."),
        .init(title: "Taxi pour Tanger", year: 2022, genres: ["Comédie", "Aventure"], category: "comedie", rating: 6.4, minutes: 97, plot: "Un chauffeur de taxi niçois accepte une course improbable jusqu’au Maroc."),
        .init(title: "Zone Rouge", year: 2024, genres: ["Action", "Science-fiction"], category: "action", rating: 6.3, minutes: 109, plot: "Une unité d’élite pénètre dans une zone de quarantaine où le temps s’écoule différemment."),
        .init(title: "Les Ailes du désert", year: 2019, genres: ["Documentaire", "Nature"], category: "docu", rating: 7.8, minutes: 86, plot: "La migration spectaculaire des cigognes entre l’Alsace et le Sahel."),
        .init(title: "Mademoiselle Détective", year: 2021, genres: ["Policier", "Comédie"], category: "thriller", rating: 6.9, minutes: 101, plot: "Une concierge parisienne mène l’enquête après un vol de bijoux dans son immeuble."),
        .init(title: "Le Royaume des Neiges", year: 2018, genres: ["Animation", "Aventure"], category: "animation", rating: 7.2, minutes: 92, plot: "Un ourson polaire et un manchot égaré traversent la banquise pour rentrer chez eux."),
        .init(title: "Dernier Train pour Varsovie", year: 2023, genres: ["Drame", "Histoire"], category: "drame", rating: 7.7, minutes: 127, plot: "1939 : une pianiste tente de faire fuir sa famille à bord du dernier train avant l’invasion."),
        .init(title: "Signal", year: 2020, genres: ["Science-fiction", "Thriller"], category: "scifi", rating: 6.9, minutes: 104, plot: "Un radioastronome amateur capte une transmission qui semble provenir de son propre jardin."),
        .init(title: "Coup de foudre à Biarritz", year: 2024, genres: ["Romance", "Comédie"], category: "comedie", rating: 6.0, minutes: 91, plot: "Une surfeuse professionnelle et un notaire guindé se disputent la même maison de vacances."),
        .init(title: "Les Bâtisseurs de cathédrales", year: 2022, genres: ["Documentaire", "Histoire"], category: "docu", rating: 8.0, minutes: 98, plot: "Comment les compagnons du Moyen Âge ont élevé Chartres, Reims et Notre-Dame."),
        .init(title: "Poursuite", year: 2017, genres: ["Action", "Thriller"], category: "action", rating: 6.5, minutes: 99, plot: "Un pilote de rallye est contraint de conduire un braqueur à travers les Alpes."),
        .init(title: "La Voix d’Élise", year: 2025, genres: ["Drame", "Musique"], category: "drame", rating: 7.3, minutes: 112, plot: "Une chanteuse lyrique qui perd la voix trouve une nouvelle façon de faire de la musique."),
    ]

    // MARK: - Series

    struct SeriesSpec {
        var title: String
        var year: Int
        var genres: [String]
        var rating: Double
        var seasons: [Int]
        var plot: String
    }

    static let seriesSpecs: [SeriesSpec] = [
        .init(title: "Brigade du Port", year: 2021, genres: ["Policier", "Drame"], rating: 7.6, seasons: [8, 8, 6], plot: "Au Havre, une brigade des douanes traque les trafics qui transitent par l’un des plus grands ports d’Europe."),
        .init(title: "Les Héritiers", year: 2019, genres: ["Drame"], rating: 7.9, seasons: [10, 10, 10, 8], plot: "À la mort du patriarche, une dynastie de champagne se déchire pour le contrôle de la maison."),
        .init(title: "Nébuleuse", year: 2023, genres: ["Science-fiction"], rating: 8.1, seasons: [8, 8], plot: "Le premier équipage habité vers Proxima du Centaure se réveille plus tôt que prévu."),
        .init(title: "Coloc’ en Folie", year: 2020, genres: ["Comédie"], rating: 6.9, seasons: [12, 12, 12], plot: "Cinq trentenaires partagent un appartement trop petit à Montreuil."),
        .init(title: "Le Village des Ombres", year: 2022, genres: ["Mystère", "Fantastique"], rating: 7.7, seasons: [6, 6], plot: "Dans un hameau des Cévennes, les habitants disparaissent un à un, chaque nuit de pleine lune."),
        .init(title: "Urgences Lyon", year: 2018, genres: ["Médical", "Drame"], rating: 7.2, seasons: [10, 10, 10, 10, 10], plot: "Le quotidien intense des soignants du service des urgences de l’hôpital Édouard-Herriot."),
        .init(title: "Cuisine en Duo", year: 2024, genres: ["Téléréalité"], rating: 6.4, seasons: [10], plot: "Des binômes amateurs s’affrontent sous l’œil de chefs étoilés."),
        .init(title: "Les Enquêtes de Margaux", year: 2017, genres: ["Policier", "Comédie"], rating: 7.0, seasons: [6, 6, 6, 6], plot: "Une libraire de Saint-Malo résout les crimes que la police locale n’arrive pas à élucider."),
        .init(title: "Frontière", year: 2021, genres: ["Thriller", "Espionnage"], rating: 7.8, seasons: [8, 8], plot: "Entre Strasbourg et Kehl, une agente franco-allemande démantèle un réseau d’espionnage industriel."),
        .init(title: "Les Petits Inventeurs", year: 2020, genres: ["Animation", "Jeunesse"], rating: 7.1, seasons: [26, 26], plot: "Trois enfants transforment leur garage en laboratoire pour résoudre les problèmes de leur quartier."),
        .init(title: "Royaume de Sable", year: 2022, genres: ["Historique", "Aventure"], rating: 7.5, seasons: [10, 10], plot: "Au XIIᵉ siècle, une marchande devient la conseillère d’un sultan en pleine guerre de succession."),
        .init(title: "Startup Nation", year: 2023, genres: ["Comédie"], rating: 6.8, seasons: [8], plot: "Quatre amis lancent une application de covoiturage pour chèvres. Et ça marche."),
        .init(title: "Abysses", year: 2024, genres: ["Science-fiction", "Thriller"], rating: 7.4, seasons: [6], plot: "Une base sous-marine de forage perd le contact avec la surface."),
        .init(title: "Planète Sauvage", year: 2019, genres: ["Documentaire"], rating: 8.4, seasons: [6, 6], plot: "Les comportements animaliers les plus extraordinaires, filmés aux quatre coins du globe."),
        .init(title: "Lycée Voltaire", year: 2021, genres: ["Drame", "Jeunesse"], rating: 6.7, seasons: [10, 10, 10], plot: "Amitiés, rivalités et premiers amours dans un lycée de la banlieue toulousaine."),
        .init(title: "Le Bureau des Légendes Perdues", year: 2018, genres: ["Fantastique", "Aventure"], rating: 7.3, seasons: [8, 8, 8], plot: "Une archiviste du Louvre enquête sur les objets maudits que le musée garde secrets."),
        .init(title: "Pole Position", year: 2022, genres: ["Sport", "Documentaire"], rating: 7.9, seasons: [10, 10], plot: "Les coulisses d’une écurie française de Formule 1, saison après saison."),
        .init(title: "Mes Années 80", year: 2020, genres: ["Comédie", "Nostalgie"], rating: 7.0, seasons: [13, 13], plot: "La vie d’une famille de Roubaix au rythme des tubes, des walkmans et des émissions du samedi soir."),
        .init(title: "Code Noir", year: 2023, genres: ["Thriller", "Technologie"], rating: 7.6, seasons: [8], plot: "Une hackeuse repentie est recrutée par l’ANSSI pour stopper une cyberattaque d’ampleur nationale."),
        .init(title: "Les Gardiennes du Phare", year: 2024, genres: ["Drame", "Historique"], rating: 7.2, seasons: [6], plot: "En 1950, trois femmes prennent la relève des gardiens d’un phare breton isolé."),
    ]

    // MARK: - Catalog assembly

    private static func url(_ string: String) -> URL? { URL(string: string) }

    static var atlasCatalog: SourceCatalog { makeSourceCatalog(atlasID, isAtlas: true) }
    static var novaCatalog: SourceCatalog { makeSourceCatalog(novaID, isAtlas: false) }

    private static func makeSourceCatalog(_ source: SourceID, isAtlas: Bool) -> SourceCatalog {
        var categories: [PrismCore.Category] = []
        for (index, category) in liveCategories.enumerated() {
            let raw = isAtlas ? "FR | \(category.name.uppercased())" : category.name
            categories.append(PrismCore.Category(sourceID: source, kind: .live, nativeID: "l-\(category.id)", name: category.name, rawName: raw, sortIndex: index))
        }
        for (index, category) in movieCategories.enumerated() {
            categories.append(PrismCore.Category(sourceID: source, kind: .movie, nativeID: "m-\(category.id)", name: category.name, sortIndex: index))
        }
        categories.append(PrismCore.Category(sourceID: source, kind: .series, nativeID: "s-all", name: "Séries", sortIndex: 0))
        categories.append(PrismCore.Category(sourceID: source, kind: .series, nativeID: "s-kids", name: "Séries jeunesse", sortIndex: 1))

        let host = isAtlas ? "http://atlas-tv.example:8080" : "https://nova-iptv.example"
        var channels: [Channel] = []
        for spec in channelSpecs where isAtlas ? spec.inAtlas : spec.inNova {
            let quality: VideoQuality = isAtlas ? (spec.number % 3 == 0 ? .fhd : .hd) : (spec.number % 4 == 0 ? .uhd : .fhd)
            let raw = isAtlas ? "FR: \(spec.name) \(quality.badge ?? "")" : "|FR| \(spec.name.uppercased()) \(quality.badge ?? "")"
            guard let stream = URL(string: "\(host)/live/demo/demo/\(spec.id).m3u8") else { continue }
            channels.append(Channel(
                sourceID: source, nativeID: spec.id, name: spec.name, rawName: raw, number: isAtlas ? spec.number : spec.number + 100,
                logoURL: nil, categoryID: "\(source.rawValue):live:l-\(spec.category)", epgID: spec.epgID, streamURL: stream,
                quality: quality, tags: ["FR"],
                catchup: isAtlas && spec.category == "generalistes" ? Catchup(mode: .xtream, days: 7) : nil
            ))
        }

        var movies: [Movie] = []
        for (index, spec) in movieSpecs.enumerated() {
            let includeInAtlas = index % 4 != 3
            let includeInNova = index % 3 == 0 || index % 4 == 3
            guard isAtlas ? includeInAtlas : includeInNova else { continue }
            let added = referenceDate.addingTimeInterval(TimeInterval(-(index * 2 + (isAtlas ? 0 : 1)) * 86_400))
            var variants: [(id: String, quality: VideoQuality, tags: [String], suffix: String)] = []
            if isAtlas {
                variants.append(("m\(index)", index % 5 == 0 ? .uhd : .hd, index % 5 == 0 ? ["HDR"] : [], ""))
                if index % 5 == 0 { variants.append(("m\(index)-hd", .hd, [], "")) }
                if index % 7 == 0 { variants.append(("m\(index)-vo", .fhd, ["VOSTFR"], " VOSTFR")) }
            } else {
                variants.append(("n\(index)", .fhd, ["MULTI"], " MULTI"))
            }
            for variant in variants {
                guard let stream = URL(string: "\(host)/movie/demo/demo/\(variant.id).mkv") else { continue }
                let badge = variant.quality.badge.map { " \($0)" } ?? ""
                movies.append(Movie(
                    sourceID: source, nativeID: variant.id, title: spec.title,
                    rawName: isAtlas ? "FR - \(spec.title) (\(spec.year))\(badge)\(variant.suffix)" : "\(spec.title.uppercased()) \(spec.year)\(badge)\(variant.suffix)",
                    year: spec.year, posterURL: nil, backdropURL: nil,
                    plot: isAtlas ? spec.plot : nil, genres: spec.genres, rating: spec.rating,
                    durationSeconds: spec.minutes * 60, cast: ["Léa Martin", "Hugo Bernard", "Camille Petit"].map { $0 },
                    director: "Claire Dubois", categoryID: "\(source.rawValue):movie:m-\(spec.category)", streamURL: stream,
                    containerExtension: "mkv", quality: variant.quality, tags: variant.tags, addedAt: added
                ))
            }
        }

        var series: [Series] = []
        for (index, spec) in seriesSpecs.enumerated() {
            guard isAtlas ? index % 5 != 4 : index % 2 == 0 else { continue }
            let nativeID = isAtlas ? "s\(index)" : "ns\(index)"
            let seriesID = ContentID(source: source, kind: .series, nativeID: nativeID)
            let seasons: [Season] = spec.seasons.enumerated().map { seasonOffset, count in
                let seasonNumber = seasonOffset + 1
                let episodes: [Episode] = (1...count).compactMap { number in
                    guard let stream = URL(string: "\(host)/series/demo/demo/\(nativeID)-\(seasonNumber)-\(number).mkv") else { return nil }
                    return Episode(
                        seriesID: seriesID, sourceID: source, nativeID: "\(nativeID)e\(seasonNumber)x\(number)",
                        season: seasonNumber, number: number, title: episodeTitle(series: index, season: seasonNumber, number: number),
                        plot: "Saison \(seasonNumber), épisode \(number) de « \(spec.title) ».",
                        durationSeconds: (spec.genres.contains("Animation") ? 22 : 48) * 60, streamURL: stream,
                        containerExtension: "mkv",
                        airDate: Calendar(identifier: .gregorian).date(from: DateComponents(year: spec.year + seasonOffset, month: 9, day: min(number * 2, 28)))
                    )
                }
                return Season(number: seasonNumber, name: "Saison \(seasonNumber)", episodes: episodes)
            }
            series.append(Series(
                sourceID: source, nativeID: nativeID, title: spec.title,
                rawName: isAtlas ? "FR - \(spec.title) (\(spec.year))" : "\(spec.title) [MULTI]",
                year: spec.year, plot: spec.plot, genres: spec.genres, rating: spec.rating,
                cast: ["Inès Moreau", "Thomas Laurent"], director: "Antoine Girard",
                categoryID: "\(source.rawValue):series:\(spec.genres.contains("Jeunesse") ? "s-kids" : "s-all")",
                quality: isAtlas ? .hd : .fhd,
                addedAt: referenceDate.addingTimeInterval(TimeInterval(-(index * 3 + (isAtlas ? 0 : 1)) * 86_400)),
                seasons: seasons
            ))
        }

        let account = isAtlas ? XtreamAccount(
            username: "demo", status: "Active", isActive: true, isTrial: false,
            expiresAt: referenceDate.addingTimeInterval(180 * 86_400), createdAt: referenceDate.addingTimeInterval(-365 * 86_400),
            maxConnections: 2, activeConnections: 0, allowedOutputFormats: ["m3u8", "ts"], serverTimeZone: "Europe/Paris",
            serverURL: url("http://atlas-tv.example:8080")
        ) : nil

        return SourceCatalog(sourceID: source, categories: categories, channels: channels, movies: movies, series: series, account: account, fetchedAt: referenceDate)
    }

    private static let episodeWords = ["Le Départ", "Révélations", "Point de non-retour", "L’Inconnu", "Sous pression", "Le Pacte",
                                       "Faux-semblants", "La Traque", "Retour aux sources", "Le Choix", "Tempête", "Final"]

    private static func episodeTitle(series: Int, season: Int, number: Int) -> String {
        episodeWords[(series * 7 + season * 3 + number) % episodeWords.count]
    }

    // MARK: - Programme pools

    struct ProgrammeSpec {
        var title: String
        var subtitle: String?
        var summary: String
        var category: String
        var minutes: Int
    }

    static let programmePool: [String: [ProgrammeSpec]] = [
        "generalistes": [
            .init(title: "Le 13h", summary: "Le journal de la mi-journée : actualité nationale et internationale.", category: "Information", minutes: 45),
            .init(title: "Questions pour un champion", summary: "Quatre candidats s’affrontent dans le jeu de culture générale.", category: "Jeu", minutes: 45),
            .init(title: "Meurtres à Collioure", subtitle: "Téléfilm", summary: "Une commissaire enquête sur la mort d’un peintre retrouvé sur la plage.", category: "Téléfilm", minutes: 90),
            .init(title: "Le 20h", summary: "Le grand journal du soir.", category: "Information", minutes: 40),
            .init(title: "Brigade du Port", subtitle: "Saison 2, épisode 4", summary: "Une cargaison suspecte mène l’équipe sur la piste d’un ancien collègue.", category: "Série", minutes: 55),
            .init(title: "Les Ombres de Lisbonne", subtitle: "Film", summary: "Une interprète découvre un message chiffré dans un roman d’occasion.", category: "Film", minutes: 120),
            .init(title: "Météo", summary: "Les prévisions pour les prochains jours.", category: "Météo", minutes: 15),
        ],
        "info": [
            .init(title: "Le journal", summary: "Toute l’actualité en continu.", category: "Information", minutes: 30),
            .init(title: "L’édition du soir", summary: "Les faits marquants de la journée, analysés par nos experts.", category: "Information", minutes: 60),
            .init(title: "Le grand débat", summary: "Responsables politiques et éditorialistes débattent.", category: "Débat", minutes: 60),
            .init(title: "Les informés", summary: "Quatre journalistes décryptent l’actualité.", category: "Magazine", minutes: 45),
            .init(title: "Bourse & Business", summary: "Marchés, entreprises et économie.", category: "Économie", minutes: 30),
        ],
        "sport": [
            .init(title: "Ligue des champions : avant-match", summary: "Analyses et compositions d’équipe avant le coup d’envoi.", category: "Football", minutes: 45),
            .init(title: "Football : Ligue des champions", subtitle: "En direct", summary: "Phase de groupes, 5ᵉ journée.", category: "Football", minutes: 120),
            .init(title: "Tennis : Masters", summary: "Quart de finale du tournoi des Masters.", category: "Tennis", minutes: 150),
            .init(title: "Rugby : Top 14", summary: "Toulouse reçoit La Rochelle pour le choc de la journée.", category: "Rugby", minutes: 105),
            .init(title: "Le magazine du sport", summary: "Résultats, reportages et invités.", category: "Magazine", minutes: 60),
        ],
        "cinema": [
            .init(title: "Horizon perdu", subtitle: "Film", summary: "Un équipage échoué sur une lune glacée suit un mystérieux signal.", category: "Film", minutes: 145),
            .init(title: "La Dernière Récolte", subtitle: "Film", summary: "Trois sœurs se retrouvent pour sauver le domaine familial.", category: "Film", minutes: 105),
            .init(title: "Station Orbitale 9", subtitle: "Film", summary: "L’IA de la station refuse d’ouvrir les sas.", category: "Film", minutes: 115),
            .init(title: "Le making-of", summary: "Dans les coulisses des tournages du moment.", category: "Magazine", minutes: 30),
        ],
        "jeunesse": [
            .init(title: "Les Petits Inventeurs", subtitle: "Épisode 12", summary: "Le robot de Léo s’échappe du garage.", category: "Dessin animé", minutes: 25),
            .init(title: "Pirates en herbe", summary: "Une bande d’enfants pirates à la recherche du trésor perdu.", category: "Dessin animé", minutes: 25),
            .init(title: "Pixel & Plume", subtitle: "Film d’animation", summary: "Un robot aspirateur et un pigeon parisien font équipe.", category: "Film", minutes: 90),
            .init(title: "Les Aventuriers de l’espace", summary: "Mission sur Mars pour nos jeunes astronautes.", category: "Dessin animé", minutes: 30),
        ],
        "documentaires": [
            .init(title: "Océans profonds", summary: "Une plongée inédite dans les abysses.", category: "Documentaire", minutes: 90),
            .init(title: "Les secrets des pyramides", summary: "Nouvelles découvertes sur le plateau de Gizeh.", category: "Histoire", minutes: 55),
            .init(title: "Planète Sauvage", subtitle: "Les prédateurs", summary: "Chasseurs de la savane africaine.", category: "Nature", minutes: 50),
            .init(title: "Mission Antarctique", summary: "Six mois avec les scientifiques de la base Concordia.", category: "Documentaire", minutes: 95),
            .init(title: "Grands travaux", summary: "Les chantiers les plus fous de la planète.", category: "Société", minutes: 45),
        ],
    ]
}
