import PrismCore
import Testing

@Suite("Synopses IPTV")
struct ProviderSynopsisTests {
    private let persian = "در این داستان پسر دزدی مشهور تلاش می‌کند تا رازهای پدرش را فاش کند و بی‌گناهی او را ثابت کند."
    private let english = "Inspired by the adventures of a legendary thief, Assane searches for the truth behind his father's arrest."
    private let french = "Inspiré par les aventures d’Arsène Lupin, Assane recherche la vérité sur l’arrestation de son père."

    @Test func selectsFrenchFromParallelTranslations() {
        #expect(ProviderSynopsis.cleaned("\(persian)           \(english)\n\n\(french)") == french)
    }

    @Test func selectsEnglishWhenFrenchIsMissing() {
        #expect(ProviderSynopsis.cleaned("\(persian)\t\t\t\t  \(english)") == english)
    }

    @Test func preservesAnAvailableSynopsisInAnyLanguage() {
        #expect(ProviderSynopsis.cleaned("  \(persian)  ") == persian)
        #expect(ProviderSynopsis.cleaned(" \t\n ") == nil)
    }

    @Test func normalizesSpacingAndKeepsParagraphs() {
        let continuation = "Il revient en ville pour retrouver sa famille, mais un témoin change soudain la suite de son enquête."
        #expect(ProviderSynopsis.cleaned("   \(french)\r\n\r\n\(continuation) \t ") == "\(french)\n\n\(continuation)")
        #expect(ProviderSynopsis.cleaned("  Une  enquête\tcommence.  ") == "Une enquête commence.")
    }
}
