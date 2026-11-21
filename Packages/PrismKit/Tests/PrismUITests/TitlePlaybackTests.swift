import Foundation
import PrismCore
import PrismPlayer
import Testing
@testable import PrismUI

@Suite("Lecture depuis une fiche")
struct TitlePlaybackTests {
    @Test func explicitEditionsTakePriorityOverProviderRegions() {
        #expect(PlaybackEdition(tags: ["FR", "VOSTFR", "HDR"]).key == "VOSTFR")
        #expect(PlaybackEdition(tags: ["EN", "VFQ"]).key == "VFQ")
        #expect(PlaybackEdition(tags: ["MULTI", "EN", "VF"]).key == "MULTI")
        #expect(PlaybackEdition(tags: ["VF"]).key == PlaybackEdition(tags: ["FRA"]).key)
        #expect(PlaybackEdition(tags: ["USA", "CA", "HDR"]).key == "unknown")
    }

    @Test func selectingAnEditionPreservesItsStreamAndHeaders() throws {
        let url = try #require(URL(string: "https://example.invalid/edition.mkv"))
        let source = Source(name: "Source", kind: .m3uURL, userAgent: "Source UA")
        let movie = Movie(
            sourceID: source.id, nativeID: "edition", title: "Film", streamURL: url,
            containerExtension: "mkv", quality: .uhd, tags: ["VOSTFR"],
            httpHeaders: ["user-agent": "Flux UA", "Referer": "https://example.invalid/"]
        )
        let title = MediaTitle(id: TitleID(rawValue: "film"), kind: .movie, title: "Film", year: nil, variants: [.movie(movie)])
        let edition = TitleEdition(variant: .movie(movie), source: source)
        let option = try #require(TitlePlaybackOption(edition: edition))
        let item = option.playbackItem(for: title, position: 420)

        #expect(option.label == "4K · MKV")
        #expect(item.url == url)
        #expect(item.startPosition == 420)
        #expect(item.httpHeaders == movie.httpHeaders)
        #expect(item.fallbackURLs.isEmpty)
        #expect(item.containerHint == "mkv")
    }

    @Test func episodesUseTheChosenProvidersUserAgentAndRejectMismatchedVariants() throws {
        let url = try #require(URL(string: "https://example.invalid/episode.m3u8"))
        let source = Source(name: "Séries", kind: .xtream, userAgent: "Xtream UA")
        let v1 = Series(sourceID: source.id, nativeID: "1", title: "Série")
        let v2 = Series(sourceID: source.id, nativeID: "2", title: "Série")
        let episode = Episode(
            seriesID: v1.id, sourceID: source.id, nativeID: "épisode", season: 1, number: 3,
            title: "Pilote", streamURL: url, containerExtension: "m3u8"
        )
        let edition = TitleEdition(variant: .series(v1), source: source)
        let valid = try #require(TitlePlaybackOption(edition: edition, episode: episode))

        #expect(valid.contentID == episode.id)
        #expect(valid.id == v1.id)
        #expect(valid.headers["User-Agent"] == "Xtream UA")
        #expect(TitlePlaybackOption(edition: TitleEdition(variant: .series(v2), source: source), episode: episode) == nil)
    }

    @Test func resumeCarriesOverOnlyBetweenComparableCuts() throws {
        let url = try #require(URL(string: "https://example.invalid/movie.mp4"))
        let source = Source(name: "Source", kind: .m3uURL)
        let movie = Movie(sourceID: source.id, nativeID: "stream", title: "Film", durationSeconds: 5_400, streamURL: url)
        let option = try #require(TitlePlaybackOption(edition: TitleEdition(variant: .movie(movie), source: source)))
        let equivalent = PlaybackProgress(contentID: movie.id, position: 1_800, duration: 5_380)
        let alternateCut = PlaybackProgress(contentID: movie.id, position: 1_800, duration: 6_000)
        let completed = PlaybackProgress(contentID: movie.id, position: 5_400, duration: 5_400)

        #expect(option.resumePosition(exact: nil, equivalent: equivalent) == 1_800)
        #expect(option.resumePosition(exact: nil, equivalent: alternateCut) == nil)
        #expect(option.resumePosition(exact: completed, equivalent: equivalent) == nil)
    }

    @Test func episodesStayOrderedAndResumeSkipsWatchedEpisodes() async throws {
        let url = try #require(URL(string: "https://example.invalid/episode.mp4"))
        let source = Source(name: "Source", kind: .m3uURL)
        let series = Series(sourceID: source.id, nativeID: "series", title: "Série")
        let episodes = [3, 1, 2, 2].map { number in
            Episode(
                seriesID: series.id, sourceID: source.id, nativeID: "e\(number)",
                season: 1, number: number, title: "Épisode \(number)", streamURL: url
            )
        }
        let inventory = await DetailEpisodeInventory.build(
            edition: TitleEdition(variant: .series(series), source: source),
            detail: SeriesDetail(seriesID: series.id, seasons: [
                Season(number: 1, episodes: Array(episodes.dropFirst())),
                Season(number: 2, episodes: []),
                Season(number: 1, episodes: Array(episodes.prefix(1))),
            ])
        )
        let completed = PlaybackProgress(contentID: episodes[1].id, position: 1_800, duration: 1_800)
        #expect(inventory.seasons.count == 1)
        #expect(inventory.orderedEpisodes.map(\.number) == [1, 2, 3])
        #expect(inventory.nextEpisode(after: completed, isWatched: { $0 == episodes[1].id || $0 == episodes[2].id })?.number == 3)
    }

    @Test func nextEpisodeCrossesSeasonsWithoutReplayingOrSwitchingEdition() async throws {
        let url = try #require(URL(string: "https://example.invalid/episode.mp4"))
        let source = Source(name: "Source", kind: .m3uURL)
        let series = Series(sourceID: source.id, nativeID: "series", title: "Série")
        let alternate = Series(sourceID: source.id, nativeID: "alternate", title: "Série")
        let first = Episode(seriesID: series.id, sourceID: source.id, nativeID: "s1e2", season: 1, number: 2,
                            title: "Finale", streamURL: url)
        let next = Episode(seriesID: series.id, sourceID: source.id, nativeID: "s2e1", season: 2, number: 1,
                           title: "Première", streamURL: url)
        let wrongEdition = Episode(seriesID: alternate.id, sourceID: source.id, nativeID: "other", season: 2, number: 1,
                                   title: "Autre version", streamURL: url)
        let inventory = await DetailEpisodeInventory.build(
            edition: TitleEdition(variant: .series(series), source: source),
            detail: SeriesDetail(seriesID: series.id, seasons: [
                Season(number: 2, episodes: [wrongEdition, next]),
                Season(number: 1, episodes: [first]),
            ])
        )

        #expect(inventory.nextAvailableEpisode(after: first.id) == next)
        #expect(inventory.nextAvailableEpisode(after: next.id) == nil)
        #expect(inventory.nextAvailableEpisode(after: wrongEdition.id) == nil)
    }
}
