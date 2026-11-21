import Foundation
import Testing

@testable import PrismPlayer

@Suite struct EngineSelectorTests {
    nonisolated struct Case: CustomTestStringConvertible, Sendable {
        let url: String
        let hint: String?
        let expected: PlaybackEngineKind
        var testDescription: String { "\(url) [\(hint ?? "-")] → \(expected.rawValue)" }
    }

    nonisolated static let cases: [Case] = [
        Case(url: "https://cdn.example.com/live/master.m3u8", hint: nil, expected: .avFoundation),
        Case(url: "https://cdn.example.com/vod/index.M3U8?token=abc", hint: nil, expected: .avFoundation),
        Case(url: "http://host/movie/u/p/123.mp4", hint: nil, expected: .avFoundation),
        Case(url: "http://host/clip.m4v", hint: nil, expected: .avFoundation),
        Case(url: "http://host/clip.mov", hint: nil, expected: .avFoundation),
        Case(url: "http://radio.example.com/stream.mp3", hint: nil, expected: .avFoundation),
        Case(url: "http://radio.example.com/stream.aac", hint: nil, expected: .avFoundation),
        Case(url: "http://radio.example.com/stream.m4a", hint: nil, expected: .avFoundation),
        Case(url: "http://host/live/u/p/42.ts", hint: nil, expected: .vlc),
        Case(url: "http://host/movie/u/p/77.mkv", hint: nil, expected: .vlc),
        Case(url: "http://host/movie/u/p/77.avi", hint: nil, expected: .vlc),
        Case(url: "http://host/stream.flv", hint: nil, expected: .vlc),
        Case(url: "http://host/stream.wmv", hint: nil, expected: .vlc),
        Case(url: "http://host/stream.webm", hint: nil, expected: .vlc),
        Case(url: "https://host/dash/manifest.mpd", hint: nil, expected: .vlc),
        Case(url: "http://host/old.mpg", hint: nil, expected: .vlc),
        Case(url: "http://host/old.mpeg", hint: nil, expected: .vlc),
        Case(url: "rtmp://live.example.com/app/stream", hint: nil, expected: .vlc),
        Case(url: "rtsp://192.168.1.10:554/ch1", hint: nil, expected: .vlc),
        Case(url: "udp://@239.0.0.1:1234", hint: nil, expected: .vlc),
        Case(url: "rtp://239.0.0.1:5004", hint: nil, expected: .vlc),
        Case(url: "mms://media.example.com/live", hint: nil, expected: .vlc),
        // Xtream live without extension.
        Case(url: "http://provider.tv:8080/live/user/pass/12345", hint: nil, expected: .vlc),
        Case(url: "http://provider.tv:8080/user/pass/12345", hint: nil, expected: .vlc),
        // Hints win over the missing extension.
        Case(url: "http://provider.tv:8080/live/user/pass/12345", hint: "m3u8", expected: .avFoundation),
        Case(url: "http://provider.tv/play/abc", hint: "application/x-mpegURL", expected: .avFoundation),
        Case(url: "http://provider.tv/play/abc", hint: ".TS", expected: .vlc),
        Case(url: "http://provider.tv/play/abc", hint: "video/x-matroska", expected: .vlc),
        Case(url: "http://provider.tv/play/abc", hint: "video/mp4", expected: .avFoundation),
        // Query-selected container (Xtream `get.php` style).
        Case(url: "http://provider.tv/live.php?username=u&password=p&stream=1&extension=m3u8", hint: nil, expected: .avFoundation),
        Case(url: "http://provider.tv/get.php?username=u&password=p&output=ts", hint: nil, expected: .vlc),
        // Unknown → AVFoundation first (VLC is the fallback).
        Case(url: "https://example.com/watch?v=1", hint: nil, expected: .avFoundation),
        Case(url: "https://example.com/stream", hint: nil, expected: .avFoundation),
        Case(url: "file:///Users/me/Movies/film.mkv", hint: nil, expected: .vlc),
        Case(url: "file:///Users/me/Movies/film.mp4", hint: nil, expected: .avFoundation),
    ]

    @Test(arguments: cases)
    func resolvesEngine(_ testCase: Case) throws {
        let url = try #require(URL(string: testCase.url))
        #expect(EngineSelector.engine(for: url, containerHint: testCase.hint) == testCase.expected)
    }

    @Test func explicitPreferenceWins() throws {
        let item = PlaybackItem(
            id: "1", url: try #require(URL(string: "http://h/a.m3u8")), title: "A", preferredEngine: .vlc)
        #expect(EngineSelector.engine(for: item) == .vlc)
    }

    @Test func attemptPlanOrdersPrimaryOtherEngineThenFallbacks() throws {
        let primary = try #require(URL(string: "http://h/live/u/p/1.ts"))
        let fallbackHLS = try #require(URL(string: "http://h/live/u/p/1.m3u8"))
        let fallbackMKV = try #require(URL(string: "http://backup/1.mkv"))
        let item = PlaybackItem(id: "1", url: primary, fallbackURLs: [fallbackHLS, fallbackMKV], title: "A", isLive: true)
        let plan = EngineSelector.attemptPlan(for: item)
        #expect(
            plan == [
                PlaybackAttempt(url: primary, engine: .vlc),
                PlaybackAttempt(url: primary, engine: .avFoundation),
                PlaybackAttempt(url: fallbackHLS, engine: .avFoundation),
                PlaybackAttempt(url: fallbackMKV, engine: .vlc),
            ])
    }

    @Test func attemptPlanDeduplicates() throws {
        let primary = try #require(URL(string: "http://h/a.m3u8"))
        let other = try #require(URL(string: "http://h/b.m3u8"))
        let item = PlaybackItem(id: "1", url: primary, fallbackURLs: [primary, other, other], title: "A")
        let plan = EngineSelector.attemptPlan(for: item)
        #expect(
            plan == [
                PlaybackAttempt(url: primary, engine: .avFoundation),
                PlaybackAttempt(url: primary, engine: .vlc),
                PlaybackAttempt(url: other, engine: .avFoundation),
            ])
        #expect(Set(plan).count == plan.count)
        #expect(!plan.contains { $0.engine == .auto })
    }

    @Test func attemptPlanHonoursDefaultEngineOverride() throws {
        let primary = try #require(URL(string: "http://h/a.m3u8"))
        let item = PlaybackItem(id: "1", url: primary, title: "A")
        let plan = EngineSelector.attemptPlan(for: item, defaultEngine: .vlc)
        #expect(plan.map(\.engine) == [.vlc, .avFoundation])
        // An explicit item preference beats the user default.
        var explicit = item
        explicit.preferredEngine = .avFoundation
        #expect(EngineSelector.attemptPlan(for: explicit, defaultEngine: .vlc).first?.engine == .avFoundation)
    }

    @Test func playbackItemDecodesLegacyPayload() throws {
        let json = #"{"id":"x","url":"http://h/a.ts","title":"T","isLive":true}"#
        let item = try JSONDecoder().decode(PlaybackItem.self, from: Data(json.utf8))
        #expect(item.isLive)
        #expect(item.fallbackURLs.isEmpty)
        #expect(item.preferredEngine == .auto)
        #expect(item.supportsTimeshift == false)
        let roundTrip = try JSONDecoder().decode(PlaybackItem.self, from: JSONEncoder().encode(item))
        #expect(roundTrip == item)
    }
}
