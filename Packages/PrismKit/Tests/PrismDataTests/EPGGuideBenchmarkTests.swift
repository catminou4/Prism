import Foundation
import PrismCore
import Testing
@testable import PrismData

/// Wall-clock benchmarks for EPG guide build/merge/query on synthetic large feeds.
/// Kept as a normal (non-gated) suite: sizes are chosen so the whole suite stays
/// in the low seconds while still exposing quadratic behaviour.
@Suite("EPGGuide performance")
struct EPGGuideBenchmarkTests {
    /// Builds `channelCount` channels × `programsPerChannel` programmes spread over
    /// `days` days ending now, plus one XMLTV channel (with display names) each.
    static func makePrograms(channelCount: Int, programsPerChannel: Int, days: Int = 6) -> (programs: [EPGProgram], channels: [XMLTVChannel]) {
        let now = Date.now
        var programs: [EPGProgram] = []
        programs.reserveCapacity(channelCount * programsPerChannel)
        var channels: [XMLTVChannel] = []
        channels.reserveCapacity(channelCount)
        // ~48 slots/day (30 min each); shuffle-free deterministic interleave.
        let span = Double(days) * 86_400
        let slot = span / Double(programsPerChannel)
        for c in 0..<channelCount {
            let id = "chan\(c).example.fr"
            channels.append(XMLTVChannel(id: id, displayNames: ["Chaîne \(c)", "Channel \(c) HD"]))
            var start = now.addingTimeInterval(-span)
            for p in 0..<programsPerChannel {
                let end = start.addingTimeInterval(slot * 0.9)
                programs.append(EPGProgram(
                    channelID: id, start: start, end: end,
                    title: "Programme \(p) de la chaîne \(c)",
                    category: p % 7 == 0 ? "Sport" : "Divertissement"
                ))
                start = start.addingTimeInterval(slot)
            }
        }
        return (programs, channels)
    }

    @Test func buildGuide() async {
        let (programs, channels) = Self.makePrograms(channelCount: 5_000, programsPerChannel: 50)
        let (guide, ms) = await measureMilliseconds {
            EPGGuide(programs: programs, channels: channels)
        }
        print("EPGGuideBenchmark build 5k×50=\(programs.count) programs: \(ms) ms (channels=\(guide.channelCount))")
        #expect(guide.channelCount == 5_000)
        #expect(guide.programCount == programs.count)
    }

    @Test func buildGuideLargeChannelCount() async {
        // > 8 192 channels exercises the parallel nameIndexPass path.
        let (programs, channels) = Self.makePrograms(channelCount: 10_000, programsPerChannel: 24)
        let (guide, ms) = await measureMilliseconds {
            EPGGuide(programs: programs, channels: channels)
        }
        print("EPGGuideBenchmark build 10k×24=\(programs.count) programs: \(ms) ms (channels=\(guide.channelCount))")
        #expect(guide.channelCount == 10_000)
    }

    @Test func mergeGuides() async {
        var guides: [EPGGuide] = []
        for s in 0..<3 {
            let (programs, channels) = Self.makePrograms(channelCount: 5_000, programsPerChannel: 50)
            // Give each source distinct channel ids to simulate 3 providers.
            let shifted = programs.map { program -> EPGProgram in
                var copy = program
                copy.channelID = "s\(s)." + program.channelID
                return copy
            }
            let shiftedChannels = channels.map { channel -> XMLTVChannel in
                var copy = channel
                copy.id = "s\(s)." + channel.id
                return copy
            }
            guides.append(EPGGuide(programs: shifted, channels: shiftedChannels))
        }
        let (merged, ms) = await measureMilliseconds {
            EPGGuide.merged(guides)
        }
        print("EPGGuideBenchmark merge 3×(5k×50): \(ms) ms (channels=\(merged.channelCount), programs=\(merged.programCount))")
        #expect(merged.channelCount == 15_000)
    }

    @Test func queryAllChannels() async {
        let (programs, channels) = Self.makePrograms(channelCount: 5_000, programsPerChannel: 50)
        let guide = EPGGuide(programs: programs, channels: channels)
        // ChannelGroup per channel, epgID matching the XMLTV id.
        let groups = (0..<5_000).map { index in
            ChannelGroup(id: "group\(index)", name: "Chaîne \(index)", epgID: "chan\(index).example.fr", variants: [])
        }
        let interval = DateInterval(start: .now.addingTimeInterval(-3_600), end: .now.addingTimeInterval(3_600))
        let (_, ms) = await measureMilliseconds {
            var hits = 0
            for group in groups {
                guard let id = guide.resolveEPGID(for: group) else { continue }
                hits += guide.programs(forEPGID: id, in: interval).count
                _ = guide.nowAndNext(forEPGID: id, at: .now)
            }
            return hits
        }
        print("EPGGuideBenchmark resolve+query 5k channels: \(ms) ms")
    }

    @Test func nameResolutionMisses() async {
        // Channels whose epgID does not match: forces the name-index path per group.
        let (programs, channels) = Self.makePrograms(channelCount: 2_000, programsPerChannel: 20)
        let guide = EPGGuide(programs: programs, channels: channels)
        let groups = (0..<2_000).map { index in
            ChannelGroup(id: "g\(index)", name: "Channel \(index) HD", variants: [])
        }
        let (_, ms) = await measureMilliseconds {
            var hits = 0
            for group in groups {
                if guide.resolveEPGID(for: group) != nil { hits += 1 }
            }
            return hits
        }
        print("EPGGuideBenchmark name-miss resolve 2k channels: \(ms) ms (hits=\(groups.count))")
    }
}
