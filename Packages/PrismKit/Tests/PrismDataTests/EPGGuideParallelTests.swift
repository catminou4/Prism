import Foundation
import PrismCore
import Testing
@testable import PrismData

/// Serial reference implementation of the guide build/merge, copied phase by phase
/// from the pre-parallel implementation. The parallel `EPGGuide` must produce exactly
/// the same data for the same input.
enum EPGSerialOracle {
    /// Serial grouping: input order, first-come append, lowercased trimmed id.
    static func group(_ programs: [EPGProgram]) -> [String: [EPGProgram]] {
        var grouped: [String: [EPGProgram]] = [:]
        var keys: [String: String] = [:]
        for program in programs {
            let id: String
            if let known = keys[program.channelID] {
                id = known
            } else {
                id = program.channelID.trimmingCharacters(in: .whitespaces).lowercased()
                keys[program.channelID] = id
            }
            guard !id.isEmpty else { continue }
            grouped[id, default: []].append(program)
        }
        return grouped
    }

    /// Serial per-channel normalization loop (as the pre-parallel init ran it).
    static func normalizeAll(_ grouped: [String: [EPGProgram]]) -> (programs: [String: [EPGProgram]], count: Int) {
        var cleaned: [String: [EPGProgram]] = [:]
        var count = 0
        for (id, list) in grouped {
            let normalized = EPGGuide.normalize(list)
            guard !normalized.isEmpty else { continue }
            cleaned[id] = normalized
            count += normalized.count
        }
        return (cleaned, count)
    }

    /// Serial channelsByID: first occurrence of a normalized id wins.
    static func channelsByID(_ channels: [XMLTVChannel]) -> [String: XMLTVChannel] {
        var channelsByID: [String: XMLTVChannel] = [:]
        for channel in channels {
            let id = channel.id.trimmingCharacters(in: .whitespaces).lowercased()
            guard !id.isEmpty, channelsByID[id] == nil else { continue }
            channelsByID[id] = channel
        }
        return channelsByID
    }

    /// Serial name index: sorted ids, display names first, then stripped ids filling gaps.
    static func nameIndex(programsByChannel: [String: [EPGProgram]], channelsByID: [String: XMLTVChannel]) -> [String: String] {
        let ids = programsByChannel.keys.sorted()
        var index: [String: String] = [:]
        for id in ids {
            for name in channelsByID[id]?.displayNames ?? [] {
                for key in EPGGuide.nameKeys(name) where index[key] == nil {
                    index[key] = id
                }
            }
        }
        for id in ids {
            let original = channelsByID[id]?.id ?? programsByChannel[id]?.first?.channelID ?? id
            for key in EPGGuide.nameKeys(EPGGuide.strippedChannelID(original)) where index[key] == nil {
                index[key] = id
            }
        }
        return index
    }

    /// Full serial build pipeline, returning exactly what the parallel guide stores.
    static func build(programs: [EPGProgram], channels: [XMLTVChannel]) -> (programs: [String: [EPGProgram]], channels: [String: XMLTVChannel], nameIndex: [String: String], count: Int) {
        let grouped = group(programs)
        let (cleaned, count) = normalizeAll(grouped)
        let channelsByID = channelsByID(channels)
        let index = nameIndex(programsByChannel: cleaned, channelsByID: channelsByID)
        return (cleaned, channelsByID, index, count)
    }

    /// Serial merge of already-built guides (as the pre-parallel `merged` ran it):
    /// per channel, left fold of mergeSorted+clean in guide order; earlier guides win.
    static func merge(_ guides: [EPGGuide]) -> (programs: [String: [EPGProgram]], channels: [String: XMLTVChannel], count: Int) {
        let filled = guides.filter { !$0.programsByChannel.isEmpty || !$0.channelsByID.isEmpty }
        guard filled.count > 1, let first = filled.first else {
            let guide = filled.first ?? .empty
            return (guide.programsByChannel, guide.channelsByID, guide.programCount)
        }
        var programs = first.programsByChannel
        var channels = first.channelsByID
        var count = first.programCount
        for other in filled.dropFirst() {
            for (id, list) in other.programsByChannel {
                if let existing = programs[id] {
                    let merged = EPGGuide.clean(EPGGuide.mergeSorted(existing, list))
                    count += merged.count - existing.count
                    programs[id] = merged
                } else {
                    programs[id] = list
                    count += list.count
                }
            }
            for (id, channel) in other.channelsByID where channels[id] == nil {
                channels[id] = channel
            }
        }
        return (programs, channels, count)
    }
}

/// Dirty synthetic feeds for the guide tests.
enum DirtyFeed {
    /// Builds `channelCount` channels × ~`programsPerChannel` programmes with realistic dirt:
    /// duplicates, overlaps, empty/negative programmes, casing/whitespace id variants and
    /// a fraction of channels whose programmes arrive fully shuffled. Deterministic per seed.
    static func make(
        channelCount: Int,
        programsPerChannel: Int,
        seed: UInt64 = 99,
        shuffledFraction: Double = 0.3
    ) -> (programs: [EPGProgram], channels: [XMLTVChannel]) {
        var rng = SplitMix64(seed: seed)
        var programs: [EPGProgram] = []
        programs.reserveCapacity(channelCount * programsPerChannel)
        var channels: [XMLTVChannel] = []
        channels.reserveCapacity(channelCount)
        let slot: TimeInterval = 1_800
        var cursor = Fixture.reference.addingTimeInterval(-86_400 * 5)
        for c in 0..<channelCount {
            let id = String(format: "chan%05d.example.fr", c)
            // Name collisions every 257 channels exercise the contested-key path.
            let shared = c % 257 == 0
            channels.append(XMLTVChannel(
                id: id,
                displayNames: shared ? ["Chaîne Mutualisée", "Chaîne \(c)"] : ["Chaîne \(c)", "Channel \(c) HD"]
            ))
            // Variable per-channel volume (±50 %) for imbalanced parallel partitions.
            let volume = max(4, programsPerChannel + Int.random(in: -programsPerChannel / 2...programsPerChannel / 2, using: &rng))
            // A few channels are pure garbage: every programme empty/negative.
            let garbage = c % 991 == 990
            var list: [EPGProgram] = []
            list.reserveCapacity(volume)
            var start = cursor
            for p in 0..<volume {
                var end = start.addingTimeInterval(slot)
                let roll = Int.random(in: 0..<100, using: &rng)
                if garbage || roll < 2 {
                    end = start // empty (zero length)
                } else if roll < 4 {
                    end = start.addingTimeInterval(-slot) // negative duration
                } else if roll < 19 {
                    end = start.addingTimeInterval(slot * 1.5) // overlaps the next slot
                }
                // Some programmes carry a casing/whitespace variant of the channel id.
                let rawID: String = switch c % 211 {
                case 0 where p % 3 == 0: "  " + id.uppercased()
                case 1 where p % 5 == 0: id.uppercased()
                default: id
                }
                list.append(EPGProgram(
                    channelID: rawID, start: start, end: end,
                    title: "Programme \(p) chaîne \(c)",
                    category: p % 9 == 0 ? "Sport" : nil
                ))
                // ~8 % exact-start duplicates (same start, other title).
                if roll >= 19, roll < 27 {
                    list.append(EPGProgram(
                        channelID: rawID, start: start, end: end,
                        title: "Doublon \(p) chaîne \(c)"
                    ))
                }
                start = start.addingTimeInterval(slot)
            }
            // A fraction of channels arrives fully shuffled (unsorted input path).
            let shuffleRoll = Double(rng.next() % 1_000) / 1_000
            if shuffleRoll < shuffledFraction {
                list.shuffle(using: &rng)
            }
            programs.append(contentsOf: list)
            cursor = cursor.addingTimeInterval(61) // desynchronise channel grids
        }
        return (programs, channels)
    }

    /// Three guides simulating independent sources whose feeds share ~20 % of their
    /// channel ids (ids ending in 0 or 5), the rest source-specific.
    static func overlappingGuides(channelCount: Int, programsPerChannel: Int) -> [EPGGuide] {
        var guides: [EPGGuide] = []
        for source in 0..<3 {
            let (programs, channels) = make(channelCount: channelCount, programsPerChannel: programsPerChannel, seed: UInt64(5_000 + source))
            let shifted = programs.map { program -> EPGProgram in
                var copy = program
                let shared = copy.channelID.contains("0.example.fr") || copy.channelID.contains("5.example.fr")
                if !shared { copy.channelID = "s\(source)." + copy.channelID }
                return copy
            }
            let shiftedChannels = channels.map { channel -> XMLTVChannel in
                var copy = channel
                let shared = channel.id.contains("0.example.fr") || channel.id.contains("5.example.fr")
                if !shared { copy.id = "s\(source)." + channel.id }
                return copy
            }
            guides.append(EPGGuide(programs: shifted, channels: shiftedChannels))
        }
        return guides
    }
}

@Suite("EPGGuide parallel construction")
struct EPGGuideParallelTests {
    @Test func buildMatchesSerialOracle() {
        let (programs, channels) = DirtyFeed.make(channelCount: 1_500, programsPerChannel: 60)
        let oracle = EPGSerialOracle.build(programs: programs, channels: channels)
        // Repeated runs: thread scheduling must never change the output.
        for run in 0..<3 {
            let guide = EPGGuide(programs: programs, channels: channels)
            #expect(guide.programCount == oracle.count, "run \(run): programme count")
            #expect(guide.programsByChannel == oracle.programs, "run \(run): per-channel programmes")
            #expect(guide.channelsByID == oracle.channels, "run \(run): channels")
            #expect(guide.nameIndex == oracle.nameIndex, "run \(run): name index")
        }
    }

    @Test func buildMatchesSerialOracleWhenMostlyShuffled() {
        // 100 % shuffled input: every channel takes the keyed-sort path.
        let (programs, channels) = DirtyFeed.make(channelCount: 1_200, programsPerChannel: 48, seed: 7, shuffledFraction: 1.0)
        let oracle = EPGSerialOracle.build(programs: programs, channels: channels)
        let guide = EPGGuide(programs: programs, channels: channels)
        #expect(guide.programCount == oracle.count)
        #expect(guide.programsByChannel == oracle.programs)
        #expect(guide.nameIndex == oracle.nameIndex)
    }

    @Test func mergeMatchesSerialOracle() {
        let guides = DirtyFeed.overlappingGuides(channelCount: 900, programsPerChannel: 40)
        let oracle = EPGSerialOracle.merge(guides)
        for run in 0..<3 {
            let merged = EPGGuide.merged(guides)
            #expect(merged.programCount == oracle.count, "run \(run): merged count")
            #expect(merged.programsByChannel == oracle.programs, "run \(run): merged programmes")
            #expect(merged.channelsByID == oracle.channels, "run \(run): merged channels")
        }
    }

    @Test func buildMatchesSerialOracleWhenFullyInterleaved() {
        // Fully shuffled flat input: channel clusters span every grouping partition,
        // the hardest case for the partition-concatenation order in `groupPrograms`.
        var rng = SplitMix64(seed: 444)
        let (clustered, channels) = DirtyFeed.make(channelCount: 1_000, programsPerChannel: 45, seed: 17)
        let programs = clustered.shuffled(using: &rng)
        let oracle = EPGSerialOracle.build(programs: programs, channels: channels)
        for run in 0..<3 {
            let guide = EPGGuide(programs: programs, channels: channels)
            #expect(guide.programCount == oracle.count, "run \(run): programme count")
            #expect(guide.programsByChannel == oracle.programs, "run \(run): per-channel programmes")
            #expect(guide.nameIndex == oracle.nameIndex, "run \(run): name index")
        }
    }

    @Test func smallInputsStayDeterministic() {
        // Below the parallel thresholds the serial path must produce the same data as well.
        let (programs, channels) = DirtyFeed.make(channelCount: 60, programsPerChannel: 20, seed: 31)
        let oracle = EPGSerialOracle.build(programs: programs, channels: channels)
        let guide = EPGGuide(programs: programs, channels: channels)
        #expect(guide.programsByChannel == oracle.programs)
        #expect(guide.nameIndex == oracle.nameIndex)
        #expect(guide.programCount == oracle.count)
    }
}

/// Wall-clock comparison of the serial reference against the parallel implementation.
/// Serialized: parallel timing runs would otherwise compete for the same cores.
@Suite("EPGGuide parallel timings", .serialized)
struct EPGGuideParallelTimingTests {
    @Test func parallelVsSerialBuildTimings() async {
        let (programs, channels) = DirtyFeed.make(channelCount: 3_000, programsPerChannel: 100)
        print("EPGGuideParallel input: \(programs.count) programmes, \(channels.count) channels")
        // Warm-up both paths.
        _ = EPGSerialOracle.build(programs: programs, channels: channels)
        _ = EPGGuide(programs: programs, channels: channels)

        var serialBest = Double.infinity
        var parallelBest = Double.infinity
        var serialTimes: [Double] = []
        var parallelTimes: [Double] = []
        for _ in 0..<3 {
            let (_, serialMs) = await measureMilliseconds {
                EPGSerialOracle.build(programs: programs, channels: channels)
            }
            let (guide, parallelMs) = await measureMilliseconds {
                EPGGuide(programs: programs, channels: channels)
            }
            #expect(guide.programCount > 0)
            serialTimes.append(serialMs)
            parallelTimes.append(parallelMs)
            serialBest = min(serialBest, serialMs)
            parallelBest = min(parallelBest, parallelMs)
        }
        print(String(format: "EPGGuideParallel build 3k×100 serial:   best %.1f ms  all %@", serialBest, serialTimes.map { String(format: "%.1f", $0) }))
        print(String(format: "EPGGuideParallel build 3k×100 parallel: best %.1f ms  all %@", parallelBest, parallelTimes.map { String(format: "%.1f", $0) }))
        print(String(format: "EPGGuideParallel speedup: %.2f×", serialBest / parallelBest))
    }

    @Test func parallelVsSerialMergeTimings() async {
        let guides = DirtyFeed.overlappingGuides(channelCount: 2_000, programsPerChannel: 80)
        // The serial reference merges like the pre-parallel implementation, then builds
        // the name index serially — the same total work `EPGGuide.merged` performs.
        func serialMerge() -> Int {
            let oracle = EPGSerialOracle.merge(guides)
            let index = EPGSerialOracle.nameIndex(programsByChannel: oracle.programs, channelsByID: oracle.channels)
            return oracle.count + index.count
        }
        _ = serialMerge()
        _ = EPGGuide.merged(guides)
        var serialBest = Double.infinity
        var parallelBest = Double.infinity
        for _ in 0..<3 {
            let (_, serialMs) = await measureMilliseconds { serialMerge() }
            let (merged, parallelMs) = await measureMilliseconds { EPGGuide.merged(guides) }
            #expect(merged.programCount > 0)
            serialBest = min(serialBest, serialMs)
            parallelBest = min(parallelBest, parallelMs)
        }
        print(String(format: "EPGGuideParallel merge 3×(2k×80) serial:   best %.1f ms", serialBest))
        print(String(format: "EPGGuideParallel merge 3×(2k×80) parallel: best %.1f ms", parallelBest))
        print(String(format: "EPGGuideParallel merge speedup: %.2f×", serialBest / parallelBest))
    }
}
