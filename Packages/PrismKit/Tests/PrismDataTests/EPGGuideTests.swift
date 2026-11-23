import Foundation
import PrismCore
import Testing
@testable import PrismData

@Suite("EPGGuide")
struct EPGGuideTests {
    typealias F = Fixture

    func minutes(_ m: Int) -> Date { F.reference.addingTimeInterval(TimeInterval(m * 60)) }

    var guide: EPGGuide {
        EPGGuide(programs: [
            F.program("TF1.fr", 120, 180, "C"),
            F.program("TF1.fr", 0, 60, "A"),
            F.program("TF1.fr", 60, 120, "B"),
            F.program("TF1.fr", 240, 300, "E"), // gap 180…240
        ])
    }

    @Test func binarySearchBoundaries() {
        let guide = self.guide
        #expect(guide.programs(forEPGID: "tf1.fr", in: DateInterval(start: minutes(60), end: minutes(120))).map(\.title) == ["B"])
        #expect(guide.programs(forEPGID: "TF1.FR", in: DateInterval(start: minutes(30), end: minutes(90))).map(\.title) == ["A", "B"])
        #expect(guide.programs(forEPGID: "tf1.fr", in: DateInterval(start: minutes(-100), end: minutes(1_000))).map(\.title) == ["A", "B", "C", "E"])
        #expect(guide.programs(forEPGID: "tf1.fr", in: DateInterval(start: minutes(180), end: minutes(240))).isEmpty)
        #expect(guide.programs(forEPGID: "tf1.fr", in: DateInterval(start: minutes(300), end: minutes(400))).isEmpty)
        #expect(guide.programs(forEPGID: "unknown", in: DateInterval(start: minutes(0), end: minutes(400))).isEmpty)
        #expect(guide.channelCount == 1)
        #expect(guide.programCount == 4)
    }

    @Test func nowAndNext() {
        let guide = self.guide
        var result = guide.nowAndNext(forEPGID: "tf1.fr", at: minutes(60))
        #expect(result.now?.title == "B")
        #expect(result.next?.title == "C")
        result = guide.nowAndNext(forEPGID: "tf1.fr", at: minutes(60).addingTimeInterval(-1))
        #expect(result.now?.title == "A")
        result = guide.nowAndNext(forEPGID: "tf1.fr", at: minutes(-10))
        #expect(result.now == nil)
        #expect(result.next?.title == "A")
        result = guide.nowAndNext(forEPGID: "tf1.fr", at: minutes(200))
        #expect(result.now == nil, "gap")
        #expect(result.next?.title == "E")
        result = guide.nowAndNext(forEPGID: "tf1.fr", at: minutes(250))
        #expect(result.now?.title == "E")
        #expect(result.next == nil)
        result = guide.nowAndNext(forEPGID: "tf1.fr", at: minutes(300))
        #expect(result.now == nil && result.next == nil)
    }

    @Test func overlapsAndDuplicatesAreResolved() {
        let guide = EPGGuide(programs: [
            F.program("m6", 0, 60, "A"),
            F.program("m6", 0, 60, "A bis"),     // duplicate start
            F.program("m6", 50, 110, "B"),       // overlaps A → A trimmed to 50
            F.program("m6", 110, 110, "Empty"),  // zero length
            F.program("m6", 120, 100, "Broken"), // negative
            F.program("M6", 110, 170, "C"),      // same channel, other casing
        ])
        let list = guide.programs(forEPGID: "m6", in: DateInterval(start: minutes(0), end: minutes(1_000)))
        #expect(list.map(\.title) == ["A", "B", "C"])
        #expect(list[0].end == minutes(50))
        for (lhs, rhs) in zip(list, list.dropFirst()) {
            #expect(lhs.end <= rhs.start)
        }
    }

    @Test func resolveEPGID() {
        let guide = EPGGuide(
            programs: [F.program("TF1.fr", 0, 60), F.program("France2.fr", 0, 60), F.program("canalplus.fr", 0, 60)],
            channels: [
                XMLTVChannel(id: "TF1.fr", displayNames: ["TF1"]),
                XMLTVChannel(id: "France2.fr", displayNames: ["France 2 HD", "France 2"]),
                XMLTVChannel(id: "Arte.fr", displayNames: ["Arte"]), // no programmes
            ]
        )
        let withID = ChannelGroup(id: "tf1", name: "TF1", epgID: "tf1.FR", variants: [])
        #expect(guide.resolveEPGID(for: withID) == "tf1.fr")
        let byName = ChannelGroup(id: TitleNormalizer.key("France 2"), name: "France 2", variants: [])
        #expect(guide.resolveEPGID(for: byName) == "france2.fr")
        let unknownID = ChannelGroup(id: "tf1", name: "TF1", epgID: "nothing.here", variants: [])
        #expect(guide.resolveEPGID(for: unknownID) == "tf1.fr", "falls back to the name")
        var withVariant = unknownID
        withVariant.variants = [
            F.channel(F.a, "empty", "TF1", epg: "nothing.here"),
            F.channel(F.b, "guide", "TF1", epg: " France2.FR "),
        ]
        #expect(guide.resolveEPGID(for: withVariant) == "france2.fr", "prefers an ID from a variant to a name match")
        let noData = ChannelGroup(id: "arte", name: "Arte", variants: [])
        #expect(guide.resolveEPGID(for: noData) == nil)
        let byChannelID = ChannelGroup(id: TitleNormalizer.key("Canal Plus"), name: "CanalPlus", variants: [])
        #expect(guide.resolveEPGID(for: byChannelID) == "canalplus.fr", "matches the XMLTV id without its country suffix")
        #expect(EPGGuide.empty.resolveEPGID(for: withID) == nil)
    }

    @Test func nameIndexParallelOrdering() {
        // > 1 024 channels with programmes makes `makeNameIndex` take the partitioned
        // path. Contested keys must still resolve exactly like the serial version:
        // smallest channel id wins, display names before stripped ids.
        var programs: [EPGProgram] = []
        var channels: [XMLTVChannel] = []
        func add(_ id: String, names: [String] = []) {
            programs.append(F.program(id, 0, 60))
            channels.append(XMLTVChannel(id: id, displayNames: names))
        }
        // "aa-…" sorts before every filler, "zz-…" after them: the two claimants of
        // "Shared Contest" land in different partitions.
        add("zz-contest.example", names: ["Shared Contest"])
        for index in 0..<8_600 {
            add(String(format: "ch%05d.example", index), names: ["Filler \(index)"])
        }
        add("aa-contest.example", names: ["Shared Contest"])
        // Pass precedence: "Stripped Key" is claimed by a display name (pass 1) and by
        // the stripped id "stripped-key.fr" (pass 2); the display name must win.
        add("mmm-display.example", names: ["Stripped Key"])
        add("stripped-key.fr", names: ["Totally Other"])

        let guide = EPGGuide(programs: programs, channels: channels)
        #expect(guide.channelCount == programs.count)

        let shared = ChannelGroup(id: "shared", name: "Shared Contest", variants: [])
        #expect(guide.resolveEPGID(for: shared) == "aa-contest.example",
                "earliest channel id wins a contested display-name key across partitions")
        let stripped = ChannelGroup(id: "stripped", name: "Stripped Key", variants: [])
        #expect(guide.resolveEPGID(for: stripped) == "mmm-display.example",
                "display-name keys keep precedence over stripped-id keys")
        // Sanity: unique filler names still resolve.
        let filler = ChannelGroup(id: "filler", name: "Filler 42", variants: [])
        #expect(guide.resolveEPGID(for: filler) == "ch00042.example")
    }

    @Test func merging() {
        let first = EPGGuide(programs: [F.program("a", 0, 60, "A1"), F.program("b", 0, 60, "B1")])
        let second = EPGGuide(programs: [F.program("a", 0, 60, "A1 other"), F.program("a", 60, 120, "A2"), F.program("c", 0, 30, "C1")],
                              channels: [XMLTVChannel(id: "c", displayNames: ["Chaîne C"])])
        let merged = first.merging(second)
        #expect(merged.channelCount == 3)
        #expect(merged.programCount == 4)
        #expect(merged.programs(forEPGID: "a", in: DateInterval(start: minutes(0), end: minutes(200))).map(\.title) == ["A1", "A2"])
        #expect(merged.xmltvChannel(forEPGID: "C")?.displayNames == ["Chaîne C"])
        #expect(EPGGuide.empty.merging(first).programCount == 2)
        #expect(first.merging(.empty).programCount == 2)
    }
}
