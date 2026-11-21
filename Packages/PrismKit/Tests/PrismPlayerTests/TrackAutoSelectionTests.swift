import CoreGraphics
import Foundation
import Testing

@testable import PrismPlayer

@Suite struct TrackAutoSelectionTests {
    @Test(arguments: [
        ("fr", "fr"), ("fr-FR", "fr"), ("fra", "fr"), ("fre", "fr"), ("FRE", "fr"), ("VF", "fr"),
        ("VFF", "fr"), ("eng", "en"), ("en_US", "en"), ("ger", "de"), ("deu", "de"), ("spa", "es"),
        ("English", "en"), ("Français", "fr"), ("Deutsch", "de"), ("anglais", "en"),
    ])
    func normalizesLanguage(_ raw: String, _ expected: String) {
        #expect(TrackLanguage.normalizedCode(raw) == expected)
    }

    @Test(arguments: ["", "und", "   ", "Track 1", "zzz"])
    func rejectsGarbage(_ raw: String) {
        #expect(TrackLanguage.normalizedCode(raw) == nil)
    }

    @Test func findsLanguageInVLCNames() {
        #expect(TrackLanguage.codeFromName("Piste 1 - [Français]") == "fr")
        #expect(TrackLanguage.codeFromName("Track 2 - [English] - SDH") == "en")
        #expect(TrackLanguage.codeFromName("Audio 3 [fra]") == "fr")
        #expect(TrackLanguage.codeFromName("Track 1") == nil)
    }

    static let subtitles = [
        MediaTrack(id: "0", name: "English", language: "en"),
        MediaTrack(id: "1", name: "Français (forcés)", language: "fr", isForced: true),
        MediaTrack(id: "2", name: "Français SDH", language: "fr", isAccessibility: true),
        MediaTrack(id: "3", name: "Français", language: "fr"),
    ]

    @Test func prefersFullRegularTrack() {
        #expect(TrackAutoSelector.bestTrack(in: Self.subtitles, preferredLanguage: "fr")?.id == "3")
        #expect(TrackAutoSelector.bestTrack(in: Self.subtitles, preferredLanguage: "fra")?.id == "3")
        #expect(TrackAutoSelector.bestTrack(in: Self.subtitles, preferredLanguage: "en")?.id == "0")
        #expect(TrackAutoSelector.bestTrack(in: Self.subtitles, preferredLanguage: "de") == nil)
        #expect(TrackAutoSelector.bestTrack(in: Self.subtitles, preferredLanguage: nil) == nil)
    }

    @Test func fallsBackToSDHThenForced() {
        let tracks = Array(Self.subtitles.prefix(3))
        #expect(TrackAutoSelector.bestTrack(in: tracks, preferredLanguage: "fr")?.id == "2")
        let forcedOnly = [Self.subtitles[1]]
        #expect(TrackAutoSelector.bestTrack(in: forcedOnly, preferredLanguage: "fr")?.id == "1")
    }

    @Test func matchesByNameWhenLanguageMissing() {
        let tracks = [
            MediaTrack(id: "1", name: "Piste 1 - [English]"),
            MediaTrack(id: "2", name: "Piste 2 - [Français]"),
        ]
        #expect(TrackAutoSelector.audioSelection(in: tracks, preferredLanguage: "fr") == "2")
        #expect(TrackAutoSelector.audioSelection(in: tracks, preferredLanguage: "it") == nil)
    }

    @Test func subtitleDecision() {
        // Disabled → explicitly off.
        #expect(TrackAutoSelector.subtitleSelection(in: Self.subtitles, enabled: false, preferredLanguage: "fr") == .some(nil))
        // Enabled + match → that track.
        #expect(TrackAutoSelector.subtitleSelection(in: Self.subtitles, enabled: true, preferredLanguage: "fr") == .some("3"))
        // Enabled but no match → keep engine default.
        #expect(TrackAutoSelector.subtitleSelection(in: Self.subtitles, enabled: true, preferredLanguage: "ja") == nil)
    }

    @Test func vlcTrackParsing() {
        let tracks = VLCEngine.tracks(
            names: ["Disable", "Track 1 - [English]", "Track 2 - [French] - SDH"],
            indexes: [NSNumber(value: -1), NSNumber(value: 3), NSNumber(value: 5)],
            prefix: "Piste audio")
        #expect(tracks.map(\.id) == ["3", "5"])
        #expect(tracks.map(\.name) == ["English", "French - SDH"])
        #expect(tracks.map(\.language) == ["en", "fr"])
        #expect(tracks[1].isAccessibility)
        #expect(VLCEngine.ratioString(for: CGSize(width: 1920, height: 1080)) == "16:9")
        #expect(VLCEngine.ratioString(for: .zero) == nil)
    }
}
