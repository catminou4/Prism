import CoreGraphics
import Foundation
import Testing

@testable import PrismPlayer

@Suite struct PlayerFormatTests {
    @Test(arguments: [
        (0.0, "00:00"), (27, "00:27"), (27.9, "00:27"), (59, "00:59"), (60, "01:00"), (725, "12:05"),
        (3599, "59:59"), (3600, "1:00:00"), (3723, "1:02:03"), (36_000, "10:00:00"), (-5, "00:00"),
        (.nan, "00:00"), (.infinity, "00:00"),
    ])
    func timecode(_ seconds: Double, _ expected: String) {
        #expect(PlayerFormat.timecode(seconds) == expected)
    }

    @Test func timecodeForcedHours() {
        #expect(PlayerFormat.timecode(27, forceHours: true) == "0:00:27")
    }

    @Test func remaining() {
        #expect(PlayerFormat.remaining(current: 27, duration: 156) == "-02:09")
        #expect(PlayerFormat.remaining(current: 27.4, duration: 156) == "-02:09")
        #expect(PlayerFormat.remaining(current: 200, duration: 156) == "-00:00")
        #expect(PlayerFormat.remaining(current: 10, duration: 5_400) == "-1:29:50")
        #expect(PlayerFormat.remaining(current: 0, duration: 3_600) == "-1:00:00")
    }

    @Test(arguments: [
        (3_420.0, "57 min"), (5_700, "1 h 35 min"), (7_200, "2 h"), (45, "1 min"), (0, "0 min"),
        (3_590, "1 h"), (.nan, "0 min"),
    ])
    func durationLabel(_ seconds: Double, _ expected: String) {
        #expect(PlayerFormat.durationLabel(seconds: seconds) == expected)
    }

    @Test func miscLabels() {
        #expect(PlayerFormat.skipLabel(10) == "+10 s")
        #expect(PlayerFormat.skipLabel(-10) == "−10 s")
        #expect(PlayerFormat.rateLabel(1) == "1×")
        #expect(PlayerFormat.rateLabel(1.5) == "1,5×")
        #expect(PlayerFormat.rateLabel(0.75) == "0,75×")
        #expect(PlayerFormat.bitrate(4_200_000) == "4,2 Mb/s")
        #expect(PlayerFormat.bitrate(850_000) == "850 kb/s")
        #expect(PlayerFormat.resolution(CGSize(width: 1920, height: 1080)) == "1920 × 1080")
        #expect(PlayerFormat.frameRate(25) == "25")
        #expect(PlayerFormat.frameRate(29.97) == "29,97")
    }
}
