import Foundation
import PrismCore
import Testing
@testable import PrismData

/// Data-store audit against the *installed* app's real caches (read-only).
/// Run alone: `ZZAUDIT=1 swift test --filter ZZAuditStores --scratch-path .build/agent-stores`
///
/// Measures the launch-path decode costs phase by phase:
///  - catalog `.catalog` archive: file read → unpack → per-segment JSON decode →
///    TitleRefinement pass → shareRepeatedValues
///  - EPG `.epg` archive: same pipeline
///  - LibraryStore snapshot/encode cost at the persistence caps
@Suite("ZZ stores audit", .serialized, .disabled(if: ProcessInfo.processInfo.environment["ZZAUDIT"] == nil))
struct ZZAuditStores {
    static var container: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers/app.prism.Prism/Data/Library", directoryHint: .isDirectory)
    }

    static var directories: AppDirectories {
        AppDirectories(
            root: container.appending(path: "Application Support/Prism", directoryHint: .isDirectory),
            caches: container.appending(path: "Caches/Prism", directoryHint: .isDirectory)
        )
    }

    static func ms(_ since: ContinuousClock.Instant) -> Double {
        let e = ContinuousClock.now - since
        return Double(e.components.seconds) * 1_000 + Double(e.components.attoseconds) / 1e15
    }

    /// Replicates `CatalogCache.decode` but with the phases timed separately and the
    /// title-refinement step optional, so its share of decode is measurable.
    private enum Part {
        case channels([Channel])
        case movies([Movie])
        case series([Series])
    }

    @Test func catalogCacheDecodePhases() async throws {
        let sources = SourceStore(directories: Self.directories).load()
        #expect(!sources.isEmpty)
        let source = sources[0]
        let url = Self.directories.catalogCacheFile(for: source.id)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            Issue.record("no catalog cache at \(url.path)")
            return
        }
        let fileSize = (try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int) ?? 0
        print("ZZAUDIT-STORE catalog file: \(fileSize / 1_048_576) MiB")

        // 1. Cold read (mapped).
        var t = ContinuousClock.now
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        print("ZZAUDIT-STORE   read+map: \(String(format: "%.1f", Self.ms(t))) ms")

        // 2. unpack.
        t = ContinuousClock.now
        guard let unpacked = SegmentedArchive.unpack(data) else {
            Issue.record("unpack failed")
            return
        }
        let segments = unpacked.segments
        let unpackMS = Self.ms(t)
        print("ZZAUDIT-STORE   unpack: \(String(format: "%.1f", unpackMS)) ms → \(segments.count) segments, format v\(unpacked.version)")
        var tagCounts: [UInt8: Int] = [:]
        for s in segments { tagCounts[s.tag, default: 0] += 1 }
        print("ZZAUDIT-STORE   tags: \(tagCounts.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " "))")

        guard let first = segments.first else {
            Issue.record("no segments")
            return
        }
        // The phase breakdown below replicates the v1 (JSON) pipeline; on a v2 archive only
        // the production-path measurements are meaningful.
        let meta: CatalogCache.Meta?
        switch unpacked.version {
        case 1:
            meta = SegmentedArchive.decodeSegment(CatalogCache.Meta.self, from: first)
        case 2:
            meta = CatalogCache.expandedBinaryPayload(of: first).flatMap(BinaryArchive.decodeMeta)
        default:
            meta = nil
        }
        guard let meta else {
            Issue.record("meta decode failed")
            return
        }
        print("ZZAUDIT-STORE   meta: \(meta.channelCount)ch \(meta.movieCount)mv \(meta.seriesCount)sr, fetched \(meta.fetchedAt)")
        guard unpacked.version == 1 else {
            t = ContinuousClock.now
            let decodedV2 = await CatalogCache.decode(data, version: CatalogCache.formatVersion, expecting: source.id)
            print("ZZAUDIT-STORE   CatalogCache.decode total (v2 binary): \(String(format: "%.1f", Self.ms(t))) ms → \(decodedV2?.movies.count ?? -1)mv")
            t = ContinuousClock.now
            _ = await CatalogCache.decode(data, version: CatalogCache.formatVersion, expecting: source.id)
            print("ZZAUDIT-STORE   decode again (warm): \(String(format: "%.1f", Self.ms(t))) ms")
            return
        }

        // 3. Whole decode through the production path (includes refine + share).
        t = ContinuousClock.now
        let decoded = await CatalogCache.decode(data, version: CatalogCache.formatVersion, expecting: source.id)
        let fullMS = Self.ms(t)
        guard let catalog = decoded else {
            Issue.record("decode returned nil")
            return
        }
        print("ZZAUDIT-STORE   CatalogCache.decode total: \(String(format: "%.1f", fullMS)) ms")
        print("ZZAUDIT-STORE   → \(catalog.channels.count)ch \(catalog.movies.count)mv \(catalog.series.count)sr")

        // 4. Same pipeline without the refinement pass, to isolate it.
        t = ContinuousClock.now
        let empty = SourceCatalog(sourceID: meta.sourceID, categories: meta.categories, account: meta.account, fetchedAt: meta.fetchedAt)
        let noRefine = await SegmentedArchive.decodeChunks(segments.dropFirst(), into: empty, decode: { segment -> Part? in
            switch segment.tag {
            case 1: return SegmentedArchive.decodeSegment([Channel].self, from: segment).map(Part.channels)
            case 2: return SegmentedArchive.decodeSegment([Movie].self, from: segment).map(Part.movies)
            case 3: return SegmentedArchive.decodeSegment([Series].self, from: segment).map(Part.series)
            default: return nil
            }
        }, append: { catalog, part in
            switch part {
            case .channels(let v): catalog.channels += v
            case .movies(let v): catalog.movies += v
            case .series(let v): catalog.series += v
            }
        })
        let decodeOnlyMS = Self.ms(t)
        guard let raw = noRefine else {
            Issue.record("no-refine decode returned nil")
            return
        }
        print("ZZAUDIT-STORE   decode (no refine, no share): \(String(format: "%.1f", decodeOnlyMS)) ms → \(raw.movies.count)mv \(raw.series.count)sr")

        // 5. Refinement alone on the decoded titles (single-threaded baseline).
        t = ContinuousClock.now
        var refinedCount = 0
        for i in raw.movies.indices {
            let r = TitleRefinement.refine(raw.movies[i].title)
            if r != raw.movies[i].title { refinedCount += 1 }
        }
        for i in raw.series.indices {
            let r = TitleRefinement.refine(raw.series[i].title)
            if r != raw.series[i].title { refinedCount += 1 }
        }
        print("ZZAUDIT-STORE   TitleRefinement serial over \(raw.movies.count + raw.series.count) titles: \(String(format: "%.1f", Self.ms(t))) ms (\(refinedCount) changed)")

        // 5b. Decode WITH the production refinement pass (parallel, like decodePart).
        t = ContinuousClock.now
        let withRefine = await SegmentedArchive.decodeChunks(segments.dropFirst(), into: empty, decode: { segment -> Part? in
            switch segment.tag {
            case 1: return SegmentedArchive.decodeSegment([Channel].self, from: segment).map(Part.channels)
            case 2:
                guard var movies = SegmentedArchive.decodeSegment([Movie].self, from: segment) else { return nil }
                for i in movies.indices {
                    let r = TitleRefinement.refine(movies[i].title)
                    if r != movies[i].title { movies[i].title = r }
                }
                return .movies(movies)
            case 3:
                guard var series = SegmentedArchive.decodeSegment([Series].self, from: segment) else { return nil }
                for i in series.indices {
                    let r = TitleRefinement.refine(series[i].title)
                    if r != series[i].title { series[i].title = r }
                }
                return .series(series)
            default: return nil
            }
        }, append: { catalog, part in
            switch part {
            case .channels(let v): catalog.channels += v
            case .movies(let v): catalog.movies += v
            case .series(let v): catalog.series += v
            }
        })
        print("ZZAUDIT-STORE   decodeChunks+refine (parallel): \(String(format: "%.1f", Self.ms(t))) ms (\(withRefine == nil ? "nil" : "ok"))")

        // 6. shareRepeatedValues alone (re-run on the decoded catalog).
        t = ContinuousClock.now
        var shared = catalog
        shared.shareRepeatedValues()
        print("ZZAUDIT-STORE   shareRepeatedValues: \(String(format: "%.1f", Self.ms(t))) ms")

        // 7. Second decode of the same data — is anything lazily warmed?
        t = ContinuousClock.now
        _ = await CatalogCache.decode(data, version: CatalogCache.formatVersion, expecting: source.id)
        print("ZZAUDIT-STORE   decode again (warm): \(String(format: "%.1f", Self.ms(t))) ms")

        // 8. Flagged round-trip: re-encode the decoded catalog (titles already refined,
        //    flag written) then decode — measures the steady-state launch path.
        t = ContinuousClock.now
        let reencoded = try await CatalogCache.encode(catalog, version: CatalogCache.formatVersion)
        print("ZZAUDIT-STORE   encode (flagged): \(String(format: "%.1f", Self.ms(t))) ms → \(reencoded.count / 1_048_576) MiB")
        t = ContinuousClock.now
        let flagged = await CatalogCache.decode(reencoded, version: CatalogCache.formatVersion, expecting: source.id)
        print("ZZAUDIT-STORE   decode (flagged, skips refine): \(String(format: "%.1f", Self.ms(t))) ms → \(flagged?.movies.count ?? -1)mv")

        withExtendedLifetime((catalog, raw, shared, flagged)) {}
    }

    @Test func epgCacheDecodePhases() async throws {
        let sources = SourceStore(directories: Self.directories).load()
        let source = sources.first(where: \.isEnabled) ?? sources[0]
        let url = Self.directories.epgCacheFile(for: source.id)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            Issue.record("no EPG cache at \(url.path)")
            return
        }
        let fileSize = (try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int) ?? 0
        print("ZZAUDIT-STORE epg file: \(fileSize / 1_048_576) MiB")

        var t = ContinuousClock.now
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        print("ZZAUDIT-STORE   read+map: \(String(format: "%.1f", Self.ms(t))) ms")

        t = ContinuousClock.now
        guard let segments = SegmentedArchive.unpack(data, version: EPGCache.formatVersion),
              let first = segments.first,
              let meta = SegmentedArchive.decodeSegment(EPGCache.Meta.self, from: first) else {
            Issue.record("epg unpack/meta failed")
            return
        }
        print("ZZAUDIT-STORE   unpack+meta: \(String(format: "%.1f", Self.ms(t))) ms → \(segments.count - 1) program segments, \(meta.programCount) programmes, \(meta.channels.count) channels")

        t = ContinuousClock.now
        let programs = await SegmentedArchive.decodeChunks(segments.dropFirst(), into: [EPGProgram](), decode: { segment in
            guard segment.tag == 1 else { return nil }
            return SegmentedArchive.decodeSegment([EPGProgram].self, from: segment)
        }, append: { $0 += $1 })
        print("ZZAUDIT-STORE   decodeChunks: \(String(format: "%.1f", Self.ms(t))) ms → \(programs?.count ?? -1) programmes")

        t = ContinuousClock.now
        let guide = EPGGuide(programs: programs ?? [], channels: meta.channels.map { XMLTVChannel(id: $0.id, displayNames: $0.displayNames, iconURL: $0.iconURL) })
        print("ZZAUDIT-STORE   EPGGuide build: \(String(format: "%.1f", Self.ms(t))) ms → \(guide.channelCount) channels")

        t = ContinuousClock.now
        let entry = await EPGCache(directories: Self.directories).load(source.id)
        print("ZZAUDIT-STORE   EPGCache.load total: \(String(format: "%.1f", Self.ms(t))) ms → \(entry?.programs.count ?? -1) programmes")
        withExtendedLifetime(guide) {}
    }

    /// LibraryStore persistence cost at the caps (progress 3 000, watched 20 000).
    @MainActor
    @Test func libraryStoreSaveCost() async throws {
        let store = LibraryStore.inMemory()
        var rng = SplitMix64(seed: 3)
        // Fill to caps.
        for i in 0..<LibraryStore.maxProgressEntries {
            let id = ContentID(source: "src", kind: .movie, nativeID: "m\(i)")
            store.updateProgress(PlaybackProgress(
                contentID: id, titleID: TitleID(rawValue: "movie:t\(i % 500)"),
                position: Double(i % 1_000), duration: 7_200,
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(i))
            ))
            if i % 15 == 0 { store.markWatched(id, titleID: nil) }
        }
        for i in 0..<LibraryStore.maxWatched {
            store.markWatched(ContentID(source: "src", kind: .movie, nativeID: "w\(i)"), titleID: nil)
        }
        _ = rng.next()

        // snapshot() is private; measure the pieces it composes: the collection copies
        // plus the LibraryFile encode (what LibraryWriter.writeNow pays per flush).
        var t = ContinuousClock.now
        let progressValues = Array(store.progress.values)
        let watchedValues = Array(store.watched)
        let file = LibraryFile(
            watchlist: store.watchlist, favoriteChannels: store.favoriteChannels,
            progress: progressValues, watched: watchedValues, history: store.history,
            preferredVariants: [], preferredChannelVariants: [],
            lastChannelGroupID: nil, dismissed: store.dismissed
        )
        print("ZZAUDIT-STORE library snapshot copies: \(String(format: "%.2f", Self.ms(t))) ms (\(progressValues.count) progress, \(watchedValues.count) watched)")

        t = ContinuousClock.now
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)
        print("ZZAUDIT-STORE library.json encode: \(String(format: "%.2f", Self.ms(t))) ms → \(data.count / 1_048_576) MiB")

        // continueWatching at cap.
        // (catalog lookups need a real Catalog; use .empty to measure the library-side scan.)
        t = ContinuousClock.now
        _ = store.continueWatching(in: .empty, limit: 20)
        print("ZZAUDIT-STORE continueWatching (empty catalog): \(String(format: "%.2f", Self.ms(t))) ms")
    }
}
