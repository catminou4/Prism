import PrismCore

/// Order is editorial within each shelf. Selections include internationally distributed works,
/// and films and series recognized by Cannes, the Oscars, the Emmys or the International Emmys.
/// Year refers to first release, so the remake of a title cannot replace the selected work.
enum EditorialSelection {
    // https://www.unifrance.org/film/56620/le-comte-de-monte-cristo
    // https://www.festival-cannes.com/en/f/anatomie-d-une-chute/
    // https://www.iemmys.tv/international-emmy-awards/winners-archive/
    static let french: [EditorialTitle] = [
        .init(.movie, 2024, "Le Comte de Monte-Cristo", "The Count of Monte Cristo"),
        .init(.series, 2021, "Lupin"),
        .init(.movie, 2023, "Anatomie d’une chute", "Anatomy of a Fall", allowUndated: true),
        .init(.series, 2015, "Le Bureau des légendes", "The Bureau", allowUndated: true),
        .init(.movie, 2011, "Intouchables", "The Intouchables", allowUndated: true),
        .init(.series, 2015, "Dix pour cent", "Call My Agent!", allowUndated: true),
        .init(.movie, 2001, "Le Fabuleux Destin d’Amélie Poulain", "Amélie", "Amélie from Montmartre", allowUndated: true),
        .init(.series, 2021, "HPI", "HPI : Haut Potentiel Intellectuel", "HIP: High Intellectual Potential"),
        .init(.movie, 1995, "La Haine", "Hate"),
        .init(.series, 2005, "Engrenages", "Spiral"),
        .init(.movie, 2023, "Les Trois Mousquetaires : D’Artagnan", "The Three Musketeers: D’Artagnan"),
        .init(.series, 2023, "Les Gouttes de Dieu", "Drops of God", allowUndated: true),
        .init(.movie, 2011, "The Artist"),
        .init(.series, 2016, "Baron noir", allowUndated: true),
        .init(.movie, 2007, "La Môme", "La Vie en Rose"),
        .init(.movie, 2008, "Bienvenue chez les Ch’tis", "Welcome to the Sticks", allowUndated: true),
        .init(.movie, 1994, "Léon", "Léon : Le Professionnel", "Léon: The Professional", "The Professional"),
        .init(.movie, 1997, "Le Cinquième Élément", "The Fifth Element", allowUndated: true),
        .init(.movie, 1959, "Les Quatre Cents Coups", "Les 400 Coups", "The 400 Blows", allowUndated: true),
    ]

    // https://www.oscars.org/oscars/ceremonies
    // https://www.televisionacademy.com/awards
    static let american: [EditorialTitle] = [
        .init(.movie, 2025, "Sinners"),
        .init(.series, 2022, "Severance", allowUndated: true),
        .init(.movie, 2024, "Dune : Deuxième Partie", "Dune: Part Two", "Dune 2", allowUndated: true),
        .init(.series, 2022, "The Bear"),
        .init(.movie, 2025, "Une bataille après l’autre", "One Battle After Another", allowUndated: true),
        .init(.series, 2025, "The Pitt"),
        .init(.movie, 2023, "Oppenheimer", allowUndated: true),
        .init(.series, 2008, "Breaking Bad", allowUndated: true),
        .init(.movie, 2014, "Interstellar", allowUndated: true),
        .init(.series, 2018, "Succession"),
        .init(.movie, 2023, "Barbie"),
        .init(.series, 2015, "Better Call Saul", allowUndated: true),
        .init(.movie, 2022, "Everything Everywhere All at Once", allowUndated: true),
        .init(.series, 2016, "Stranger Things", allowUndated: true),
        .init(.movie, 2022, "Top Gun : Maverick", "Top Gun: Maverick", allowUndated: true),
        .init(.series, 2011, "Game of Thrones", "Le Trône de fer", allowUndated: true),
        .init(.movie, 2016, "La La Land", allowUndated: true),
        .init(.series, 2023, "The Last of Us"),
        .init(.movie, 2010, "Inception"),
        .init(.series, 2002, "The Wire", "Sur écoute"),
        .init(.movie, 2008, "The Dark Knight", "The Dark Knight : Le Chevalier noir"),
        .init(.series, 1999, "Les Soprano", "The Sopranos", allowUndated: true),
        .init(.movie, 1994, "Les Évadés", "The Shawshank Redemption"),
        .init(.movie, 1994, "Pulp Fiction", allowUndated: true),
        .init(.movie, 1972, "Le Parrain", "The Godfather"),
    ]

    // https://www.festival-cannes.com/en/retrospective/2019/palmares/
    // https://www.oscars.org/oscars/ceremonies/2024
    // https://www.televisionacademy.com/shows/reservation-dogs
    static let discoveries: [EditorialTitle] = [
        .init(.movie, 2019, "Portrait de la jeune fille en feu", "Portrait of a Lady on Fire", allowUndated: true),
        .init(.series, 2021, "Reservation Dogs", allowUndated: true),
        .init(.movie, 2023, "Winter Break", "The Holdovers", allowUndated: true),
        .init(.series, 2012, "Les Revenants", "The Returned"),
        .init(.movie, 2025, "Train Dreams"),
        .init(.movie, 2025, "Arco"),
        .init(.series, 2022, "Somebody Somewhere", allowUndated: true),
        .init(.movie, 2023, "Past Lives – Nos vies d’avant", "Past Lives", "Nos vies d’avant"),
        .init(.series, 2022, "Les 7 vies de Léa", "Les Sept Vies de Léa", "The 7 Lives of Lea", allowUndated: true),
        .init(.movie, 2019, "Les Misérables"),
        .init(.series, 2021, "Station Eleven", allowUndated: true),
        .init(.movie, 2016, "Moonlight"),
        .init(.series, 2022, "Les Papillons noirs", "Black Butterflies"),
        .init(.movie, 2021, "Titane", allowUndated: true),
        .init(.series, 2016, "Atlanta"),
        .init(.movie, 2009, "Un prophète", "A Prophet"),
        .init(.series, 2023, "Poker Face"),
        .init(.movie, 2020, "Minari", allowUndated: true),
        .init(.series, 2013, "The Americans"),
        .init(.movie, 2019, "Sound of Metal", allowUndated: true),
        .init(.series, 2014, "Halt and Catch Fire", allowUndated: true),
        .init(.movie, 2023, "La Passion de Dodin Bouffant", "The Taste of Things", allowUndated: true),
        .init(.movie, 2008, "Entre les murs", "The Class"),
        .init(.movie, 2023, "Le Règne animal", "The Animal Kingdom"),
        .init(.movie, 2007, "Persepolis", allowUndated: true),
        .init(.movie, 2019, "Parasite", "Gisaengchung"),
        .init(.movie, 2022, "Decision to Leave", "Heojil Kyolshim", allowUndated: true),
        .init(.movie, 2021, "Drive My Car", "Doraibu mai kā", allowUndated: true),
        .init(.movie, 2018, "Une affaire de famille", "Shoplifters"),
        .init(.movie, 2021, "Julie (en 12 chapitres)", "The Worst Person in the World", allowUndated: true),
        .init(.movie, 2011, "Une séparation", "A Separation"),
        .init(.movie, 2018, "Burning", "Beoning"),
    ]
}
