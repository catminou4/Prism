import Testing
@testable import PrismCore

@Suite("TitleRefinement")
struct TitleRefinementTests {
    @Test("Provider leftovers are removed", arguments: [
        ("A Fistful Of Dollars CLINT EASTWOOD, SERGIO LEONE", "A Fistful Of Dollars"),
        ("The Runner NICOLAS CAGE", "The Runner"),
        ("Il Conformista, The Conformist (ITALIAN ENG-SUB) BERNARDO BERTOLUCCI", "Il Conformista, The Conformist"),
        ("The Fall Of El Mayo (SPANISH MULTI SUB)", "The Fall Of El Mayo"),
        ("Redemptions (QUEBEC FRENCH ENG-SUB)", "Redemptions"),
        ("Night of the Zoopocalypse (Svenskt Tal)", "Night of the Zoopocalypse"),
        ("Black Panther(БГ Аудио)", "Black Panther"),
        ("Narcos SPANISH MULTI SUB", "Narcos"),
        ("Autumn At Apple Hill Hallmark", "Autumn At Apple Hill"),
        ("The Movie HALLMARK", "The Movie"),
        ("A Film hallmar\u{212A}", "A Film"),
        ("Une Présentation Spéciale Marvel Television : The Punisher : One Last Kill", "The Punisher : One Last Kill"),
        ("Taylor Swift | The Eras Tour | The End of an Era", "Taylor Swift – The Eras Tour – The End of an Era"),
        ("The Killing (2011-2014)", "The Killing"),
        ("Tulsa King پادشاه تالسا", "Tulsa King"),
        ("Kızılcık Serbeti شربت زغال اخته (حفظ آبرو)", "Kızılcık Serbeti"),
        ("Napoleon Dar Bagh Zardaloo ناپلئون در باغ زردآلو AMIR JAFARI", "Napoleon Dar Bagh Zardaloo"),
        ("Alparslan_ Büyük Selçuklu", "Alparslan: Büyük Selçuklu"),
        ("Cry_Wolf", "Cry Wolf"),
        ("THREE HOUSEWIVES AND A BODY", "Three Housewives and a Body"),
        ("THE GODFATHER PART II", "The Godfather Part II"),
        ("Poison WES ANDERSON", "Poison"),
        ("Les Sept Samouraïs VSFR", "Les Sept Samouraïs"),
        ("Enola Holmes انولا هولمز 3", "Enola Holmes 3"),
        ("Toy Story (Svensk Text)", "Toy Story"),
    ])
    func cleans(raw: String, expected: String) {
        #expect(TitleRefinement.refine(raw) == expected)
        #expect(TitleRefinement.refine(expected) == expected)
    }

    @Test("Real titles are left alone", arguments: [
        "Crouching Tiger, Hidden Dragon", "Love, Death & Robots", "JUNG_E", "Ghost in the Shell: SAC_2045",
        "RIPLEY", "M3GAN 2.0", "FUBAR", "Mission: Impossible – DEAD RECKONING", "Agents of S.H.I.E.L.D.",
        "Les Parfait(s) : Arnaques en Famille", "Star Wars: Episode IV – A New Hope", "Le Bureau des légendes",
        "The Lord of the Rings: The Rings of Power", "Halt and Catch Fire", "Me, Myself & Irene",
        "Law & Order: SVU", "Hallmark", "Movie HALLMARK", "Hallmark Movies", "Bon Cop, Bad Cop", "فيلم الجواهرجي",
    ])
    func keeps(title: String) {
        #expect(TitleRefinement.refine(title) == title)
    }
}
