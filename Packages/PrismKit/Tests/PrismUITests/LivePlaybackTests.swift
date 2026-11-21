import Foundation
import PrismCore
import PrismPlayer
import Testing
@testable import PrismUI

@Suite("Sources de télévision en direct")
struct LivePlaybackTests {
    @Test func aFallbackCannotSendAuthenticationToAnotherProvider() throws {
        let primary = try channel("main", "https://stream.example/main.ts", headers: ["Authorization": "Bearer secret"])
        let mirror = try channel("mirror", "https://stream.example/mirror.ts", headers: ["authorization": "Bearer secret"])
        let anotherPath = try channel("different-auth", "https://stream.example/other.ts", headers: ["Authorization": "Bearer other"])
        let anotherHost = try channel("another-host", "https://other.example/main.ts", headers: ["Authorization": "Bearer secret"])
        let group = ChannelGroup(id: "station", name: "Station", variants: [primary, mirror, anotherPath, anotherHost])
        let item = LivePlayback.makeItem(group: group, variant: primary)
        #expect(item.isLive)
        #expect(item.fallbackURLs == [mirror.streamURL])
    }

    @Test func equivalentFallbacksWithoutSensitiveHeadersCanUseASecondProvider() throws {
        let primary = try channel("main", "https://stream.example/main.ts", headers: ["User-Agent": "Prism"])
        let mirror = try channel("mirror", "https://other.example/live.m3u8", headers: ["user-agent": "Prism"])
        let group = ChannelGroup(id: "station", name: "Station", variants: [primary, mirror])
        #expect(LivePlayback.makeItem(group: group, variant: primary).fallbackURLs == [mirror.streamURL])
    }

    private func channel(_ id: String, _ url: String, headers: [String: String]) throws -> Channel {
        Channel(sourceID: SourceID(id), nativeID: "1", name: "Station", streamURL: try #require(URL(string: url)), httpHeaders: headers)
    }
}
