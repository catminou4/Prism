import Foundation
import PrismCore
import Testing
@testable import PrismData

/// Measures the EPG cache decode on the real data cached by the configured app, comparing
/// the v1-JSON and v2-binary codecs over the exact same logical entry. Strictly read-only
/// on the user container: the transcoded archives live in memory, nothing is written.
/// Run with `PRISM_REAL_BENCH=1` in release mode (`swift test -c release`).
@Suite("Binary EPG bench", .serialized, .enabled(if: ProcessInfo.processInfo.environment["PRISM_REAL_BENCH"] == "1"))
struct BinaryEPGBenchTests {
    static var containerDirectories: AppDirectories {
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers/app.prism.Prism/Data/Library")
        return AppDirectories(
            root: library.appending(path: "Application Support/Prism", directoryHint: .isDirectory),
            caches: library.appending(path: "Caches/Prism", directoryHint: .isDirectory)
        )
    }

    private static func ms(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: end)
        return Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    /// Process CPU seconds (user+system) — noise-robust unlike wall time on a loaded machine:
    /// competing processes inflate wall time but not the CPU time this process actually burns.
    private static var cpuSeconds: Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    /// Alternating A/B decode measurement of the same entry encoded as v1-JSON and v2-binary.
    /// Reports minimums (least machine noise) of wall and CPU time over several rounds.
    @Test func realCacheV1VersusV2() async throws {
        let directories = Self.containerDirectories
        let store = SourceStore(directories: directories)
        let sources = store.load().filter(\.isEnabled)
        try #require(!sources.isEmpty)
        let clock = ContinuousClock()

        for source in sources {
            let url = directories.epgCacheFile(for: source.id)
            guard let onDisk = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                  let diskVersion = CatalogCache.embeddedVersion(of: onDisk) else { continue }
            // Decode whatever is on disk (either version), then produce both encodings of the
            // same logical entry in memory: the A/B comparison is perfectly controlled.
            guard let entry = await EPGCache.decode(onDisk, version: EPGCache.formatVersion, expecting: source.id) else {
                print("[epg-bench] \(source.id.rawValue.prefix(8)): no decodable cache (version \(diskVersion))")
                continue
            }
            let v1 = try await EPGCache.encode(entry, for: source.id, version: 1)
            let v2 = try await EPGCache.encode(entry, for: source.id, version: 2)
            // The oracle first: both decode back to the exact same entry.
            let fromV1 = try #require(await EPGCache.decode(v1, version: 2, expecting: source.id))
            let fromV2 = try #require(await EPGCache.decode(v2, version: 2, expecting: source.id))
            #expect(fromV1.programs == fromV2.programs)
            #expect(fromV1.programs == entry.programs)
            #expect(fromV1.channels == entry.channels)

            print("[epg-bench] \(source.id.rawValue.prefix(8)): \(entry.programs.count) programmes, \(entry.channels.count) chaînes — on disk v\(diskVersion) \(onDisk.count / 1_048_576) MiB, re-encoded v1 \(v1.count / 1_048_576) MiB vs v2 \(v2.count / 1_048_576) MiB (\(v2.count * 100 / max(v1.count, 1)) %)")

            // Encode cost, one-shot each (the migration pays the v2 one in the background).
            var start = clock.now
            _ = try await EPGCache.encode(entry, for: source.id, version: 1)
            let v1EncodeMS = Self.ms(start, clock.now)
            start = clock.now
            _ = try await EPGCache.encode(entry, for: source.id, version: 2)
            let v2EncodeMS = Self.ms(start, clock.now)
            print("[epg-bench] encode: v1 \(String(format: "%.0f", v1EncodeMS)) ms, v2 \(String(format: "%.0f", v2EncodeMS)) ms")

            // Alternating rounds: the machine noise hits both codecs evenly. Each round
            // decodes the on-disk archive too, which is what launches actually pay today.
            var wall: [String: Double] = [:]
            var cpu: [String: Double] = [:]
            let variants: [(String, Data)] = [("v1-json", v1), ("v2-binary", v2), ("on-disk-v\(diskVersion)", onDisk)]
            for round in 1...3 {
                for (label, data) in variants {
                    let cpuStart = Self.cpuSeconds
                    let wallStart = clock.now
                    let decoded = await EPGCache.decode(data, version: EPGCache.formatVersion, expecting: source.id)
                    let wallMS = Self.ms(wallStart, clock.now)
                    let cpuMS = (Self.cpuSeconds - cpuStart) * 1000
                    #expect(decoded?.programs.count == entry.programs.count)
                    wall[label] = min(wall[label] ?? .infinity, wallMS)
                    cpu[label] = min(cpu[label] ?? .infinity, cpuMS)
                    if round == 1, label.hasPrefix("v") {
                        print("[epg-bench]   round1 \(label): wall \(String(format: "%.1f", wallMS)) ms, cpu \(String(format: "%.0f", cpuMS)) ms")
                    }
                }
            }
            for (label, _) in variants {
                print("[epg-bench] best \(label): wall \(String(format: "%.1f", wall[label] ?? 0)) ms, cpu \(String(format: "%.0f", cpu[label] ?? 0)) ms")
            }
            if let wv1 = wall["v1-json"], let wv2 = wall["v2-binary"], let cv1 = cpu["v1-json"], let cv2 = cpu["v2-binary"] {
                print("[epg-bench] speedup v1→v2: wall ×\(String(format: "%.1f", wv1 / max(wv2, 0.01))), cpu ×\(String(format: "%.1f", cv1 / max(cv2, 0.01)))")
            }
        }
    }
}
