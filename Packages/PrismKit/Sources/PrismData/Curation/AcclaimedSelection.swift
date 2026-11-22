import PrismCore

/// Works with lasting critical and public recognition (Oscars, Césars, Cannes, Emmys, long-standing
/// critics' and audience rankings). Matching marks catalogue titles as canon: they lead
/// "Primés et acclamés", "Les grands classiques" and weigh in every ranking.
///
/// Each line is `year|name|alias…`, the year being the first release. Names are matched through the
/// same key as provider titles, with a year tolerance of one for providers that use the local release.
enum AcclaimedSelection {
    @concurrent
    static func matches(in catalog: Catalog) async -> Set<TitleID> {
        var result: Set<TitleID> = []
        for (kind, lines) in [(MediaKind.movie, movies), (.series, series)] {
            for line in lines {
                let parts = line.split(separator: "|", omittingEmptySubsequences: true)
                guard parts.count >= 2, let year = Int(parts[0]) else { continue }
                let keys = Set(parts.dropFirst().map { TitleNormalizer.key(String($0)) }).filter { !$0.isEmpty }
                var found: MediaTitle?
                search: for candidateYear in [year, year - 1, year + 1] {
                    for key in keys {
                        if let title = catalog.title(TitleID(kind: kind, normalizedTitle: key, year: candidateYear)),
                           title.kind == kind, !title.isAdult {
                            found = title
                            break search
                        }
                    }
                }
                if let found { result.insert(found.id) }
            }
        }
        return result
    }

    static let movies: [String] = [
        // Film history
        "1937|La Grande Illusion|Grand Illusion", "1941|Citizen Kane", "1942|Casablanca",
        "1946|It’s a Wonderful Life|La vie est belle", "1950|Sunset Boulevard|Boulevard du crépuscule",
        "1954|Seven Samurai|Les Sept Samouraïs", "1954|Rear Window|Fenêtre sur cour", "1957|12 Angry Men|Douze Hommes en colère",
        "1958|Vertigo|Sueurs froides", "1959|North by Northwest|La Mort aux trousses", "1959|Some Like It Hot|Certains l’aiment chaud",
        "1960|Psycho|Psychose", "1960|À bout de souffle|Breathless", "1962|Lawrence of Arabia|Lawrence d’Arabie",
        "1962|Jules et Jim|Jules and Jim", "1963|Le Mépris|Contempt", "1964|Dr. Strangelove|Docteur Folamour",
        "1966|The Good, the Bad and the Ugly|Le Bon, la Brute et le Truand", "1966|La Grande Vadrouille",
        "1968|2001: A Space Odyssey|2001, l’odyssée de l’espace", "1968|Once Upon a Time in the West|Il était une fois dans l’Ouest",
        "1971|A Clockwork Orange|Orange mécanique", "1972|The Godfather|Le Parrain", "1973|The Exorcist|L’Exorciste",
        "1974|The Godfather Part II|The Godfather: Part II|Le Parrain, 2e partie|Le Parrain 2", "1974|Chinatown",
        "1975|Jaws|Les Dents de la mer", "1975|One Flew Over the Cuckoo’s Nest|Vol au-dessus d’un nid de coucou",
        "1976|Taxi Driver", "1976|Rocky", "1978|The Deer Hunter|Voyage au bout de l’enfer", "1979|Alien|Alien, le huitième passager",
        "1979|Apocalypse Now", "1979|Mad Max", "1980|The Shining|Shining", "1980|The Empire Strikes Back|L’Empire contre-attaque",
        "1981|Raiders of the Lost Ark|Les Aventuriers de l’arche perdue", "1982|Blade Runner",
        "1982|E.T. the Extra-Terrestrial|E.T. l’extra-terrestre|E.T.", "1982|The Thing", "1983|Scarface",
        "1984|The Terminator|Terminator", "1984|Amadeus", "1984|Once Upon a Time in America|Il était une fois en Amérique",
        "1984|Ghostbusters|SOS Fantômes", "1985|Back to the Future|Retour vers le futur", "1985|Ran",
        "1986|Aliens|Aliens, le retour", "1986|Platoon", "1986|Top Gun", "1987|Full Metal Jacket",
        "1988|Die Hard|Piège de cristal", "1988|Rain Man", "1988|Cinema Paradiso|Nuovo Cinema Paradiso",
        "1988|My Neighbor Totoro|Mon voisin Totoro", "1988|Grave of the Fireflies|Le Tombeau des lucioles",
        "1989|Dead Poets Society|Le Cercle des poètes disparus", "1989|Indiana Jones and the Last Crusade|Indiana Jones et la Dernière Croisade",
        "1990|Goodfellas|Les Affranchis", "1990|Dances with Wolves|Danse avec les loups",
        "1991|The Silence of the Lambs|Le Silence des agneaux", "1991|Terminator 2: Judgment Day|Terminator 2 : Le Jugement dernier|Terminator 2",
        "1991|Beauty and the Beast|La Belle et la Bête", "1992|Reservoir Dogs", "1992|Unforgiven|Impitoyable", "1992|Aladdin",
        "1993|Schindler’s List|La Liste de Schindler", "1993|Jurassic Park", "1993|Groundhog Day|Un jour sans fin",
        "1993|Les Visiteurs", "1994|The Shawshank Redemption|Les Évadés", "1994|Pulp Fiction", "1994|Forrest Gump",
        "1994|The Lion King|Le Roi lion", "1994|Léon|Léon: The Professional", "1995|Se7en|Seven", "1995|Heat",
        "1995|The Usual Suspects|Usual Suspects", "1995|Braveheart", "1995|Toy Story", "1995|La Haine",
        "1996|Fargo", "1997|Titanic", "1997|Good Will Hunting|Will Hunting", "1997|L.A. Confidential",
        "1997|Life Is Beautiful|La vita è bella", "1997|Princess Mononoke|Princesse Mononoké",
        "1998|Saving Private Ryan|Il faut sauver le soldat Ryan", "1998|American History X", "1998|The Truman Show",
        "1998|The Big Lebowski", "1998|Le Dîner de cons", "1999|Fight Club", "1999|The Matrix|Matrix",
        "1999|The Green Mile|La Ligne verte", "1999|American Beauty",
        // 2000s
        "2000|Gladiator", "2000|Memento", "2000|Requiem for a Dream", "2000|Snatch",
        "2000|Crouching Tiger, Hidden Dragon|Tigre et Dragon", "2000|Le Goût des autres",
        "2001|The Lord of the Rings: The Fellowship of the Ring|Le Seigneur des anneaux : La Communauté de l’anneau",
        "2001|Spirited Away|Le Voyage de Chihiro", "2001|Amélie|Le Fabuleux Destin d’Amélie Poulain",
        "2001|A Beautiful Mind|Un homme d’exception", "2001|Monsters, Inc.|Monstres & Cie",
        "2002|The Lord of the Rings: The Two Towers|Le Seigneur des anneaux : Les Deux Tours",
        "2002|City of God|La Cité de Dieu|Cidade de Deus", "2002|The Pianist|Le Pianiste",
        "2002|Catch Me If You Can|Arrête-moi si tu peux",
        "2003|The Lord of the Rings: The Return of the King|Le Seigneur des anneaux : Le Retour du roi",
        "2003|Oldboy|Old Boy", "2003|Finding Nemo|Le Monde de Nemo", "2003|Kill Bill: Vol. 1|Kill Bill : Volume 1",
        "2003|Lost in Translation", "2004|Eternal Sunshine of the Spotless Mind", "2004|The Incredibles|Les Indestructibles",
        "2004|Million Dollar Baby", "2004|Howl’s Moving Castle|Le Château ambulant", "2004|Les Choristes",
        "2005|Batman Begins", "2005|Brokeback Mountain", "2006|The Departed|Les Infiltrés", "2006|The Prestige|Le Prestige",
        "2006|Pan’s Labyrinth|Le Labyrinthe de Pan|El laberinto del fauno", "2006|The Lives of Others|La Vie des autres|Das Leben der Anderen",
        "2006|Children of Men|Les Fils de l’homme", "2006|The Pursuit of Happyness|À la recherche du bonheur",
        "2006|OSS 117 : Le Caire, nid d’espions|OSS 117: Cairo, Nest of Spies", "2007|No Country for Old Men",
        "2007|There Will Be Blood", "2007|Ratatouille", "2007|Into the Wild", "2007|La Môme|La Vie en Rose",
        "2008|The Dark Knight|The Dark Knight : Le Chevalier noir", "2008|WALL·E|WALL-E", "2008|Gran Torino",
        "2008|Slumdog Millionaire", "2009|Inglourious Basterds", "2009|Up|Là-haut", "2009|Avatar",
        "2009|The Hurt Locker|Démineurs", "2009|District 9", "2009|The Secret in Their Eyes|Dans ses yeux|El secreto de sus ojos",
        "2009|Un prophète|A Prophet",
        // 2010s
        "2010|Inception", "2010|Shutter Island", "2010|The Social Network", "2010|Toy Story 3",
        "2010|The King’s Speech|Le Discours d’un roi", "2010|Incendies", "2010|Des hommes et des dieux|Of Gods and Men",
        "2011|The Intouchables|Intouchables", "2011|Drive", "2011|A Separation|Une séparation", "2011|The Artist",
        "2012|Django Unchained", "2012|The Dark Knight Rises", "2012|Argo", "2012|Life of Pi|L’Odyssée de Pi",
        "2012|De rouille et d’os|Rust and Bone", "2013|The Wolf of Wall Street|Le Loup de Wall Street",
        "2013|12 Years a Slave|Twelve Years a Slave", "2013|Gravity", "2013|Her", "2013|Prisoners",
        "2013|La Vie d’Adèle|Blue Is the Warmest Colour", "2013|The Hunt|La Chasse|Jagten", "2014|Interstellar",
        "2014|Whiplash", "2014|Gone Girl", "2014|The Grand Budapest Hotel|Grand Budapest Hotel", "2014|Birdman",
        "2014|Nightcrawler|Night Call", "2014|Boyhood", "2014|Wild Tales|Les Nouveaux Sauvages|Relatos salvajes",
        "2014|Timbuktu", "2015|Mad Max: Fury Road", "2015|Inside Out|Vice-versa", "2015|Spotlight", "2015|The Revenant",
        "2015|The Martian|Seul sur Mars", "2015|Room", "2016|Arrival|Premier Contact", "2016|La La Land", "2016|Moonlight",
        "2016|Manchester by the Sea", "2016|Hacksaw Ridge|Tu ne tueras point", "2016|Your Name|Your Name.|Kimi no na wa",
        "2017|Get Out", "2017|Blade Runner 2049", "2017|Coco", "2017|Dunkirk", "2017|Lady Bird",
        "2017|Call Me by Your Name", "2017|The Shape of Water|La Forme de l’eau",
        "2017|Three Billboards Outside Ebbing, Missouri|3 Billboards : Les Panneaux de la vengeance",
        "2017|120 battements par minute|BPM (Beats per Minute)", "2018|Spider-Man: Into the Spider-Verse|Spider-Man : New Generation",
        "2018|Avengers: Infinity War", "2018|Roma", "2018|Green Book|Green Book : Sur les routes du Sud", "2018|BlacKkKlansman",
        "2018|A Star Is Born", "2018|Shoplifters|Une affaire de famille", "2018|Jusqu’à la garde|Custody",
        "2019|Parasite|Gisaengchung", "2019|Joker", "2019|Avengers: Endgame", "2019|1917", "2019|Ford v Ferrari|Le Mans 66",
        "2019|Once Upon a Time in Hollywood|Once Upon a Time… in Hollywood", "2019|Knives Out|À couteaux tirés",
        "2019|Jojo Rabbit", "2019|Marriage Story", "2019|Portrait de la jeune fille en feu|Portrait of a Lady on Fire",
        "2019|Les Misérables", "2019|J’accuse|An Officer and a Spy",
        // 2020s
        "2020|Nomadland", "2020|Soul", "2020|The Father", "2020|Another Round|Drunk|Druk", "2020|Minari",
        "2020|Sound of Metal", "2021|Dune", "2021|The Power of the Dog", "2021|CODA", "2021|Drive My Car",
        "2021|The Worst Person in the World|Julie (en 12 chapitres)", "2021|Titane",
        "2022|Everything Everywhere All at Once", "2022|Top Gun: Maverick|Top Gun : Maverick",
        "2022|All Quiet on the Western Front|À l’Ouest, rien de nouveau|Im Westen nichts Neues",
        "2022|The Banshees of Inisherin|Les Banshees d’Inisherin", "2022|Tár|TÁR", "2022|Decision to Leave",
        "2023|Oppenheimer", "2023|Anatomie d’une chute|Anatomy of a Fall", "2023|Killers of the Flower Moon",
        "2023|Spider-Man: Across the Spider-Verse", "2023|The Holdovers|Winter Break", "2023|Past Lives|Past Lives – Nos vies d’avant",
        "2023|Poor Things|Pauvres Créatures", "2023|The Zone of Interest|La Zone d’intérêt", "2023|Godzilla Minus One",
        "2023|The Boy and the Heron|Le Garçon et le Héron", "2023|La Passion de Dodin Bouffant|The Taste of Things",
        "2024|Dune: Part Two|Dune : Deuxième Partie", "2024|Anora", "2024|The Brutalist", "2024|Conclave",
        "2024|The Substance", "2024|The Wild Robot|Le Robot sauvage", "2024|Flow|Flow, le chat qui n’avait plus peur de l’eau",
        "2024|Le Comte de Monte-Cristo|The Count of Monte Cristo", "2024|L’Amour ouf|Beating Hearts", "2024|Un p’tit truc en plus",
        "2024|Inside Out 2|Vice-versa 2", "2025|Sinners|Les Pécheurs", "2025|One Battle After Another|Une bataille après l’autre",
        "2025|KPop Demon Hunters", "2025|Weapons|Évanouis", "2025|Sentimental Value|Valeur sentimentale|Affeksjonsverdi",
        "2025|Hamnet", "2025|Train Dreams", "2025|F1 Le Film|F1: The Movie",
    ]

    static let series: [String] = [
        "1989|Seinfeld", "1990|Twin Peaks", "1993|The X-Files|X-Files : Aux frontières du réel", "1994|Friends",
        "1997|Oz", "1998|Cowboy Bebop", "1999|The Sopranos|Les Soprano", "1999|One Piece",
        "2001|Six Feet Under", "2001|Band of Brothers|Frères d’armes", "2002|The Wire|Sur écoute",
        "2003|Arrested Development", "2004|Lost|Lost : Les Disparus", "2004|Deadwood", "2004|House|Dr House",
        "2005|The Office", "2005|Rome", "2005|Kaamelott", "2005|Engrenages|Spiral", "2006|Dexter", "2006|30 Rock",
        "2006|Death Note", "2006|Planet Earth|Planète Terre", "2007|Mad Men", "2008|Breaking Bad",
        "2009|Parks and Recreation", "2009|Modern Family", "2009|Fullmetal Alchemist: Brotherhood", "2010|Sherlock",
        "2010|Luther", "2010|The Walking Dead", "2010|Downton Abbey", "2011|Game of Thrones|Le Trône de fer",
        "2011|Black Mirror", "2011|Homeland", "2011|Hunter x Hunter", "2012|Line of Duty", "2012|Les Revenants|The Returned",
        "2013|Peaky Blinders", "2013|Attack on Titan|L’Attaque des Titans|Shingeki no Kyojin", "2013|Brooklyn Nine-Nine",
        "2013|Orange Is the New Black", "2013|Rick and Morty", "2013|House of Cards", "2013|Hannibal", "2013|The Americans",
        "2014|True Detective", "2014|Fargo", "2014|BoJack Horseman", "2014|Halt and Catch Fire",
        "2015|Narcos", "2015|Mr. Robot", "2015|Better Call Saul", "2015|Fauda", "2015|Le Bureau des légendes|The Bureau",
        "2015|Dix pour cent|Call My Agent!", "2016|The Crown", "2016|Westworld", "2016|Fleabag", "2016|Stranger Things",
        "2016|The Night Of", "2016|Atlanta", "2016|Planet Earth II|Planète Terre II", "2016|Baron noir",
        "2017|Dark", "2017|Mindhunter", "2017|Ozark", "2017|The Handmaid’s Tale|La Servante écarlate",
        "2017|The Marvelous Mrs. Maisel|La Fabuleuse Mme Maisel", "2017|Money Heist|La Casa de Papel", "2017|Babylon Berlin",
        "2018|Succession", "2018|Killing Eve", "2018|Barry", "2018|Bodyguard", "2018|The Haunting of Hill House",
        "2019|Chernobyl", "2019|Watchmen", "2019|The Mandalorian", "2019|The Boys", "2019|Euphoria",
        "2019|When They See Us", "2019|Unbelievable", "2019|Demon Slayer|Demon Slayer: Kimetsu no Yaiba",
        "2020|The Queen’s Gambit|Le Jeu de la dame", "2020|Ted Lasso", "2020|Normal People", "2020|I May Destroy You",
        "2020|Jujutsu Kaisen", "2021|Lupin", "2021|Squid Game", "2021|Arcane", "2021|Mare of Easttown",
        "2021|The White Lotus", "2021|Only Murders in the Building", "2021|Hacks", "2021|Yellowjackets",
        "2021|Reservation Dogs", "2021|Station Eleven", "2021|HPI", "2022|Severance|Séparation", "2022|The Bear",
        "2022|Andor|Star Wars : Andor", "2022|House of the Dragon", "2022|Abbott Elementary", "2022|Wednesday|Mercredi",
        "2022|Slow Horses", "2022|Bad Sisters", "2023|The Last of Us", "2023|Beef|Acharnés", "2023|Silo",
        "2023|Blue Eye Samurai", "2023|Frieren|Frieren: Beyond Journey’s End", "2023|Poker Face",
        "2024|Shōgun|Shogun", "2024|Baby Reindeer|Mon petit renne", "2024|Ripley", "2024|The Penguin", "2024|Fallout",
        "2025|Adolescence", "2025|The Studio", "2025|Pluribus", "2025|The Pitt",
    ]
}
