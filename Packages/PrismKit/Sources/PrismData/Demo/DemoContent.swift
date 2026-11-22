import Foundation
import PrismCore

/// Built-in demo source ("Essayer la démo"): free, legal, public streams and Blender open movies.
///
/// Channels are public broadcasters' official HLS feeds and Apple's HLS sample streams.
/// The films and series are Blender Foundation open movies, hosted by Blender, Internet Archive
/// or Mux, with artwork from Blender Studio's public press materials and Wikimedia Commons.
public enum DemoContent {
    public static let sourceID: SourceID = "prism-demo"
    /// Placeholder playlist URL recognised by `CatalogRepository` (no network access needed).
    public static let playlistURL = URL(string: "prism-demo://catalog")!
    public static let scheme = "prism-demo"

    public static func isDemo(_ source: Source) -> Bool {
        source.id == sourceID || source.serverURL?.scheme == scheme
    }

    public static func makeSources() -> [Source] {
        [makeSource()]
    }

    public static func makeSource(createdAt: Date = referenceDate) -> Source {
        Source(
            id: sourceID, name: "Démo Prism", kind: .m3uURL, serverURL: playlistURL,
            preferHLSForLive: true, tint: .purple, isEnabled: true, createdAt: createdAt
        )
    }

    public static func makeCatalogs() -> [SourceCatalog] {
        [makeCatalog()]
    }

    /// Fixed date used for `addedAt` values (keeps the demo deterministic).
    public static let referenceDate = Date(timeIntervalSince1970: 1_793_000_000) // 2026-10-26

    public static func makeCatalog(fetchedAt: Date = .now) -> SourceCatalog {
        SourceCatalog(
            sourceID: sourceID, categories: categories, channels: channels, movies: movies, series: series,
            account: nil, fetchedAt: fetchedAt
        )
    }

    /// Generic programme blocks for the demo channels so that the guide is not empty
    /// (`now − 6 h … now + 24 h`, aligned on the hour). No claim about real schedules.
    public static func makeGuide(now: Date = .now) -> EPGGuide {
        let calendar = Calendar(identifier: .gregorian)
        let hour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        var programs: [EPGProgram] = []
        for channel in channels {
            guard let epgID = channel.epgID else { continue }
            let blocks = channel.categoryID.flatMap { guideBlocks[$0] } ?? guideBlocks[categoryID(.live, "info")] ?? []
            guard !blocks.isEmpty else { continue }
            var start = hour.addingTimeInterval(-6 * 3_600)
            var index = Int(SafeFileName.stableHash(channel.nativeID) % UInt64(blocks.count))
            while start < hour.addingTimeInterval(24 * 3_600) {
                let block = blocks[index % blocks.count]
                let end = start.addingTimeInterval(TimeInterval(block.minutes * 60))
                programs.append(EPGProgram(
                    channelID: epgID, start: start, end: end, title: block.title,
                    summary: block.summary, category: block.category
                ))
                start = end
                index += 1
            }
        }
        return EPGGuide(programs: programs)
    }

    // MARK: - Categories

    private static func category(_ kind: MediaKind, _ id: String, _ name: String, _ sort: Int) -> PrismCore.Category {
        PrismCore.Category(sourceID: sourceID, kind: kind, nativeID: id, name: name, sortIndex: sort)
    }

    private static let categories: [PrismCore.Category] = [
        category(.live, "info", "Information", 0),
        category(.live, "sport", "Sport & aventure", 1),
        category(.live, "demo", "Démos techniques", 2),
        category(.movie, "anim", "Films d’animation", 0),
        category(.movie, "scifi", "Science-fiction", 1),
        category(.movie, "comedy", "Comédies", 2),
        category(.series, "anim-series", "Séries d’animation", 0),
    ]

    private static func categoryID(_ kind: MediaKind, _ native: String) -> String {
        "\(sourceID.rawValue):\(kind.rawValue):\(native)"
    }

    // MARK: - Channels

    private static func url(_ string: String) -> URL? { URL(string: string) }

    private static func channel(
        _ id: String, _ name: String, number: Int, category: String, quality: VideoQuality,
        stream: String, logo: String?, epg: String
    ) -> Channel? {
        guard let streamURL = URL(string: stream) else { return nil }
        let badge = quality.badge.map { " \($0)" } ?? ""
        return Channel(
            sourceID: sourceID, nativeID: id, name: name, rawName: "FR: \(name)\(badge)", number: number,
            logoURL: logo.flatMap(url), categoryID: categoryID(.live, category), epgID: epg,
            streamURL: streamURL, quality: quality
        )
    }

    private static let commons = "https://upload.wikimedia.org/wikipedia/commons/"
    private static let studioArt = "https://studio.blender.org/files/public/"

    private static let channels: [Channel] = [
        channel("france24", "France 24", number: 1, category: "info", quality: .fhd,
                stream: "https://live.france24.com/hls/live/2037179/F24_FR_HI_HLS/master_5000.m3u8",
                logo: commons + "thumb/c/c1/France_24_logo_%282013%29.svg/500px-France_24_logo_%282013%29.svg.png",
                epg: "France24.fr@French"),
        channel("france24-en", "France 24 English", number: 2, category: "info", quality: .fhd,
                stream: "https://live.france24.com/hls/live/2037218/F24_EN_HI_HLS/master_5000.m3u8",
                logo: commons + "thumb/c/c1/France_24_logo_%282013%29.svg/500px-France_24_logo_%282013%29.svg.png",
                epg: "France24.fr@English"),
        channel("euronews", "Euronews", number: 3, category: "info", quality: .hd,
                stream: "https://cdn-euronews.akamaized.net/live/eds/euronews-fr/25026/index.m3u8",
                logo: commons + "thumb/9/9c/Euronews_2022.svg/500px-Euronews_2022.svg.png",
                epg: "EuronewsFrench.fr"),
        channel("africanews", "Africanews", number: 4, category: "info", quality: .hd,
                stream: "https://cdn-euronews.akamaized.net/live/eds/africanews-fr/25050/index.m3u8",
                logo: commons + "thumb/1/19/Africanews_logo.svg/500px-Africanews_logo.svg.png",
                epg: "AfricanewsFrench.fr"),
        channel("tv5monde-info", "TV5Monde Info", number: 5, category: "info", quality: .fhd,
                stream: "https://ott.tv5monde.com/Content/HLS/Live/channel(info)/index.m3u8",
                logo: commons + "thumb/5/51/Logo_TV5_Monde_-_2021.svg/500px-Logo_TV5_Monde_-_2021.svg.png",
                epg: "TV5MondeInfo.fr"),
        channel("dw", "DW English", number: 6, category: "info", quality: .fhd,
                stream: "https://dwamdstream102.akamaized.net/hls/live/2015525/dwstream102/index.m3u8",
                logo: commons + "thumb/7/75/Deutsche_Welle_symbol_2012.svg/500px-Deutsche_Welle_symbol_2012.svg.png",
                epg: "DWEnglish.de"),
        channel("aljazeera", "Al Jazeera English", number: 7, category: "info", quality: .fhd,
                stream: "https://live-hls-apps-aje-fa.getaj.net/AJE/index.m3u8",
                logo: commons + "0/03/Al_Jazeera_Media_Network_Logo_design.png",
                epg: "AlJazeeraEnglish.qa"),
        channel("bloomberg", "Bloomberg TV Europe", number: 8, category: "info", quality: .hd,
                stream: "https://www.bloomberg.com/media-manifest/streams/eu.m3u8",
                logo: commons + "thumb/6/66/Bloomberg_Television_logo.svg/500px-Bloomberg_Television_logo.svg.png",
                epg: "BloombergTVEurope.uk"),
        channel("redbull", "Red Bull TV", number: 9, category: "sport", quality: .fhd,
                stream: "https://rbmn-live.akamaized.net/hls/live/590964/BoRB-AT/master.m3u8",
                logo: nil, epg: "RedBullTV.at"),
        channel("apple-bipbop", "Apple BipBop (démo HLS)", number: 90, category: "demo", quality: .fhd,
                stream: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8",
                logo: commons + "thumb/f/fa/Apple_logo_black.svg/500px-Apple_logo_black.svg.png",
                epg: "prism.demo.bipbop"),
        channel("apple-dolby", "Apple Dolby Vision & Atmos (démo)", number: 91, category: "demo", quality: .uhd,
                stream: "https://devstreaming-cdn.apple.com/videos/streaming/examples/adv_dv_atmos/main.m3u8",
                logo: commons + "thumb/f/fa/Apple_logo_black.svg/500px-Apple_logo_black.svg.png",
                epg: "prism.demo.dolby"),
    ].compactMap { $0 }

    // MARK: - Movies

    private static func movie(
        _ id: String, _ title: String, year: Int, quality: VideoQuality, stream: String, container: String,
        category: String, poster: String?, backdrop: String?, plot: String, genres: [String], rating: Double,
        duration: Int, cast: [String] = [], director: String?, addedDaysAgo: Int, tmdbID: Int? = nil, rawSuffix: String = ""
    ) -> Movie? {
        guard let streamURL = URL(string: stream) else { return nil }
        let badge = quality.badge.map { " \($0)" } ?? ""
        return Movie(
            sourceID: sourceID, nativeID: id, title: title, rawName: "\(title) (\(year))\(badge)\(rawSuffix)", year: year,
            posterURL: poster.flatMap(url), backdropURL: backdrop.flatMap(url), plot: plot, genres: genres,
            rating: rating, durationSeconds: duration, cast: cast, director: director,
            categoryID: categoryID(.movie, category), streamURL: streamURL, containerExtension: container,
            quality: quality, addedAt: referenceDate.addingTimeInterval(TimeInterval(-addedDaysAgo * 86_400)),
            tmdbID: tmdbID
        )
    }

    private static let bbbPlot = "Un lapin géant au grand cœur profite paisiblement de la forêt jusqu’à ce que trois rongeurs farceurs s’en prennent à lui et aux papillons qu’il aime tant. Poussé à bout, le doux colosse prépare une revanche aussi ingénieuse que spectaculaire. Le court métrage culte du projet Peach de la Blender Foundation."
    private static let tosPlot = "Dans un Amsterdam futuriste, un groupe de scientifiques et de soldats tente de sauver le monde d’une invasion de robots en rejouant une rupture amoureuse qui a mal tourné des années plus tôt. Un court métrage mêlant prises de vues réelles et effets visuels entièrement créés avec Blender."

    private static let movies: [Movie] = [
        movie("big-buck-bunny", "Big Buck Bunny", year: 2008, quality: .fhd,
              stream: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8", container: "m3u8", category: "anim",
              poster: commons + "thumb/c/c5/Big_buck_bunny_poster_big.jpg/960px-Big_buck_bunny_poster_big.jpg",
              backdrop: commons + "thumb/e/e6/Big.Buck.Bunny.-.Landscape.png/1280px-Big.Buck.Bunny.-.Landscape.png",
              plot: bbbPlot, genres: ["Animation", "Comédie", "Familial"], rating: 6.4, duration: 596,
              director: "Sacha Goedegebure", addedDaysAgo: 1, tmdbID: 10378),
        movie("big-buck-bunny-mp4", "Big Buck Bunny", year: 2008, quality: .sd,
              stream: "https://archive.org/download/BigBuckBunny_124/Content/big_buck_bunny_720p_surround.mp4", container: "mp4",
              category: "anim", poster: nil, backdrop: nil, plot: bbbPlot, genres: ["Animation"], rating: 6.4, duration: 597,
              director: "Sacha Goedegebure", addedDaysAgo: 30, tmdbID: 10378, rawSuffix: " [MP4]"),
        movie("sprite-fright", "Sprite Fright", year: 2021, quality: .fhd,
              stream: "https://archive.org/download/sprite-fright/Sprite%20Fright%20-%20Open%20Movie%20by%20Blender%20Studio-804p.mp4",
              container: "mp4", category: "comedy",
              poster: commons + "thumb/e/e5/Sprite_Fright-movie_poster.jpg/960px-Sprite_Fright-movie_poster.jpg",
              backdrop: studioArt + "header/project/ff/3d/ff3d8a8048e767cbc92d6489404924b2.jpg",
              plot: "Une bande d’adolescents bruyants part faire la fête dans une forêt reculée d’Irlande du Nord. Ils y découvrent les « Sprites », d’adorables petites créatures champignons… qui ne tolèrent pas qu’on manque de respect à la nature. Une comédie horrifique dans l’esprit des années 80.",
              genres: ["Animation", "Horreur", "Comédie"], rating: 7.0, duration: 630,
              director: "Matthew Luhn, Hjalti Hjálmarsson", addedDaysAgo: 2),
        movie("spring", "Spring", year: 2019, quality: .sd,
              stream: "https://archive.org/download/spring_blenderopenmovie/Spring%20-%20Blender%20Open%20Movie%20-%20YouTube.mp4",
              container: "mp4", category: "anim",
              poster: studioArt + "thumbnail/b5/b9/b5b96c3ca39745d4bc46b62e72c51bf4_o_xs.webp",
              backdrop: studioArt + "header/project/e5/0f/e50f13c31a485f3a05d4983f1b4ab7ee.png",
              plot: "Une jeune bergère et son chien affrontent d’anciens esprits de la forêt pour que le cycle de la vie puisse continuer. Un conte poétique et lumineux, inspiré par l’enfance du réalisateur dans les montagnes.",
              genres: ["Animation", "Fantastique"], rating: 7.4, duration: 464, director: "Andy Goralczyk", addedDaysAgo: 3),
        movie("agent-327", "Agent 327 : Opération Barbershop", year: 2017, quality: .fhd,
              stream: "https://archive.org/download/agent327operationbarbershop/agent327-1080.mp4", container: "mp4",
              category: "comedy",
              poster: studioArt + "thumbnail/00/006f7d937a3540fa9dc4d2be4b73b551/006f7d937a3540fa9dc4d2be4b73b551.png",
              backdrop: studioArt + "header/blog/da/5e/da5eb81a801bb705301bf5e951dfb43e.jpg",
              plot: "Infiltré dans un salon de coiffure qui sert de façade à un réseau criminel, l’agent 327, le plus célèbre des espions néerlandais, affronte le redoutable Boris Kloris dans une bagarre aussi drôle que spectaculaire. D’après la bande dessinée de Martin Lodewijk.",
              genres: ["Animation", "Action", "Comédie"], rating: 7.4, duration: 232,
              director: "Colin Levy, Hjalti Hjálmarsson", addedDaysAgo: 4),
        movie("cosmos-laundromat", "Cosmos Laundromat", year: 2015, quality: .fhd,
              stream: "https://archive.org/download/cosmos-laundromat-first-cycle/Cosmos%20Laundromat%20-%20First%20Cycle.mp4",
              container: "mp4", category: "anim",
              poster: commons + "thumb/c/c5/CosmosLaundromatPoster.jpg/960px-CosmosLaundromatPoster.jpg",
              backdrop: commons + "thumb/2/22/CosmosLaundromat-final-scene.jpg/1280px-CosmosLaundromat-final-scene.jpg",
              plot: "Sur une île désolée, Franck, un mouton désabusé, croise la route de Victor, un mystérieux vendeur qui lui offre le cadeau d’une vie… ou plutôt de plusieurs. Le premier cycle d’un projet de long métrage de la Blender Foundation.",
              genres: ["Animation", "Fantastique", "Comédie"], rating: 7.2, duration: 731,
              cast: ["Pierre Bokma", "Reinout Scholten van Aschat"], director: "Mathieu Auvray", addedDaysAgo: 5),
        movie("tears-of-steel", "Tears of Steel", year: 2012, quality: .fhd,
              stream: "https://test-streams.mux.dev/tos_ismc/main.m3u8", container: "m3u8", category: "scifi",
              poster: commons + "thumb/7/70/Tos-poster.png/960px-Tos-poster.png",
              backdrop: commons + "thumb/1/18/Tears_of_Steel_frame_01_2a.jpg/1920px-Tears_of_Steel_frame_01_2a.jpg",
              plot: tosPlot, genres: ["Science-fiction", "Action"], rating: 6.0, duration: 734,
              cast: ["Derek de Lint", "Sergio Hasselbaink", "Rogier Schippers", "Vanja Rukavina", "Denise Rebergen"],
              director: "Ian Hubert", addedDaysAgo: 6, tmdbID: 133701),
        movie("tears-of-steel-usp", "Tears of Steel", year: 2012, quality: .hd,
              stream: "https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8",
              container: "m3u8", category: "scifi", poster: nil, backdrop: nil, plot: tosPlot,
              genres: ["Science-fiction"], rating: 6.0, duration: 734, director: "Ian Hubert", addedDaysAgo: 40,
              tmdbID: 133701, rawSuffix: " [VOSTFR]"),
        movie("sintel", "Sintel", year: 2010, quality: .fhd,
              stream: "https://archive.org/download/Sintel/sintel-2048-surround.mp4", container: "mp4", category: "anim",
              poster: commons + "8/8f/Sintel_poster.jpg",
              backdrop: commons + "thumb/6/6d/Durian_-_Sintel-wallpaper-dragon.jpg/1280px-Durian_-_Sintel-wallpaper-dragon.jpg",
              plot: "Une jeune guerrière solitaire parcourt des contrées hostiles à la recherche d’un bébé dragon qu’elle avait recueilli et soigné avant qu’il ne lui soit arraché. Sa quête la mènera jusqu’au repaire d’un dragon adulte, où l’attend une vérité bouleversante.",
              genres: ["Animation", "Fantastique", "Aventure"], rating: 7.3, duration: 888,
              cast: ["Halina Reijn", "Thom Hoffman"], director: "Colin Levy", addedDaysAgo: 7, tmdbID: 45745),
        movie("elephants-dream", "Elephants Dream", year: 2006, quality: .hd,
              stream: "https://download.blender.org/ED/elephantsdream-720-h264-st-aac.mov", container: "mov", category: "scifi",
              poster: studioArt + "thumbnail/f6/d6/f6d66663d511c54caa25595e189768f77ebab3a9_o_xs.webp",
              backdrop: studioArt + "header/project/8b/d7/8bd7d4c5b572890a86299ff40813a201.png",
              plot: "Dans un monde mécanique sans fin, le vieux Proog guide le jeune Emo à travers une machine labyrinthique dont lui seul semble comprendre les règles. Mais leurs visions du monde divergent… Le tout premier « open movie », réalisé avec Blender.",
              genres: ["Animation", "Science-fiction"], rating: 5.6, duration: 654,
              cast: ["Tygo Gernandt", "Cas Jansen"], director: "Bassam Kurdali", addedDaysAgo: 8, tmdbID: 9761),
    ].compactMap { $0 }

    // MARK: - Series

    private static let caminandesID = ContentID(source: sourceID, kind: .series, nativeID: "caminandes")

    private static func episode(_ id: String, season: Int, number: Int, title: String, plot: String, duration: Int, stream: String, still: String, aired: String) -> Episode? {
        guard let streamURL = URL(string: stream) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return Episode(
            seriesID: caminandesID, sourceID: sourceID, nativeID: id, season: season, number: number, title: title,
            plot: plot, durationSeconds: duration, stillURL: url(still), streamURL: streamURL,
            containerExtension: "mp4", airDate: formatter.date(from: aired)
        )
    }

    private static let series: [Series] = [
        Series(
            sourceID: sourceID, nativeID: "caminandes", title: "Caminandes", rawName: "Caminandes (2013) FHD", year: 2013,
            posterURL: url(studioArt + "thumbnail/e5/83/e58372aa0af5e669325a4913a46b12561e7d60a8_o.webp"),
            backdropURL: url(studioArt + "header/project/2f/89/2f897cfe4d6092c3ce77566de98019e1.jpg"),
            plot: "Dans les paysages arides de Patagonie, Koro, un lama têtu et toujours affamé, est prêt à tout pour atteindre l’herbe plus verte de l’autre côté de la route… ou de la clôture. Une série de courts métrages burlesques réalisés avec Blender.",
            genres: ["Animation", "Comédie", "Familial"], rating: 6.9, cast: [], director: "Pablo Vazquez",
            categoryID: categoryID(.series, "anim-series"), quality: .fhd,
            addedAt: referenceDate.addingTimeInterval(-86_400 * 2),
            seasons: [
                Season(number: 1, name: "Saison 1", episodes: [
                    episode("caminandes-s1e1", season: 1, number: 1, title: "Llama Drama",
                            plot: "Koro tente de traverser une route perdue au milieu du désert patagonien. Un défi bien plus périlleux qu’il n’y paraît.",
                            duration: 90, stream: "https://archive.org/download/Caminandes1LlamaDrama/01_llama_drama_1080p.mp4",
                            still: commons + "thumb/6/61/Pablo_Vazquez_-_Caminandes_-_Episode_1_-_Llama_Drama_-_Cover_thumbnail.png/1280px-Pablo_Vazquez_-_Caminandes_-_Episode_1_-_Llama_Drama_-_Cover_thumbnail.png",
                            aired: "2013-01-01"),
                    episode("caminandes-s1e2", season: 1, number: 2, title: "Gran Dillama",
                            plot: "L’herbe est toujours plus verte de l’autre côté de la clôture électrique : Koro va l’apprendre à ses dépens.",
                            duration: 146, stream: "https://archive.org/download/Caminandes2GranDillama/02_gran_dillama_1080p.mp4",
                            still: studioArt + "thumbnail/80/4b/804beb324d82e98db44d8308d9e6f495_m.webp",
                            aired: "2013-11-22"),
                ].compactMap { $0 }),
                Season(number: 2, name: "Saison 2", episodes: [
                    episode("caminandes-s2e1", season: 2, number: 1, title: "Llamigos",
                            plot: "En plein hiver, Koro croise Oti, un manchot taquin, et doit lui disputer les dernières baies rouges de la montagne.",
                            duration: 150, stream: "https://archive.org/download/CaminandesLlamigos/Caminandes_%20Llamigos-1080p.mp4",
                            still: studioArt + "thumbnail/6e/84/6e84fd08dda59d66aeb2152cb879f160_m.webp", aired: "2016-09-30"),
                ].compactMap { $0 }),
            ]
        ),
    ]

    // MARK: - Guide blocks

    private struct GuideBlock {
        var title: String
        var summary: String
        var category: String
        var minutes: Int
    }

    private static let guideBlocks: [String: [GuideBlock]] = [
        categoryID(.live, "info"): [
            GuideBlock(title: "Le journal", summary: "Les titres de l’actualité internationale.", category: "Information", minutes: 30),
            GuideBlock(title: "Information en continu", summary: "Actualité, reportages et analyses.", category: "Information", minutes: 60),
            GuideBlock(title: "Le débat", summary: "Experts et invités décryptent l’actualité.", category: "Débat", minutes: 30),
            GuideBlock(title: "Économie", summary: "Marchés, entreprises et tendances.", category: "Économie", minutes: 30),
            GuideBlock(title: "Reportages", summary: "Grands formats et documentaires d’actualité.", category: "Magazine", minutes: 60),
        ],
        categoryID(.live, "sport"): [
            GuideBlock(title: "Sports extrêmes", summary: "Glisse, VTT, escalade et sensations fortes.", category: "Sport", minutes: 60),
            GuideBlock(title: "Aventure", summary: "Expéditions et défis aux quatre coins du monde.", category: "Documentaire", minutes: 90),
            GuideBlock(title: "En direct", summary: "Retransmission d’un événement sportif.", category: "Sport", minutes: 120),
        ],
        categoryID(.live, "demo"): [
            GuideBlock(title: "Démo HLS en boucle", summary: "Flux de démonstration Apple pour tester la lecture adaptative.", category: "Démo", minutes: 60),
        ],
    ]
}
