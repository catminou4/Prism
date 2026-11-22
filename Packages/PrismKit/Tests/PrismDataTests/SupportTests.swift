import Foundation
import Testing
@testable import PrismData

@Suite("Support")
struct SupportTests {
    @Test(arguments: [
        ("Amélie", "amelie"), ("ŒDIPE", "oedipe"), ("Straße", "strasse"), ("plain", "plain"), ("MiXeD 42", "mixed 42"),
        ("Ｆｕｌｌ", "full"),
    ])
    func folding(input: String, expected: String) {
        #expect(TextFolding.fold(input) == expected)
    }

    @Test func words() {
        let words = TextFolding.words(ofFolded: TextFolding.fold("Le Fabuleux Destin d'Amélie Poulain (2001)"))
        #expect(words.map { String(decoding: $0, as: UTF8.self) } == ["le", "fabuleux", "destin", "d", "amelie", "poulain", "2001"])
    }

    @Test func unicodePunctuationNeverGluesToWords() {
        // Guillemets and CJK punctuation are separators: every UTF-8 byte ≥ 0x80 used to count
        // as a word byte, gluing «» and 。 onto neighbouring words in the search postings.
        let french = TextFolding.words(ofFolded: TextFolding.fold("« Amour »"))
        #expect(french.map { String(decoding: $0, as: UTF8.self) } == ["amour"])
        let cjk = TextFolding.words(ofFolded: TextFolding.fold("。SAC"))
        #expect(cjk.map { String(decoding: $0, as: UTF8.self) } == ["sac"])
        // Letters from non-Latin scripts stay word characters.
        let cyrillic = TextFolding.words(ofFolded: TextFolding.fold("\u{41C}\u{43E}\u{441}\u{43A}\u{432}\u{430} 2024"))
        #expect(cyrillic.map { String(decoding: $0, as: UTF8.self) } == ["\u{43C}\u{43E}\u{441}\u{43A}\u{432}\u{430}", "2024"])
    }

    @Test func forEachWordSkipsUnicodePunctuation() {
        var words: [String] = []
        var buffer: [UInt8] = []
        TextFolding.forEachWord(in: "«Dune» 。", buffer: &buffer) { word in
            words.append(String(decoding: word, as: UTF8.self))
        }
        #expect(words == ["dune"])
    }

    @Test func naturalness() {
        #expect(TextFolding.naturalnessScore("Amélie") > TextFolding.naturalnessScore("AMELIE"))
        #expect(TextFolding.naturalnessScore("Amélie") > TextFolding.naturalnessScore("Amelie"))
        #expect(TextFolding.naturalnessScore("The Bear") > TextFolding.naturalnessScore("the bear"))
    }

    @Test func safeFileNames() {
        #expect(SafeFileName.make("abc-123") == "abc-123")
        let weird = SafeFileName.make("a/b:c")
        #expect(!weird.contains("/") && !weird.contains(":"))
        #expect(weird != SafeFileName.make("a_b_c"))
        let long = String(repeating: "x", count: 300)
        #expect(SafeFileName.make(long).count < 120)
        #expect(SafeFileName.make(long) != SafeFileName.make(long + "y"))
        #expect(SafeFileName.make(".hidden").hasPrefix("_"))
    }
}
