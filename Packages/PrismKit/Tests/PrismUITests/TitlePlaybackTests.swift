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

    @MainActor @Test func languageFiltersIncludeSharedAudioButKeepSubtitleVersionsSeparate() throws {
        let url = try #require(URL(string: "https://example.invalid/edition.mkv"))
        let source = Source(name: "Source", kind: .m3uURL)
        let tags = [["FR", "IT"], ["VFQ"], ["VOSTFR"], ["MULTI"], ["FR"], ["EN", "FR"], ["FR"]]
        let options = tags.enumerated().compactMap { index, tags in
            let variant = Movie(sourceID: source.id, nativeID: "\(index)", title: "Film", streamURL: url, tags: tags)
            return TitlePlaybackOption(edition: TitleEdition(variant: .movie(variant), source: source))
        }
        var choices = PlaybackSheetChoices(Array(options.prefix(2)))
        choices.append(options)

        let french = try #require(choices.filters.first { $0.id == "audio-FR" })
        let italian = try #require(choices.filters.first { $0.id == "audio-IT" })
        let subtitled = try #require(choices.filters.first { $0.id == "version-VOSTFR" })
        #expect(choices.filters.prefix(2).map(\.id) == ["audio-FR", "audio-EN"])
        #expect(french.title == "Français")
        #expect(choices[french].map(\.id) == [options[0].id, options[1].id, options[4].id, options[5].id, options[6].id])
        #expect(choices[italian].map(\.id) == [options[0].id])
        #expect(choices[subtitled].map(\.id) == [options[2].id])
        #expect(choices[.all].map(\.id) == options.map(\.id))
        let group = try #require(PlaybackSourceGroup.grouped(choices[french]).first)
        #expect(group.duplicateNumbers == [options[4].id: 1, options[6].id: 2])
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
        let olderLongerVersion = PlaybackProgress(contentID: movie.id, position: 5_500, duration: 6_000)

        #expect(option.resumePosition(exact: nil, equivalent: equivalent) == 1_800)
        #expect(option.resumePosition(exact: nil, equivalent: alternateCut) == nil)
        #expect(option.resumePosition(exact: completed, equivalent: equivalent) == nil)
        #expect(option.resumePosition(exact: olderLongerVersion, equivalent: equivalent) == nil)
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

    @Test func choosingAnEditionResumesItsOwnMostRecentEpisode() async throws {
        let url = try #require(URL(string: "https://example.invalid/episode.mp4"))
        let source = Source(name: "Source", kind: .m3uURL)
        let series = Series(sourceID: source.id, nativeID: "series", title: "Série")
        let episodes = (1...3).map { number in
            Episode(
                seriesID: series.id, sourceID: source.id, nativeID: "e\(number)",
                season: 1, number: number, title: "Épisode \(number)", streamURL: url
            )
        }
        let inventory = await DetailEpisodeInventory.build(
            edition: TitleEdition(variant: .series(series), source: source),
            detail: SeriesDetail(seriesID: series.id, seasons: [Season(number: 1, episodes: episodes)])
        )
        let other = PlaybackProgress(contentID: ContentID(rawValue: "another-edition"), position: 200, duration: 1_000)
        let here = PlaybackProgress(contentID: episodes[2].id, position: 300, duration: 1_000, updatedAt: .distantPast)
        let candidate = inventory.latestProgress(in: [other.contentID: other, here.contentID: here])
        #expect(candidate == here)
        #expect(inventory.nextEpisode(after: candidate, isWatched: { _ in false }) == episodes[2])
    }

    @Test func alternateEditionDiscardsWrongSourcesAndResolvesDuplicatesDeterministically() throws {
        let url = try #require(URL(string: "https://example.invalid/episode.mp4"))
        let source = Source(name: "Source", kind: .xtream)
        let series = Series(sourceID: source.id, nativeID: "series", title: "Série")
        let alternate = Series(sourceID: source.id, nativeID: "alternate", title: "Série")
        let edition = TitleEdition(variant: .series(alternate), source: source)
        let wrong = Episode(
            seriesID: series.id, sourceID: source.id, nativeID: "0", season: 1, number: 2,
            title: "Autre édition", streamURL: url
        )
        let valid = Episode(
            seriesID: alternate.id, sourceID: source.id, nativeID: "1", season: 1, number: 2,
            title: "Épisode valide", streamURL: url
        )
        let duplicate = Episode(
            seriesID: alternate.id, sourceID: source.id, nativeID: "2", season: 1, number: 2,
            title: "Doublon", streamURL: url
        )
        let detail = SeriesDetail(seriesID: alternate.id, seasons: [
            Season(number: 1, episodes: [wrong, duplicate, valid]),
        ])
        let option = AlternateEditionResolver.option(in: detail, edition: edition, coordinate: EpisodeCoordinate(wrong))
        #expect(option?.episode == valid)
    }

    @Test func alternateOptionsKeepCatalogOrderAcrossOutOfOrderResultsAndRetries() throws {
        let url = try #require(URL(string: "https://example.invalid/edition.mkv"))
        let source = Source(name: "Source", kind: .m3uURL)
        let options = (0..<5).compactMap { index in
            let movie = Movie(sourceID: source.id, nativeID: "\(index)", title: "Film", streamURL: url, tags: ["FR"])
            return TitlePlaybackOption(edition: TitleEdition(variant: .movie(movie), source: source))
        }
        let initial = Array(options.prefix(1))
        var choices = PlaybackSheetChoices(initial, followedBy: options.dropFirst().map(\.titleEdition))
        choices.append([options[3], options[1], options[4]])
        choices.append([options[2], options[3]])
        #expect(choices[.all].map(\.id) == options.map(\.id))
        let french = try #require(choices.filters.first)
        #expect(choices.section(for: french).ordered.map(\.id) == options.map(\.id))
        #expect(choices.section(for: .all).groups.first?.duplicateNumbers[options[3].id] == 4)
    }

    @MainActor @Test func closingAnEditionPickerDoesNotStartMoreProviderQueries() async throws {
        let url = try #require(URL(string: "https://example.invalid/episode.mp4"))
        let source = Source(name: "Source", kind: .xtream)
        let original = Series(sourceID: source.id, nativeID: "original", title: "Série")
        let episode = Episode(
            seriesID: original.id, sourceID: source.id, nativeID: "e1", season: 1, number: 1,
            title: "Épisode", streamURL: url
        )
        let editions = (0..<36).map { index in
            TitleEdition(
                variant: .series(Series(sourceID: source.id, nativeID: "v\(index)", title: "Série")), source: source
            )
        }
        let counter = Requests()
        var updates = 0
        await AlternateEditionResolver.resolve(editions, episode: episode, load: { series, _ in
            await counter.started()
            return SeriesDetail(seriesID: series.id)
        }) { _ in
            updates += 1
            return false
        }
        #expect(updates == 1)
        #expect(await counter.count <= 4)
    }

    private actor Requests {
        private(set) var count = 0
        func started() { count += 1 }
    }
}
