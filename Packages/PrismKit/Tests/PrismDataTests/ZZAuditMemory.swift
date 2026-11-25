import Foundation
import Testing
@testable import PrismData
import PrismCore

/// Temporary memory audit: loads the *installed* app's caches (read-only) and reports
/// physical footprint after every stage, plus per-kind catalog breakdowns.
/// Run alone: `ZZAUDIT=1 swift test --filter ZZAuditMemory`.
@Suite("ZZ memory audit", .disabled(if: ProcessInfo.processInfo.environment["ZZAUDIT"] == nil))
struct ZZAuditMemory {
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    static func mark(_ label: String, _ extra: String = "") {
        let relief = malloc_zone_pressure_relief(nil, 0)
        print(String(format: "ZZAUDIT %-46@ footprint %7.1f MB  (relief %.1f MB) %@", label, footprintMB(), Double(relief) / 1_048_576, extra))
    }

    @Test func auditInstalledCaches() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let container = home.appending(path: "Library/Containers/app.prism.Prism/Data/Library", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: container.path(percentEncoded: false)) else {
            Issue.record("installed container not found")
            return
        }
        let directories = AppDirectories(
            root: container.appending(path: "Application Support/Prism", directoryHint: .isDirectory),
            caches: container.appending(path: "Caches/Prism", directoryHint: .isDirectory)
        )
        Self.mark("baseline")

        let sources = SourceStore(directories: directories).load()
        Self.mark("after SourceStore.load", "\(sources.count) sources")

        // ---- Catalogs -------------------------------------------------------
        let cache = CatalogCache(directories: directories)
        var sourceCatalogs: [SourceID: SourceCatalog] = [:]
        for source in sources {
            guard let catalog = await cache.load(source.id) else { continue }
            sourceCatalogs[catalog.sourceID] = catalog
            Self.mark("catalog load \(source.id.rawValue.prefix(8))",
                      "\(catalog.channels.count)ch \(catalog.movies.count)mv \(catalog.series.count)sr")
        }
        var catalogs = sources.compactMap { sourceCatalogs[$0.id] }
        Self.mark("all SourceCatalogs retained (dict + array)")

        // ---- Merged catalog -------------------------------------------------
        let buildStart = Date()
        let catalog = await CatalogBuilder.build(sources: sources, catalogs: catalogs, options: .init(hideAdult: true))
        Self.mark("after CatalogBuilder.build (source catalogs retained)",
                  "\(catalog.movies.count)mv \(catalog.series.count)sr \(catalog.channels.count)ch in \(Int(Date().timeIntervalSince(buildStart) * 1000))ms")
        var variantCount = 0
        for t in catalog.movies { variantCount += t.variants.count }
        for t in catalog.series { variantCount += t.variants.count }
        for g in catalog.channels { variantCount += g.variants.count }
        print("ZZAUDIT variants total: \(variantCount); titles \(catalog.movies.count + catalog.series.count + catalog.channels.count)")

        // Now drop BOTH references to the source catalogs (array + dict).
        catalogs = []
        sourceCatalogs = [:]
        Self.mark("after source catalogs fully released")

        // ---- Recommendations ------------------------------------------------
        let recStart = Date()
        let recommendations = await RecommendationBuilder.build(for: catalog)
        Self.mark("after RecommendationBuilder.build", "\(Int(Date().timeIntervalSince(recStart) * 1000))ms")

        // ---- Search index ---------------------------------------------------
        let searchStart = Date()
        let searchIndex = await SearchIndex.build(from: catalog, recommendations: recommendations)
        Self.mark("after SearchIndex.build",
                  "entries \(searchIndex.entryCount) words \(searchIndex.wordCount) in \(Int(Date().timeIntervalSince(searchStart) * 1000))ms")
        print(String(format: "ZZAUDIT search arrays: nameBytes %d entryWords %d wordBytes %d postings %d baseScores %d",
                     searchIndex.nameBytes.count, searchIndex.entryWords.count, searchIndex.wordBytes.count,
                     searchIndex.postings.count, searchIndex.baseScores.count))

        // ---- Curation index -------------------------------------------------
        let curStart = Date()
        let curation = await CurationIndex.build(catalog: catalog, recommendations: recommendations)
        Self.mark("after CurationIndex.build", "\(Int(Date().timeIntervalSince(curStart) * 1000))ms")

        // ---- EPG ------------------------------------------------------------
        let epgCache = EPGCache(directories: directories, version: EPGCache.formatVersion)
        var guides: [EPGGuide] = []
        var rawEntries: [EPGCache.Entry] = []
        for source in sources where source.isEnabled {
            guard let entry = await epgCache.load(source.id) else { continue }
            Self.mark("EPG cache load \(source.id.rawValue.prefix(8))",
                      "\(entry.programs.count) programs \(entry.channels.count) channels")
            let guideStart = Date()
            let guide = EPGGuide(programs: entry.programs, channels: entry.channels)
            guides.append(guide)
            rawEntries.append(entry)
            Self.mark("EPGGuide built (+ raw entry retained)", "\(guide.programCount) programs, \(guide.channelCount) channels, in \(Int(Date().timeIntervalSince(guideStart) * 1000))ms")
        }
        let mergedGuide = await EPGGuide.merged(guides)
        Self.mark("EPG merged guide retained", "\(mergedGuide.programCount) programs")
        rawEntries = []
        Self.mark("after raw EPG entries released (guides + merged retained)")

        // ---- App-like retained set ------------------------------------------
        withExtendedLifetime((catalog, recommendations, searchIndex, curation, guides, mergedGuide)) {}
        Self.mark("FINAL app-like retained set (no sourceCatalogs)")

        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print(String(format: "ZZAUDIT max RSS %.0f MB", Double(usage.ru_maxrss) / 1_048_576))
    }

    /// EPG in isolation: no catalog loaded, so footprint deltas are EPG-only.
    @Test func epgOnly() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let container = home.appending(path: "Library/Containers/app.prism.Prism/Data/Library", directoryHint: .isDirectory)
        let directories = AppDirectories(
            root: container.appending(path: "Application Support/Prism", directoryHint: .isDirectory),
            caches: container.appending(path: "Caches/Prism", directoryHint: .isDirectory)
        )
        Self.mark("EPG-only baseline")
        let sources = SourceStore(directories: directories).load()
        let epgCache = EPGCache(directories: directories, version: EPGCache.formatVersion)
        var guides: [EPGGuide] = []
        var entries: [EPGCache.Entry] = []
        for source in sources where source.isEnabled {
            guard let entry = await epgCache.load(source.id) else { continue }
            entries.append(entry)
            Self.mark("EPG entry decoded", "\(entry.programs.count) programs \(entry.channels.count) channels")
        }
        Self.mark("all EPG entries retained")
        for entry in entries {
            let guide = EPGGuide(programs: entry.programs, channels: entry.channels)
            guides.append(guide)
        }
        Self.mark("EPG guides built (entries + guides)")
        entries = []
        Self.mark("raw entries released, guides retained")
        let merged = await EPGGuide.merged(guides)
        Self.mark("merged guide (single-source passthrough?)", "programs \(merged.programCount) channels \(merged.channelCount)")
        withExtendedLifetime((guides, merged)) {}
        Self.mark("EPG final retained")
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print(String(format: "ZZAUDIT epg max RSS %.0f MB", Double(usage.ru_maxrss) / 1_048_576))
    }

    /// Catalog in isolation: merged catalog only, source catalogs released before measure.
    @Test func catalogOnly() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let container = home.appending(path: "Library/Containers/app.prism.Prism/Data/Library", directoryHint: .isDirectory)
        let directories = AppDirectories(
            root: container.appending(path: "Application Support/Prism", directoryHint: .isDirectory),
            caches: container.appending(path: "Caches/Prism", directoryHint: .isDirectory)
        )
        Self.mark("catalog-only baseline")
        let sources = SourceStore(directories: directories).load()
        let cache = CatalogCache(directories: directories)
        var sourceCatalogs: [SourceCatalog] = []
        for source in sources {
            if let catalog = await cache.load(source.id) { sourceCatalogs.append(catalog) }
        }
        Self.mark("source catalogs loaded", "\(sourceCatalogs.count) sources")
        let catalog = await CatalogBuilder.build(sources: sources, catalogs: sourceCatalogs, options: .init(hideAdult: true))
        Self.mark("merged catalog built (sources retained)")
        sourceCatalogs = []
        // Force allocator to settle: allocate+touch a scratch region is unreliable; rely on
        // footprint after a short delay — freed Array buffers are returned by malloc zones
        // only under pressure, so ALSO record a pressure-forced number.
        try? await Task.sleep(for: .milliseconds(500))
        Self.mark("source catalogs released (settled)")
        let recommendations = await RecommendationBuilder.build(for: catalog)
        Self.mark("recommendations built")
        let searchIndex = await SearchIndex.build(from: catalog, recommendations: recommendations)
        Self.mark("search index built", "words \(searchIndex.wordCount)")
        let curation = await CurationIndex.build(catalog: catalog, recommendations: recommendations)
        Self.mark("curation built")
        withExtendedLifetime((catalog, recommendations, searchIndex, curation)) {}
        Self.mark("catalog-only final retained")
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print(String(format: "ZZAUDIT catalog max RSS %.0f MB", Double(usage.ru_maxrss) / 1_048_576))
    }
}
