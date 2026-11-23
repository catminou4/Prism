import Foundation
import PrismCore
import Testing
@testable import PrismData

/// Live TV surface audit against the *installed* app's real caches (read-only).
/// Run alone: `ZZAUDIT=1 swift test --filter ZZAuditLive --scratch-path .build/agent-audit-live`
///
/// Covers the paths `LiveScreen`/`LiveGuide` exercise per frame:
///  - `Catalog.channels(in:)` materialization for category filtering
///  - the `filteredChannels` scan (replicated verbatim from LiveScreen.swift:362-391)
///  - `EPGGuide.resolveEPGID` / `nowAndNext` / `programs(forEPGID:in:)` per visible row
///  - `EPGGuide.merged` (the `guide = currentGuide` write after each source refresh)
///  - `LibraryStore` favourite lookups used by the tile menus
@Suite("ZZ live audit", .disabled(if: ProcessInfo.processInfo.environment["ZZAUDIT"] == nil))
struct ZZAuditLiveTests {
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

    /// Verbatim copy of `LiveScreen.filteredChannels` (LiveScreen.swift:362-391).
    /// `Filter` reduced to the fields the scan reads.
    nonisolated struct ScanRequest: Sendable {
        let category: String?
        let favorites: [String]?
        let query: String
        var isUnfiltered: Bool { category == nil && favorites == nil && query.isEmpty }
    }

    static func filteredChannels(in catalog: Catalog, request: ScanRequest) -> [ChannelGroup] {
        let channels: [ChannelGroup]
        if let favorites = request.favorites {
            channels = favorites.compactMap(catalog.channelGroup)
        } else if let categoryID = request.category, let category = catalog.categoryGroup(categoryID) {
            channels = catalog.channels(in: category)
        } else {
            channels = catalog.channels
        }
        guard !request.query.isEmpty else { return channels }
        let key = TitleNormalizer.key(request.query)
        guard !key.isEmpty else { return channels }
        let terms = key.split(separator: " ")
        let number = Int(key)
        var exact: [ChannelGroup] = []
        var prefixes: [ChannelGroup] = []
        var other: [ChannelGroup] = []
        for (index, channel) in channels.enumerated() {
            if index.isMultiple(of: 256), Task.isCancelled { return [] }
            if channel.id == key || (number != nil && channel.number == number) {
                exact.append(channel)
            } else if channel.id.hasPrefix(key) {
                prefixes.append(channel)
            } else if channel.id.first != "#", terms.allSatisfy({ channel.id.contains($0) }) {
                other.append(channel)
            }
        }
        return exact + prefixes + other
    }

    @Test func liveGridAndGuideCosts() async throws {
        let sources = SourceStore(directories: Self.directories).load()
        let enabled = sources.filter(\.isEnabled)
        #expect(!enabled.isEmpty)
        print("ZZAUDIT-LIVE sources=\(sources.count) enabled=\(enabled.count)")

        // ---- Merged catalog (what AppModel.catalog holds) -------------------
        let catalogCache = CatalogCache(directories: Self.directories)
        var sourceCatalogs: [SourceID: SourceCatalog] = [:]
        for source in sources {
            if let catalog = await catalogCache.load(source.id) { sourceCatalogs[catalog.sourceID] = catalog }
        }
        let catalogs = sources.compactMap { sourceCatalogs[$0.id] }
        let (catalog, buildMS) = await measureMilliseconds {
            await CatalogBuilder.build(sources: sources, catalogs: catalogs, options: .init(hideAdult: true))
        }
        print("ZZAUDIT-LIVE catalog: \(catalog.channels.count) channel groups, \(catalog.liveCategories.count) live categories, build=\(String(format: "%.0f", buildMS))ms")

        // Variant fan-out per group (drives resolveUncached + menu cost).
        var variantTotal = 0, variantMax = 0, groupsWithVariants = 0
        for group in catalog.channels {
            variantTotal += group.variants.count
            variantMax = max(variantMax, group.variants.count)
            if group.variants.count > 1 { groupsWithVariants += 1 }
        }
        print("ZZAUDIT-LIVE variants: total=\(variantTotal) max/group=\(variantMax) multi-variant groups=\(groupsWithVariants)")

        // ---- Category materialization ---------------------------------------
        var categorySizes: [(String, Int)] = []
        for category in catalog.liveCategories {
            let (members, ms) = await measureMilliseconds { catalog.channels(in: category) }
            categorySizes.append((category.name, members.count))
            if members.count > 5_000 {
                print("ZZAUDIT-LIVE category '\(category.name)': \(members.count) channels materialized in \(String(format: "%.1f", ms))ms")
            }
        }
        categorySizes.sort { $0.1 > $1.1 }
        print("ZZAUDIT-LIVE biggest categories: \(categorySizes.prefix(8).map { "\($0.1)" }.joined(separator: ", "))")
        if let biggest = catalog.liveCategories.max(by: { $0.itemCount < $1.itemCount }) {
            let (_, ms) = await measureMilliseconds { _ = catalog.channels(in: biggest) }
            print("ZZAUDIT-LIVE largest category '\(biggest.name)' itemCount=\(biggest.itemCount): channels(in:)=\(String(format: "%.1f", ms))ms")
        }

        // ---- filteredChannels scans (the per-keystroke / per-tap path) -------
        let all = ScanRequest(category: nil, favorites: nil, query: "")
        for query in ["", "tf1", "canal", "eurosport", "beIN sport", "france", "zzzqqq", "13"] {
            let request = ScanRequest(category: nil, favorites: nil, query: query)
            let (result, ms) = await measureMilliseconds { Self.filteredChannels(in: catalog, request: request) }
            print("ZZAUDIT-LIVE filter query='\(query)': \(result.count) matches in \(String(format: "%.1f", ms))ms")
        }
        // Category-scoped query (worst realistic case: big category + text).
        if let biggest = catalog.liveCategories.max(by: { $0.itemCount < $1.itemCount }) {
            let request = ScanRequest(category: biggest.id, favorites: nil, query: "sport")
            let (result, ms) = await measureMilliseconds { Self.filteredChannels(in: catalog, request: request) }
            print("ZZAUDIT-LIVE filter category='\(biggest.name)' query='sport': \(result.count) matches in \(String(format: "%.1f", ms))ms")
        }
        // Unfiltered-but-not-all path (category only, no query) — what a chip tap pays.
        if let biggest = catalog.liveCategories.max(by: { $0.itemCount < $1.itemCount }) {
            let request = ScanRequest(category: biggest.id, favorites: nil, query: "")
            let (_, ms) = await measureMilliseconds { Self.filteredChannels(in: catalog, request: request) }
            print("ZZAUDIT-LIVE category-only '\(biggest.name)': \(String(format: "%.1f", ms))ms")
        }

        // ---- EPG guide -------------------------------------------------------
        let epgCache = EPGCache(directories: Self.directories)
        var guides: [EPGGuide] = []
        for source in enabled {
            guard let entry = await epgCache.load(source.id) else { continue }
            let (guide, ms) = await measureMilliseconds {
                await EPGRepository.makeGuide(entry.programs, channels: entry.channels)
            }
            guides.append(guide)
            print("ZZAUDIT-LIVE epg source=\(source.id.rawValue.prefix(8)): \(entry.programs.count) programs → guide channels=\(guide.channelCount) programs=\(guide.programCount) build=\(String(format: "%.0f", ms))ms")
        }
        let (merged, mergeMS) = await measureMilliseconds { await EPGGuide.merged(guides) }
        print("ZZAUDIT-LIVE merged guide: channels=\(merged.channelCount) programs=\(merged.programCount) merge=\(String(format: "%.1f", mergeMS))ms (runs on EVERY source refresh completion → 'guide =' write)")

        guard !catalog.channels.isEmpty else { return }

        // ---- Per-tile EPG lookups -------------------------------------------
        // Cold pass: every group's resolveEPGID misses ResolutionMemo once — the
        // worst case is a full scroll through the catalog or a fresh guide object
        // (each refresh builds a NEW EPGGuide → memo starts empty).
        let interval = DateInterval(start: .now.addingTimeInterval(-3_600), end: .now.addingTimeInterval(5 * 3_600))
        let now = Date.now
        var resolved = 0
        let (_, coldMS) = await measureMilliseconds {
            for group in catalog.channels {
                guard let id = merged.resolveEPGID(for: group) else { continue }
                resolved += 1
                _ = merged.nowAndNext(forEPGID: id, at: now)
                _ = merged.programs(forEPGID: id, in: interval)
            }
        }
        print("ZZAUDIT-LIVE cold resolve+nowAndNext+programs over \(catalog.channels.count) groups: \(resolved) resolved in \(String(format: "%.1f", coldMS))ms")

        // Warm pass: ResolutionMemo hits — the steady-state per-tick cost for the
        // same sweep (approximates what a 30 s LiveClock tick pays for every
        // materialized tile; only ~visible rows run it per tick in reality).
        let (_, warmMS) = await measureMilliseconds {
            for group in catalog.channels {
                guard let id = merged.resolveEPGID(for: group) else { continue }
                _ = merged.nowAndNext(forEPGID: id, at: now)
                _ = merged.programs(forEPGID: id, in: interval)
            }
        }
        print("ZZAUDIT-LIVE warm resolve+queries over \(catalog.channels.count) groups: \(String(format: "%.1f", warmMS))ms")

        // Single-tile cost (what one visible tile pays per 30 s tick).
        let sample = Array(catalog.channels.prefix(200))
        let (_, singleMS) = await measureMilliseconds {
            for _ in 0..<50 {
                for group in sample {
                    guard let id = merged.resolveEPGID(for: group) else { continue }
                    _ = merged.nowAndNext(forEPGID: id, at: now).now?.progress(at: now)
                }
            }
        }
        print("ZZAUDIT-LIVE 10k tile-lookups (200 groups × 50 ticks): \(String(format: "%.1f", singleMS))ms → ~\(String(format: "%.4f", singleMS / 10_000))ms/tile")

        // Guide-mode row cost: programs(in:) allocates per row per tick.
        let (_, rowMS) = await measureMilliseconds {
            var total = 0
            for group in catalog.channels.prefix(2_000) {
                guard let id = merged.resolveEPGID(for: group) else { continue }
                total += merged.programs(forEPGID: id, in: interval).count
            }
            return total
        }
        print("ZZAUDIT-LIVE programs(in:) 4h window × 2000 rows: \(String(format: "%.1f", rowMS))ms")

        // Resolution coverage: how many of the 55k groups actually resolve.
        var hits = 0
        for group in catalog.channels {
            if merged.resolveEPGID(for: group) != nil { hits += 1 }
        }
        print("ZZAUDIT-LIVE EPG coverage: \(hits)/\(catalog.channels.count) channel groups resolve")

        // ---- LibraryStore hot paths ------------------------------------------
        let library = await MainActor.run { LibraryStore.inMemory() }
        // Simulate max favorites (1 000 cap) in one main-actor hop.
        await MainActor.run {
            for i in 0..<1_000 { library.toggleFavorite("channel-\(i)") }
        }
        let favs = await MainActor.run { library.favoriteChannels }
        let (_, hashMS) = await measureMilliseconds { _ = favs.hashValue }
        print("ZZAUDIT-LIVE favorites.hashValue (\(favs.count) entries): \(String(format: "%.4f", hashMS))ms per LiveScreen body eval")
        let (_, containsMS) = await measureMilliseconds {
            var hits = 0
            await MainActor.run {
                for group in catalog.channels.prefix(500) { if library.isFavorite(group.id) { hits += 1 } }
            }
            return hits
        }
        print("ZZAUDIT-LIVE isFavorite ×500 (avg \(String(format: "%.4f", containsMS / 500))ms/call incl. actor hop, O(#favorites))")
    }
}
