import Foundation
import Testing
@testable import PrismPlayer

@Suite(.serialized)
struct HeroPreviewPlayerTests {
    @Test func startsMutedAndStopsWithoutReportingPlayback() throws {
        let factory = MockFactory()
        let item = PlaybackItem(id: "preview", url: try #require(URL(string: "https://example.com/clip.mp4")), title: "Film")
        let player = HeroPreviewPlayer(item: item, factory: factory.make, timeout: .seconds(30), duration: .seconds(30))
        player.start()
        let engine = try #require(factory.last)
        #expect(engine.isMuted)
        #expect(engine.volume == 0)
        #expect(engine.playCount == 1)
        #expect(!player.isReady)
        engine.emit(.firstFrame)
        #expect(player.isReady)
        player.toggleMute()
        #expect(!engine.isMuted)
        #expect(engine.volume == 1)
        player.stop()
        #expect(engine.isStopped)
        #expect(!player.isReady)
    }

    @Test func retriesOnceThenFinishesAndReleasesBothEngines() throws {
        let factory = MockFactory()
        let item = PlaybackItem(id: "preview", url: try #require(URL(string: "https://example.com/clip.mkv")), title: "Film")
        let player = HeroPreviewPlayer(item: item, factory: factory.make, timeout: .seconds(30), duration: .seconds(30))
        var finished = 0
        player.onFinished = { finished += 1 }
        player.start()
        let first = try #require(factory.last)
        first.emit(.failed("indisponible"))
        let second = try #require(factory.last)
        #expect(first !== second)
        #expect(first.isStopped)
        #expect(second.isMuted)
        second.emit(.failed("indisponible"))
        #expect(second.isStopped)
        #expect(finished == 1)
        player.stop()
        #expect(finished == 1)
    }

    @Test func endsAfterShortPreview() async throws {
        let factory = MockFactory()
        let item = PlaybackItem(id: "preview", url: try #require(URL(string: "https://example.com/clip.mp4")), title: "Film")
        let player = HeroPreviewPlayer(item: item, factory: factory.make, timeout: .seconds(30), duration: .milliseconds(30))
        var finished = 0
        player.onFinished = { finished += 1 }
        player.start()
        let engine = try #require(factory.last)
        engine.emit(.firstFrame)
        try await Task.sleep(for: .milliseconds(100))
        #expect(finished == 1)
        #expect(engine.isStopped)
    }

    @Test func advancingClockRevealsAnInitiallyHiddenPlayer() throws {
        let factory = MockFactory()
        let item = PlaybackItem(id: "preview", url: try #require(URL(string: "https://example.com/clip.mp4")), title: "Film")
        let player = HeroPreviewPlayer(item: item, factory: factory.make, timeout: .seconds(30), duration: .seconds(30))
        player.start()
        let engine = try #require(factory.last)
        engine.emit(.time(current: 30, buffered: 31))
        #expect(!player.isReady)
        engine.emit(.time(current: 31, buffered: 32))
        #expect(player.isReady)
        player.stop()
    }

    @Test func playsALocalVideoWithoutOpeningAPlayerWindow() async throws {
        let url = try await AVFoundationIntegrationTests.makeMovie(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = HeroPreviewPlayer(item: PlaybackItem(id: "preview", url: url, title: "Film"))
        player.start()
        let deadline = ContinuousClock.now + .seconds(8)
        while !player.isReady && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(player.isReady)
        #expect(player.isMuted)
        player.stop()
    }
}
