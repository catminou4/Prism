import Foundation
import PrismCore
import Testing
@testable import PrismData

/// Correctness oracle for the binary (v2) EPG cache format: exact round-trips, cross-format
/// equivalence with the JSON (v1) encoding, migration, and corruption resistance.
@Suite("Binary EPG cache")
struct BinaryEPGCacheTests {
    typealias F = Fixture

    // MARK: - Fixtures

    /// A programme with every field populated, including the awkward ones: unicode, empty
    /// strings distinct from nil, fractional sub-second dates, a multi-label category list.
    static func fullProgram(_ channel: String, _ start: Double, _ end: Double) -> EPGProgram {
        EPGProgram(
            channelID: channel,
            start: Date(timeIntervalSinceReferenceDate: start),
            end: Date(timeIntervalSinceReferenceDate: end),
            title: "Le Journal de 20h 🗞",
            subtitle: "Édition du soir — invité : un ministre",
            summary: "Toute l'actualité du jour. " + String(repeating: "Un long résumé. ", count: 20),
            category: "Journal",
            categoryLabels: ["Journal", "Information", "Actualités"],
            iconURL: URL(string: "https://img.example.com/programmes/journal-20h.jpg"),
            episodeLabel: "S2024 E315",
            rating: "Tout public",
            isNew: true
        )
    }

    /// A programme with nothing optional set: nil everywhere.
    static func bareProgram(_ channel: String, _ start: Double, _ end: Double) -> EPGProgram {
        EPGProgram(
            channelID: channel,
            start: Date(timeIntervalSinceReferenceDate: start),
            end: Date(timeIntervalSinceReferenceDate: end),
            title: ""
        )
    }

    /// An entry touching every type and every edge case at once. Programmes concentrate on
    /// few channels (as real feeds do: tens of programmes per channel id).
    static func richEntry(source: SourceID = F.a) -> EPGCache.Entry {
        let base = 817_305_875.587752
        var programs: [EPGProgram] = [
            Self.fullProgram("tf1.fr", base, base + 1_800),
            Self.fullProgram("tf1.fr", base + 1_800, base + 5_400),
            Self.bareProgram("tf1.fr", base + 5_400, base + 7_200),
            Self.fullProgram("m6.fr", base + 600, base + 2_400),
        ]
        // Empty strings must survive distinctly from nil.
        programs[1].subtitle = ""
        programs[1].summary = nil
        programs[1].categoryLabels = []
        programs[1].rating = ""
        programs[2].subtitle = nil
        var tweaked = Self.bareProgram("m6.fr", base - 3_600, base - 1_800)
        tweaked.title = "  🇫🇷 Cinéma"
        tweaked.episodeLabel = ""
        tweaked.isNew = false
        programs.append(tweaked)
        return EPGCache.Entry(
            programs: programs,
            channels: [
                XMLTVChannel(id: "tf1.fr", displayNames: ["TF1", "TF1 HD"], iconURL: URL(string: "https://logos.example.com/tf1.png")),
                XMLTVChannel(id: "m6.fr", displayNames: ["M6 🎥"], iconURL: nil),
                XMLTVChannel(id: "", displayNames: [], iconURL: URL(string: "https://logos.example.com/x.png")),
            ],
            fetchedAt: Date(timeIntervalSinceReferenceDate: base)
        )
    }

    // MARK: - Round-trip oracle

    @Test func binaryRoundTripIsExact() async throws {
        let entry = Self.richEntry()
        let data = try await EPGCache.encode(entry, for: F.a, version: 2)
        #expect(CatalogCache.embeddedVersion(of: data) == 2)
        let decoded = try #require(await EPGCache.decode(data, version: 2, expecting: F.a))
        expectEqual(decoded, entry)
    }

    @Test func binaryRoundTripEmptyEntry() async throws {
        let entry = EPGCache.Entry(programs: [], channels: [], fetchedAt: F.reference)
        let data = try await EPGCache.encode(entry, for: F.a, version: 2)
        let decoded = try #require(await EPGCache.decode(data, version: 2, expecting: F.a))
        expectEqual(decoded, entry)
    }

    /// Dates far in the past/future, fractional seconds, negative intervals, signed zero:
    /// the start/end doubles must round-trip bit for bit.
    @Test func binaryRoundTripDatesBitExact() async throws {
        let intervals: [Double] = [
            817_305_875.587752, -37_581_983.25, 0.0, -0.0, 62_135_596_800, -62_135_596_800,
            1.0 / 3.0, 5e-324, 1e300, 123_456_789.000_976_562_5,
        ]
        let programs = intervals.enumerated().map { index, interval in
            EPGProgram(
                channelID: "ch",
                start: Date(timeIntervalSinceReferenceDate: interval),
                end: Date(timeIntervalSinceReferenceDate: interval + 0.5),
                title: "P\(index)"
            )
        }
        let entry = EPGCache.Entry(programs: programs, fetchedAt: Date(timeIntervalSinceReferenceDate: -0.0))
        let data = try await EPGCache.encode(entry, for: F.a, version: 2)
        let decoded = try #require(await EPGCache.decode(data, version: 2, expecting: F.a))
        for (index, interval) in intervals.enumerated() {
            #expect(decoded.programs[index].start.timeIntervalSinceReferenceDate.bitPattern == interval.bitPattern, "start \(index)")
            #expect(decoded.programs[index].end.timeIntervalSinceReferenceDate.bitPattern == (interval + 0.5).bitPattern, "end \(index)")
        }
        #expect(decoded.fetchedAt.timeIntervalSinceReferenceDate.bitPattern == (-0.0).bitPattern, "signed zero fetchedAt")
        expectEqual(decoded, entry)
    }

    /// NaN and infinity can never come back from a v1 archive (JSON refuses them), but the
    /// binary format itself must not lose them: dates are stored as exact bit patterns.
    /// `Date` equality is useless for NaN, so the bit patterns are compared directly.
    @Test func binaryRoundTripNonFiniteDates() async throws {
        let values: [Double] = [.nan, .infinity, -.infinity]
        let programs = values.enumerated().map { index, value in
            EPGProgram(
                channelID: "ch",
                start: Date(timeIntervalSinceReferenceDate: value),
                end: Date(timeIntervalSinceReferenceDate: value),
                title: "P\(index)"
            )
        }
        let entry = EPGCache.Entry(programs: programs, fetchedAt: F.reference)
        let data = try await EPGCache.encode(entry, for: F.a, version: 2)
        let decoded = try #require(await EPGCache.decode(data, version: 2, expecting: F.a))
        for (index, value) in values.enumerated() {
            #expect(decoded.programs[index].start.timeIntervalSinceReferenceDate.bitPattern == value.bitPattern, "start \(index)")
            #expect(decoded.programs[index].end.timeIntervalSinceReferenceDate.bitPattern == value.bitPattern, "end \(index)")
        }
        #expect(decoded.programs[0].start.timeIntervalSinceReferenceDate.isNaN)
        #expect(decoded.programs[1].start.timeIntervalSinceReferenceDate == .infinity)
        #expect(decoded.programs[2].start.timeIntervalSinceReferenceDate == -.infinity)
    }

    /// Empty strings and nil are different states of the same field; both must round-trip.
    @Test func binaryRoundTripEmptyStringVersusNil() async throws {
        var a = Self.bareProgram("ch", 0, 1)
        a.subtitle = ""
        a.summary = nil
        var b = Self.bareProgram("ch", 1, 2)
        b.subtitle = nil
        b.summary = ""
        var c = Self.bareProgram("ch", 2, 3)
        c.categoryLabels = []
        var d = Self.bareProgram("ch", 3, 4)
        d.categoryLabels = [""]
        d.category = ""
        let entry = EPGCache.Entry(programs: [a, b, c, d], fetchedAt: F.reference)
        let data = try await EPGCache.encode(entry, for: F.a, version: 2)
        let decoded = try #require(await EPGCache.decode(data, version: 2, expecting: F.a))
        #expect(decoded.programs[0].subtitle == "")
        #expect(decoded.programs[0].summary == nil)
        #expect(decoded.programs[1].subtitle == nil)
        #expect(decoded.programs[1].summary == "")
        #expect(decoded.programs[2].categoryLabels == [])
        #expect(decoded.programs[3].categoryLabels == [""])
        #expect(decoded.programs[3].category == "")
        expectEqual(decoded, entry)
    }

    /// Unicode stress: emoji sequences, combining marks, RTL scripts, zero-width joiners.
    @Test func binaryRoundTripUnicode() async throws {
        let titles = ["👨‍👩‍👧‍👦 famille", "e\u{0301} combining", "برامج منوعه", "", "\u{202E}rtl override", "🏳️‍🌈"]
        let programs = titles.enumerated().map { index, title in
            EPGProgram(channelID: "chaîne-\(index).fr", start: Date(timeIntervalSinceReferenceDate: Double(index)), end: Date(timeIntervalSinceReferenceDate: Double(index) + 1), title: title)
        }
        let entry = EPGCache.Entry(
            programs: programs,
            channels: [XMLTVChannel(id: "chaîne-0.fr", displayNames: ["Chaîne zéro 🏳️‍🌈", "برامج"])],
            fetchedAt: F.reference
        )
        let data = try await EPGCache.encode(entry, for: F.a, version: 2)
        let decoded = try #require(await EPGCache.decode(data, version: 2, expecting: F.a))
        #expect(decoded.programs.map(\.title) == titles)
        expectEqual(decoded, entry)
    }

    // MARK: - Cross-format equivalence

    /// The same logical entry encoded as v1-JSON and v2-binary must decode to the exact
    /// same value — the migration is value-preserving.
    @Test func crossFormatEquivalence() async throws {
        let entry = Self.richEntry()
        let v1 = try await EPGCache.encode(entry, for: F.a, version: 1)
        let v2 = try await EPGCache.encode(entry, for: F.a, version: 2)
        #expect(CatalogCache.embeddedVersion(of: v1) == 1)
        #expect(CatalogCache.embeddedVersion(of: v2) == 2)
        let fromV1 = try #require(await EPGCache.decode(v1, version: 2, expecting: F.a))
        let fromV2 = try #require(await EPGCache.decode(v2, version: 2, expecting: F.a))
        expectEqual(fromV1, fromV2)
        // And both match the original bit for bit.
        expectEqual(fromV2, entry)
        expectEqual(fromV1, entry)
    }

    /// Migration fidelity on the exact path the app takes: decode the v1 archive, re-encode
    /// the *decoded* entry as v2, decode again — no drift.
    @Test func migrationReencodeIsStable() async throws {
        let entry = Self.richEntry()
        let v1 = try await EPGCache.encode(entry, for: F.a, version: 1)
        let migrated = try #require(await EPGCache.decode(v1, version: 2, expecting: F.a))
        let v2 = try await EPGCache.encode(migrated, for: F.a, version: 2)
        let remigrated = try #require(await EPGCache.decode(v2, version: 2, expecting: F.a))
        expectEqual(remigrated, migrated)
        let v2again = try await EPGCache.encode(remigrated, for: F.a, version: 2)
        let decodedAgain = try #require(await EPGCache.decode(v2again, version: 2, expecting: F.a))
        expectEqual(decodedAgain, migrated)
    }

    /// A v1 archive keeps decoding exactly as before even when the cache writes v2 —
    /// including through the versioned cache API the read-only harnesses use.
    @Test func legacyV1ArchiveDecodesThroughCache() async throws {
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        let entry = Self.richEntry()
        let v1 = try await EPGCache.encode(entry, for: F.a, version: 1)
        try v1.write(to: directories.epgCacheFile(for: F.a), options: [.atomic])
        let cache = EPGCache(directories: directories, version: EPGCache.formatVersion)
        let loaded = try #require(await cache.load(F.a))
        expectEqual(loaded, entry)
        #expect(await cache.fetchedAt(F.a) == entry.fetchedAt)
    }

    // MARK: - Migration through the cache

    @Test func loadMigratesV1ArchiveToV2() async throws {
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        let entry = Self.richEntry()

        // Write a v1 archive through the v1 encode path, as the old app version would have.
        let v1Data = try await EPGCache.encode(entry, for: F.a, version: 1)
        try v1Data.write(to: directories.epgCacheFile(for: F.a), options: [.atomic])

        // The production cache reads it, and migration replaces it with a v2 file.
        let cache = EPGCache(directories: directories)
        let loaded = try #require(await cache.load(F.a))
        expectEqual(loaded, entry)

        // Migration is a background task: wait for the v2 file to appear.
        let url = directories.epgCacheFile(for: F.a)
        var migratedData: Data?
        for _ in 0..<200 {
            if let data = try? Data(contentsOf: url), CatalogCache.embeddedVersion(of: data) == 2 {
                migratedData = data
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let rewritten = try #require(migratedData, "the v1 archive should be re-saved as v2 in the background")
        let reloaded = try #require(await EPGCache.decode(rewritten, version: 2, expecting: F.a))
        expectEqual(reloaded, entry)
    }

    /// A newer write must never be overwritten by a stale migration: the migration bails out
    /// when the file changed since the load.
    @Test func migrationNeverOverwritesNewerSave() async throws {
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        let original = Self.richEntry()

        let v1Data = try await EPGCache.encode(original, for: F.a, version: 1)
        try v1Data.write(to: directories.epgCacheFile(for: F.a), options: [.atomic])

        let cache = EPGCache(directories: directories)
        _ = try #require(await cache.load(F.a))

        // Race the migration: immediately overwrite with a fresher entry through save.
        var fresher = original
        fresher.programs.append(Self.bareProgram("fresh.fr", 0, 60))
        fresher.fetchedAt = Date(timeIntervalSinceReferenceDate: 999_999_999)
        try await cache.save(fresher, for: F.a)

        // Even after waiting, the on-disk entry must be the fresher one.
        try await Task.sleep(for: .milliseconds(800))
        let reloaded = try #require(await cache.load(F.a))
        #expect(reloaded.programs.count == fresher.programs.count)
        #expect(reloaded.fetchedAt == fresher.fetchedAt)
    }

    /// Read-only harnesses (the versioned init) must never write: loading a v1 archive
    /// leaves the file byte-identical.
    @Test func versionedInitNeverMigrates() async throws {
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        let entry = Self.richEntry()
        let v1Data = try await EPGCache.encode(entry, for: F.a, version: 1)
        let url = directories.epgCacheFile(for: F.a)
        try v1Data.write(to: url, options: [.atomic])

        let cache = EPGCache(directories: directories, version: EPGCache.formatVersion)
        _ = try #require(await cache.load(F.a))
        try await Task.sleep(for: .milliseconds(500))
        let after = try Data(contentsOf: url)
        #expect(after == v1Data, "the read-only harness must leave the v1 archive untouched")
    }

    /// v1 archives are *kept* by the purge (they are migratable); unknown versions are not.
    @Test func purgeKeepsMigratableVersions() async throws {
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        let directory = directories.caches.appending(path: "EPG", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let entry = EPGCache.Entry(programs: [], fetchedAt: F.reference)
        let v1 = try await EPGCache.encode(entry, for: F.a, version: 1)
        let v2 = try await EPGCache.encode(entry, for: F.a, version: 2)
        let v3 = try await EPGCache.encode(entry, for: F.a, version: 3)
        for (name, data) in [("one.epg", v1), ("two.epg", v2), ("three.epg", v3)] {
            try data.write(to: directory.appending(path: name))
        }

        await Task.detached(priority: .utility) {
            SegmentedArchive.purgeObsoleteFiles(in: directory, versions: EPGCache.readableVersions, suffix: "epg")
        }.value

        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "one.epg").path(percentEncoded: false)), "v1 is migratable: kept")
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "two.epg").path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "three.epg").path(percentEncoded: false)), "undecodable future versions are purged")
    }

    /// Future archives (written by a newer app) must be ignored, not misdecoded.
    @Test func futureVersionIsRejected() async throws {
        let entry = Self.richEntry()
        let v3 = try await EPGCache.encode(entry, for: F.a, version: 3)
        #expect(await EPGCache.decode(v3, version: 2, expecting: F.a) == nil)
        // A version-0 header is equally foreign.
        var v0 = try await EPGCache.encode(entry, for: F.a, version: 2)
        v0[4] = 0; v0[5] = 0; v0[6] = 0; v0[7] = 0
        #expect(await EPGCache.decode(v0, version: 2, expecting: F.a) == nil)
    }

    // MARK: - Corruption resistance

    @Test func truncatedPayloadsFailGracefully() async throws {
        let entry = Self.richEntry()
        let data = try await EPGCache.encode(entry, for: F.a, version: 2)
        #expect(await EPGCache.decode(data, version: 2, expecting: F.a) != nil)
        // Every truncation length must return nil without crashing — never a partial entry.
        for length in [0, 4, 8, 11, 12, 100, data.count / 2, data.count - 1] {
            #expect(await EPGCache.decode(data.prefix(length), version: 2, expecting: F.a) == nil, "truncated at \(length)")
        }
    }

    @Test func garbageBytesFailGracefully() async throws {
        var rng = SplitMix64(seed: 1)
        for _ in 0..<30 {
            let length = Int.random(in: 0...2_000, using: &rng)
            var garbage = Data(count: length)
            for index in garbage.indices { garbage[index] = UInt8(truncatingIfNeeded: rng.next()) }
            #expect(await EPGCache.decode(garbage, version: 2, expecting: F.a) == nil)
        }
    }

    /// Absurd counts and lengths inside otherwise well-formed containers must fail, not
    /// allocate: a string-length field claiming gigabytes, an item count of billions.
    @Test func absurdCountsNeverAllocate() async throws {
        // Hand-craft a binary payload: valid codec byte, then a string table count of 2^32.
        var payload = Data([BinaryArchive.codecByte])
        var count: UInt64 = 1 << 32
        while count >= 0x80 {
            payload.append(UInt8(truncatingIfNeeded: count) | 0x80)
            count >>= 7
        }
        payload.append(UInt8(truncatingIfNeeded: count))
        #expect(BinaryArchive.decodePrograms(payload) == nil)
        #expect(BinaryArchive.decodeEPGMeta(payload) == nil)

        // Valid codec byte, plausible small string count, then a string claiming 2^40 bytes.
        var crafted = Data([BinaryArchive.codecByte, 1]) // stringCount = 1
        var length: UInt64 = 1 << 40
        var encoded: [UInt8] = []
        while length >= 0x80 {
            encoded.append(UInt8(truncatingIfNeeded: length) | 0x80)
            length >>= 7
        }
        encoded.append(UInt8(truncatingIfNeeded: length))
        crafted.append(contentsOf: encoded)
        #expect(BinaryArchive.decodePrograms(crafted) == nil)
        #expect(BinaryArchive.decodeEPGMeta(crafted) == nil)
    }

    /// Truncating inside the *binary* payload specifically (after decompression) exercises
    /// the reader bounds checks rather than the container's.
    @Test func binaryPayloadTruncation() async throws {
        let programs = (0..<100).map { Self.fullProgram("ch\($0 % 3).fr", Double($0 * 60), Double($0 * 60 + 30)) }
        let payload = BinaryArchive.encodePrograms(programs[...])
        #expect(BinaryArchive.decodePrograms(payload)?.count == 100)
        for length in [1, 2, 5, payload.count / 2, payload.count - 1] {
            #expect(BinaryArchive.decodePrograms(payload.prefix(length)) == nil, "payload truncated at \(length)")
        }
    }

    /// A valid payload with trailing garbage must be rejected (the reader requires exact consumption).
    @Test func trailingGarbageIsRejected() async throws {
        let programs = [Self.fullProgram("ch.fr", 0, 60)]
        var payload = BinaryArchive.encodePrograms(programs[...])
        payload.append(0xFF)
        #expect(BinaryArchive.decodePrograms(payload) == nil)
        var metaPayload = BinaryArchive.encodeEPGMeta(EPGCache.Meta(
            sourceID: F.a,
            channels: [.init(id: "ch.fr", displayNames: ["Ch"], iconURL: nil)],
            fetchedAt: F.reference, programCount: 1
        ))
        metaPayload.append(0xFF)
        #expect(BinaryArchive.decodeEPGMeta(metaPayload) == nil)
    }

    /// Bit-flip fuzz over a valid compressed archive: corrupting anything may return nil or —
    /// for flips in inert payload bytes — an entry, but it must never crash and never block.
    @Test func bitFlipFuzzNeverCrashes() async throws {
        let entry = Self.richEntry()
        let data = try await EPGCache.encode(entry, for: F.a, version: 2)
        var rng = SplitMix64(seed: 42)
        var nilCount = 0
        var okCount = 0
        for _ in 0..<150 {
            var mutated = data
            let flips = Int.random(in: 1...3, using: &rng)
            for _ in 0..<flips {
                let position = Int.random(in: 0..<mutated.count, using: &rng)
                mutated[position] ^= UInt8(1 << Int.random(in: 0...7, using: &rng))
            }
            if await EPGCache.decode(mutated, version: 2, expecting: F.a) == nil {
                nilCount += 1
            } else {
                okCount += 1
            }
        }
        #expect(nilCount + okCount == 150)
        print("[fuzz] bit flips: \(nilCount) rejected, \(okCount) still decodable out of 150")
    }

    // MARK: - Decoded-value sharing

    /// The table encoding must give back what JSON could never provide cheaply: equal
    /// category-label lists are the same array instance after decode, and the repeated
    /// channel id is one string instance per segment.
    @Test func decodedValuesAreShared() async throws {
        let labels = ["Information", "Journal télévisé", "this-label-is-definitely-longer-than-fifteen-bytes"]
        let programs = (0..<200).map { index in
            EPGProgram(
                channelID: "a-channel-id-that-is-fairly-long.fr",
                start: Date(timeIntervalSinceReferenceDate: Double(index * 1_800)),
                end: Date(timeIntervalSinceReferenceDate: Double(index * 1_800 + 900)),
                title: "Programme \(index)", categoryLabels: labels
            )
        }
        let entry = EPGCache.Entry(programs: programs, fetchedAt: F.reference)
        let data = try await EPGCache.encode(entry, for: F.a, version: 2)
        let decoded = try #require(await EPGCache.decode(data, version: 2, expecting: F.a))
        #expect(decoded.programs.count == 200)
        let firstLabels = try #require(decoded.programs[0].categoryLabels)
        for index in 1..<200 {
            #expect(decoded.programs[index].categoryLabels == labels)
            // Unsafe identity check through withContiguousStorage — equal arrays that share
            // a buffer have the same base address.
            let same = try #require(decoded.programs[index].categoryLabels).withContiguousStorageIfAvailable { other in
                firstLabels.withContiguousStorageIfAvailable { first in
                    first.baseAddress == other.baseAddress
                }
            }
            #expect(same == true, "category-label lists should share one buffer")
        }
    }

    // MARK: - Comparison helpers

    /// Exact field-by-field comparison. The models are `Hashable`, so equality is already
    /// defined — but when a test fails, knowing *which* field drifted is the difference
    /// between minutes and hours; this helper pinpoints it.
    func expectEqual(_ lhs: EPGCache.Entry, _ rhs: EPGCache.Entry) {
        #expect(lhs.fetchedAt == rhs.fetchedAt, "fetchedAt: \(lhs.fetchedAt) vs \(rhs.fetchedAt)")
        #expect(lhs.channels == rhs.channels, "channels differ")
        #expect(lhs.programs == rhs.programs, "programs differ")
        guard lhs.channels == rhs.channels, lhs.programs == rhs.programs else {
            for (a, b) in zip(lhs.channels, rhs.channels) where a != b {
                #expect(a.id == b.id, "channel id")
                #expect(a.displayNames == b.displayNames, "channel \(a.id) displayNames")
                #expect(a.iconURL == b.iconURL, "channel \(a.id) iconURL")
                break
            }
            for (a, b) in zip(lhs.programs, rhs.programs) where a != b {
                diff(a, b)
                break
            }
            return
        }
    }

    private func diff(_ a: EPGProgram, _ b: EPGProgram) {
        #expect(a.channelID == b.channelID, "program channelID: \(a.channelID) vs \(b.channelID)")
        #expect(a.start == b.start, "program start")
        #expect(a.start.timeIntervalSinceReferenceDate.bitPattern == b.start.timeIntervalSinceReferenceDate.bitPattern, "program start bits")
        #expect(a.end == b.end, "program end")
        #expect(a.end.timeIntervalSinceReferenceDate.bitPattern == b.end.timeIntervalSinceReferenceDate.bitPattern, "program end bits")
        #expect(a.title == b.title, "program title")
        #expect(a.subtitle == b.subtitle, "program subtitle")
        #expect(a.summary == b.summary, "program summary")
        #expect(a.category == b.category, "program category")
        #expect(a.categoryLabels == b.categoryLabels, "program categoryLabels")
        #expect(a.iconURL == b.iconURL, "program iconURL")
        #expect(a.episodeLabel == b.episodeLabel, "program episodeLabel")
        #expect(a.rating == b.rating, "program rating")
        #expect(a.isNew == b.isNew, "program isNew")
    }
}
