import AppKit
import Foundation
import Observation
import SwiftUI
import PrismCore
import PrismData

/// App-wide state: sources, the merged catalog, the EPG guide, the search index and the
/// user's library. Heavy work (refresh, grouping, indexing) runs off the main actor in
/// PrismData; only the finished immutable snapshots are assigned here.
@MainActor
@Observable
public final class AppModel {
    public enum Phase: Equatable, Sendable {
        case launching, onboarding, ready
    }

    // MARK: Services

    @ObservationIgnored public let directories: AppDirectories
    @ObservationIgnored public let credentials: any CredentialStoring
    @ObservationIgnored public let catalogRepository: CatalogRepository
    @ObservationIgnored public let epgRepository: EPGRepository
    @ObservationIgnored public let detailRepository: DetailRepository
    @ObservationIgnored public let metadataRepository: MetadataRepository
    @ObservationIgnored private let sourceStore: SourceStore
    @ObservationIgnored private let isEphemeral: Bool
    public private(set) var library: LibraryStore

    // MARK: State

    public private(set) var phase: Phase = .launching
    public private(set) var sources: [Source] = []
    public private(set) var catalog: Catalog = .empty
    public private(set) var guide: EPGGuide = .empty
    public private(set) var searchIndex: SearchIndex?
    public private(set) var recommendations = Recommendations.empty
    /// In-flight imports/refreshes, by source.
    public private(set) var imports: [SourceID: ImportProgress] = [:]
    /// Last refresh error per source (French, user-facing).
    public private(set) var errors: [SourceID: String] = [:]
    public private(set) var accounts: [SourceID: XtreamAccount] = [:]
    public private(set) var isRefreshingGuide = false
    public private(set) var isMetadataEnabled = false
    private var hiddenCategoriesBySource: [String: [String]] = [:]
    /// Bumped every time `catalog` is replaced (cheap change token for views/tasks).
    public private(set) var catalogRevision = 0

    public var hideAdultContent: Bool {
        didSet {
            guard oldValue != hideAdultContent else { return }
            UserDefaults.standard.set(hideAdultContent, forKey: Keys.hideAdult)
            Task { await rebuild() }
        }
    }

    @ObservationIgnored private var sourceCatalogs: [SourceID: SourceCatalog] = [:]
    @ObservationIgnored private var pendingSources: Set<SourceID> = []
    @ObservationIgnored private var rebuildGeneration = 0
    @ObservationIgnored private var didBootstrap = false

    private enum Keys {
        static let hideAdult = "prism.hideAdultContent"
        static let onboardingDone = "prism.onboardingCompleted"
        static let hiddenCategories = "prism.hiddenSourceCategories"
    }

    /// Catalogs older than this are refreshed in the background at launch.
    public static let catalogMaxAge: TimeInterval = 12 * 3_600
    public static let guideMaxAge: TimeInterval = 6 * 3_600

    // MARK: Init

    public init(
        directories: AppDirectories = .standard,
        credentials: any CredentialStoring = KeychainCredentialStore(),
        library: LibraryStore? = nil,
        isEphemeral: Bool = false
    ) {
        self.directories = directories
        self.credentials = credentials
        self.isEphemeral = isEphemeral
        let cache = CatalogCache(directories: directories)
        self.catalogRepository = CatalogRepository(directories: directories, credentials: credentials, cache: cache)
        self.epgRepository = EPGRepository(directories: directories, credentials: credentials)
        self.detailRepository = DetailRepository(directories: directories, credentials: credentials)
        self.metadataRepository = MetadataRepository(directories: directories, credentials: credentials)
        self.sourceStore = SourceStore(directories: directories)
        self.library = library ?? LibraryStore(directories: directories)
        self.hideAdultContent = UserDefaults.standard.object(forKey: Keys.hideAdult) as? Bool ?? true
        if !isEphemeral {
            self.hiddenCategoriesBySource = UserDefaults.standard.dictionary(forKey: Keys.hiddenCategories) as? [String: [String]] ?? [:]
        }
    }

    /// Fully populated in-memory model for previews and offscreen snapshots.
    public static func preview() async -> AppModel {
        let model = AppModel(
            directories: .temporary("prism-preview"),
            credentials: InMemoryCredentialStore(),
            library: .inMemory(),
            isEphemeral: true
        )
        model.sources = PreviewData.sources
        for catalog in PreviewData.catalogs { model.sourceCatalogs[catalog.sourceID] = catalog }
        model.guide = PreviewData.guide
        await model.rebuild()
        model.library = PreviewData.makeLibrary(for: model.catalog)
        model.phase = .ready
        model.didBootstrap = true
        return model
    }

    // MARK: Lookups

    public func source(_ id: SourceID) -> Source? { sources.first { $0.id == id } }
    public func password(for id: SourceID) -> String? { credentials.password(for: id) }
    public func account(for id: SourceID) -> XtreamAccount? { accounts[id] }
    public func isImporting(_ id: SourceID) -> Bool { imports[id] != nil }
    public var isImportingAnything: Bool { !imports.isEmpty }
    public var hasCompletedOnboarding: Bool { UserDefaults.standard.bool(forKey: Keys.onboardingDone) }

    /// Provider categories come from the full source, including categories filtered from the library.
    public func sourceCategories(for id: SourceID) -> [PrismCore.Category] {
        _ = catalogRevision
        return sourceCatalogs[id]?.categories ?? []
    }

    public func hiddenCategoryIDs(for id: SourceID) -> Set<String> {
        Set(hiddenCategoriesBySource[id.rawValue] ?? [])
    }

    // MARK: Lifecycle

    /// Loads sources and cached catalogs, then refreshes stale data in the background.
    public func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        sources = sourceStore.load()
        isMetadataEnabled = await metadataRepository.isEnabled
        guard !sources.isEmpty else {
            phase = .onboarding
            return
        }
        let cached = await catalogRepository.cachedCatalogs(for: sources)
        for catalog in cached {
            sourceCatalogs[catalog.sourceID] = catalog
            if let account = catalog.account { accounts[catalog.sourceID] = account }
        }
        await rebuild()
        phase = .ready
        guide = await epgRepository.cachedGuide(for: sources)

        let now = Date.now
        for source in sources where source.isEnabled {
            let stale = sourceCatalogs[source.id] == nil
                || (source.lastRefreshedAt.map { now.timeIntervalSince($0) > Self.catalogMaxAge } ?? true)
            if stale { Task { await refresh(source.id) } }
        }
        Task { await refreshGuideIfStale() }
    }

    /// Called by the onboarding when the user enters the app.
    public func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: Keys.onboardingDone)
        withAnimation(.smooth(duration: 0.6)) { phase = .ready }
    }

    /// Shows the onboarding again (e.g. from Settings, or after removing every source).
    public func restartOnboarding() {
        withAnimation(.smooth(duration: 0.6)) { phase = .onboarding }
    }

    /// Persists pending library writes (app termination).
    public func flush() {
        library.flush()
    }

    // MARK: Sources

    /// Saves the source (+ password in the Keychain), imports it and streams the progress.
    /// The last element has stage `.finished`; the guide stage is included.
    public func importSource(_ source: Source, password: String?) -> AsyncThrowingStream<ImportProgress, any Error> {
        let isNew = self.source(source.id) == nil
        let stream = AsyncThrowingStream<ImportProgress, any Error>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task { @MainActor in
                do {
                    guard self.imports[source.id] == nil else { throw SourceImportBusy() }
                    try Task.checkCancellation()
                    if let password {
                        try self.credentials.setPassword(password, for: source.id)
                    }
                    if isNew { self.pendingSources.insert(source.id) }
                    self.upsert(source)
                    try await self.performImport(source.id) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    if isNew, self.sourceCatalogs[source.id] == nil, self.imports[source.id] == nil,
                       self.source(source.id) != nil {
                        self.remove(source.id)
                    } else if !isNew, !(error is CancellationError), !(error is SourceImportBusy) {
                        self.errors[source.id] = error.localizedDescription
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return stream
    }

    /// Adds the built-in demo source.
    public func importDemo() -> AsyncThrowingStream<ImportProgress, any Error> {
        importSource(DemoContent.makeSource(), password: nil)
    }

    /// Refreshes one source in the background (progress visible through `imports`).
    public func refresh(_ id: SourceID) async {
        guard imports[id] == nil else { return }
        do {
            try await performImport(id) { _ in }
        } catch is CancellationError {
        } catch {
            errors[id] = error.localizedDescription
        }
    }

    public func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for source in sources where source.isEnabled {
                group.addTask { await self.refresh(source.id) }
            }
        }
    }

    /// Updates a source's settings. Connection changes trigger a refresh.
    public func update(_ source: Source, password: String? = nil) {
        guard imports[source.id] == nil else { return }
        if let password {
            do {
                try credentials.setPassword(password, for: source.id)
            } catch {
                errors[source.id] = error.localizedDescription
                return
            }
        }
        let previous = self.source(source.id)
        upsert(source)
        let connectionChanged = previous?.serverURL != source.serverURL
            || previous?.username != source.username
            || previous?.fileBookmark != source.fileBookmark
            || previous?.preferHLSForLive != source.preferHLSForLive
            || previous?.userAgent != source.userAgent
            || password != nil
        if connectionChanged {
            Task { await refresh(source.id) }
        } else if previous?.isEnabled != source.isEnabled || previous?.name != source.name || previous?.tint != source.tint {
            Task { await rebuild() }
        }
        if previous?.epgURL != source.epgURL || previous?.epgTimeShiftHours != source.epgTimeShiftHours {
            Task { await refreshGuide(for: source.id) }
        }
    }

    public func setEnabled(_ enabled: Bool, for id: SourceID) {
        guard var source = source(id) else { return }
        source.isEnabled = enabled
        update(source)
    }

    public func setHiddenCategoryIDs(_ categoryIDs: Set<String>, for id: SourceID) {
        guard source(id) != nil else { return }
        let categoryIDs = categoryIDs.filter { $0.hasPrefix(id.rawValue + ":") }
        guard categoryIDs != hiddenCategoryIDs(for: id) else { return }
        hiddenCategoriesBySource[id.rawValue] = categoryIDs.isEmpty ? nil : categoryIDs.sorted()
        persistHiddenCategories()
        Task { await rebuild() }
    }

    public func remove(_ id: SourceID) {
        guard imports[id] == nil else { return }
        pendingSources.remove(id)
        sources.removeAll { $0.id == id }
        if hiddenCategoriesBySource.removeValue(forKey: id.rawValue) != nil { persistHiddenCategories() }
        persistSources()
        try? credentials.setPassword(nil, for: id)
        sourceCatalogs[id] = nil
        accounts[id] = nil
        errors[id] = nil
        imports[id] = nil
        Task {
            await catalogRepository.forget(id)
            await epgRepository.forget(id)
            guide = await epgRepository.currentGuide(for: sources)
            await rebuild()
        }
    }

    public func moveSources(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        sources.move(fromOffsets: offsets, toOffset: destination)
        persistSources()
        Task {
            guide = await epgRepository.currentGuide(for: sources)
            await rebuild()
        }
    }

    // MARK: TMDB

    public var tmdbKey: String? { credentials.secret(named: CredentialKeys.tmdb) }

    public func setTMDBKey(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        try? credentials.setSecret(trimmed?.isEmpty == false ? trimmed : nil, named: CredentialKeys.tmdb)
        Task {
            await metadataRepository.reload()
            isMetadataEnabled = await metadataRepository.isEnabled
        }
    }

    // MARK: Guide

    public func refreshGuideIfStale() async {
        var staleSources: [SourceID] = []
        for source in sources where source.isEnabled {
            let fetched = await epgRepository.lastFetched(source.id)
            if fetched.map({ Date.now.timeIntervalSince($0) > Self.guideMaxAge }) ?? true {
                staleSources.append(source.id)
            }
        }
        for id in staleSources { await refreshGuide(for: id) }
    }

    @discardableResult
    public func refreshGuide(for id: SourceID) async -> Int {
        guard let source = source(id), source.isEnabled else { return 0 }
        isRefreshingGuide = true
        defer { isRefreshingGuide = false }
        do {
            let sourceGuide = try await epgRepository.refresh(source, playlistEPGURLs: catalogRepository.playlistEPGURLs(for: id))
            guide = await epgRepository.currentGuide(for: sources)
            return sourceGuide.programCount
        } catch {
            return 0
        }
    }

    // MARK: Private

    private func upsert(_ source: Source) {
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = source
        } else {
            sources.append(source)
        }
        if !pendingSources.contains(source.id) { persistSources() }
    }

    private func persistSources() {
        guard !isEphemeral else { return }
        try? sourceStore.save(sources.filter { !pendingSources.contains($0.id) })
    }

    private func persistHiddenCategories() {
        guard !isEphemeral else { return }
        UserDefaults.standard.set(hiddenCategoriesBySource, forKey: Keys.hiddenCategories)
    }

    private func performImport(_ id: SourceID, report: (ImportProgress) -> Void) async throws {
        guard let source = source(id) else { return }
        errors[id] = nil
        imports[id] = ImportProgress(stage: .connecting, fraction: 0)
        defer { imports[id] = nil }

        var finished: ImportProgress?
        for try await progress in catalogRepository.refresh(source) {
            try Task.checkCancellation()
            if progress.stage == .finished {
                finished = progress
            } else {
                var playlistProgress = progress
                playlistProgress.fraction *= 0.91
                imports[id] = playlistProgress
                report(playlistProgress)
            }
        }
        guard let finished, let catalog = finished.catalog else { throw SourceError.emptyPlaylist }
        guard self.source(id) != nil else { throw CancellationError() }

        sourceCatalogs[id] = catalog
        pendingSources.remove(id)
        if let account = catalog.account { accounts[id] = account }
        if var updated = self.source(id) {
            updated.lastRefreshedAt = .now
            upsert(updated)
        }
        await rebuild()

        var counts = finished.counts
        let guideStart = ImportProgress(stage: .guide(0), counts: counts, fraction: 0.92)
        imports[id] = guideStart
        report(guideStart)
        counts.programs = await refreshGuide(for: id)
        let guideDone = ImportProgress(stage: .guide(counts.programs), counts: counts, fraction: 0.98)
        imports[id] = guideDone
        report(guideDone)
        report(ImportProgress(stage: .finished, counts: counts, fraction: 1, catalog: catalog, epgURLs: finished.epgURLs))
    }

    /// Rebuilds the merged catalog + search index off the main actor; the latest call wins.
    public func rebuild() async {
        rebuildGeneration += 1
        let generation = rebuildGeneration
        let sources = self.sources
        let catalogs = sources.compactMap { sourceCatalogs[$0.id] }
        let options = CatalogBuildOptions(
            hideAdult: hideAdultContent,
            hiddenCategoryIDs: Set(hiddenCategoriesBySource.values.joined())
        )
        let built = await CatalogBuilder.build(sources: sources, catalogs: catalogs, options: options)
        async let index = SearchIndex.build(from: built)
        async let recommendations = RecommendationBuilder.build(for: built)
        let (newIndex, newRecommendations) = await (index, recommendations)
        guard generation == rebuildGeneration else { return }
        library.reconcileTitles(in: built)
        catalog = built
        searchIndex = newIndex
        self.recommendations = newRecommendations
        catalogRevision &+= 1
    }
}

private struct SourceImportBusy: LocalizedError {
    var errorDescription: String? { "Cette source est déjà en cours d’importation." }
}
