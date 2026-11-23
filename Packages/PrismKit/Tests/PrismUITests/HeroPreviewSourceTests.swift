import Foundation
import Testing
@testable import PrismUI

struct HeroPreviewSourceTests {
    @Test func choosesOnlyDirectVideoAndSkipsHostedPages() throws {
        let youtube = try #require(URL(string: "https://www.youtube.com/watch?v=123"))
        let disguised = try #require(URL(string: "https://youtube.com/example.mp4"))
        let webpage = try #require(URL(string: "https://example.com/trailer"))
        let direct = try #require(URL(string: "https://example.com/trailer.mp4?token=123"))
        #expect(HeroPreviewSource.directTrailer([youtube, disguised, webpage, direct]) == direct)
        #expect(HeroPreviewSource.directTrailer([youtube, webpage]) == nil)
    }
}
