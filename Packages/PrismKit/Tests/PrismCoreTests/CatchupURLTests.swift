import Foundation
import PrismCore
import Testing

@Suite("URLs de replay")
struct CatchupURLTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private var program: EPGProgram {
        EPGProgram(channelID: "channel", start: start, end: start.addingTimeInterval(3_701), title: "La suite")
    }

    @Test func appendsAQueryWithoutDiscardingTheSignedStreamQuery() throws {
        let channel = try channel(.init(mode: .append, days: 2, template: "?utc=${start}&end={utcend}&minutes={duration:60}"))
        let url = try #require(CatchupURL.make(channel: channel, program: program, now: program.end))
        #expect(url.absoluteString == "https://stream.example/live.m3u8?signature=a%2Bb&utc=1700000000&end=1700003701&minutes=61#video")
    }

    @Test func supportsProviderTimeZoneAndReversesGuideOffsetForXtream() throws {
        let channel = try channel(.init(mode: .xtream, days: 2))
        let credentials = XtreamCredentials(server: try #require(URL(string: "https://stream.example")), username: "user", password: "pass")
        let timeZone = try #require(TimeZone(identifier: "Europe/Paris"))
        let url = try #require(CatchupURL.make(
            channel: channel, program: program, now: program.end,
            correctingGuideBy: -3_600, xtream: credentials, timeZone: timeZone
        ))
        #expect(url.absoluteString == "https://stream.example/timeshift/user/pass/62/2023-11-14:22-13/7.ts")
    }

    @Test func rejectsCurrentExpiredAndInvalidReplayEntries() throws {
        let channel = try channel(.init(mode: .shift, days: 1))
        #expect(CatchupURL.make(channel: channel, program: program, now: start) == nil)
        #expect(CatchupURL.make(channel: channel, program: program, now: start.addingTimeInterval(86_401)) == nil)
        #expect(CatchupURL.make(channel: channel, program: program, now: start.addingTimeInterval(86_400)) != nil)
        let unknown = try self.channel(.init(mode: .default, days: 1, template: "https://stream.example/archive/{catchup-id}"))
        #expect(CatchupURL.make(channel: unknown, program: program, now: program.end) == nil)
        let local = try self.channel(.init(mode: .default, days: 1, template: "file:///tmp/archive/{utc}"))
        #expect(CatchupURL.make(channel: local, program: program, now: program.end) == nil)
    }

    private func channel(_ catchup: Catchup) throws -> Channel {
        Channel(
            sourceID: "source", nativeID: "7", name: "Chaîne",
            streamURL: try #require(URL(string: "https://stream.example/live.m3u8?signature=a%2Bb#video")),
            catchup: catchup
        )
    }
}
