import AppKit
import Foundation
import Observation
import SwiftUI
import PrismCore
import PrismData

/// Everything a curated page depends on. Equal requests produce the same feed.
public struct CurationRequest: Hashable, Sendable {
    public let scope: CurationScope
    let catalogRevision: Int
    let curationRevision: Int
    let trendingRevision: Int
    let languages: Set<HomeAudioLanguage>
    /// Content token of `profile`: the payload itself can hold ~2 000 dismissed
    /// ids, so `==`/`hash` go through this revision — `.task(id:)` pays the
    /// comparison on every body evaluation of every page asking for a feed.
    /// Two requests sharing a `profileRevision` always carry equal profiles
    /// (the revision only bumps when the rebuilt profile differs).
    let profileRevision: Int
    let profile: CurationProfile
    /// Shelves rotate once a day.
    let day: Int

    public static func == (lhs: CurationRequest, rhs: CurationRequest) -> Bool {
        lhs.scope == rhs.scope
            && lhs.catalogRevision == rhs.catalogRevision
            && lhs.curationRevision == rhs.curationRevision
            && lhs.trendingRevision == rhs.trendingRevision
            && lhs.languages == rhs.languages
            && lhs.profileRevision == rhs.profileRevision
            && lhs.day == rhs.day
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(scope)
        hasher.combine(catalogRevision)
        hasher.combine(curationRevision)
        hasher.combine(trendingRevision)
        hasher.combine(languages)
        hasher.combine(profileRevision)
        hasher.combine(day)
    }
}

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
    @ObservationIgnored public let sportsRepository: SportsRepository
    /// Hero pages' artwork and synopsis, resolved once per title.
    @ObservationIgnored let heroArtwork = HeroArtworkStore()
    @ObservationIgnored private let sourceStore: SourceStore
    @ObservationIgnored private let settings = AppSettings()
    @ObservationIgnored private let isEphemeral: Bool
    public private(set) var library: LibraryStore {
        didSet {
            // A swapped store invalidates the curation memo and its observation
            // (tests/previews reassign it); the next read re-arms on the new one.
            curationProfileDirty = true
            curationProfileObservedStore = nil
        }
    }

    // MARK: State

    public private(set) var phase: Phase = .launching
    public private(set) var sources: [Source] = []
    public private(set) var catalog: Catalog = .empty
    public private(set) var guide: EPGGuide = .empty {
        didSet { guideRevision &+= 1 }
    }
    public private(set) var guideRevision = 0
    public private(set) var searchIndex: SearchIndex?
    public private(set) var recommendations = Recommendations.empty
    public private(set) var homeAudioLanguages = HomeAudioLanguage.defaults
    public private(set) var sportsSettingsRevision = 0
    /// In-flight imports/refreshes, by source: one observable cell per source.
    /// The dictionary only changes when a cell is created (kept for the session),
    /// so "is importing" readers are not invalidated by the ~8/s progress ticks —
    /// only views reading `importProgress(for:)` subscribe to a source's stream.
    private var importStates: [SourceID: SourceImportState] = [:]
    /// Last refresh error per source (French, user-facing).
    public private(set) var errors: [SourceID: String] = [:]
    public private(set) var accounts: [SourceID: XtreamAccount] = [:]
    /// `true` while at least one EPG refresh runs (was a plain flag that flipped
    /// back early when a second refresh overlapped).
    public private(set) var isRefreshingGuide = false
    /// Grouped-item counts per source, computed once per catalogue publish
    /// (`countsBySource`) — replaces the per-page O(catalogue) `Catalog.counts(for:)`.
    public private(set) var sourceCounts: [SourceID: ImportCounts] = [:]
    public private(set) var isMetadataEnabled = false
    /// Signals behind the curated shelves; rebuilt in the background after each catalogue.
    @ObservationIgnored public private(set) var curationIndex = CurationIndex.empty
    public private(set) var curationRevision = 0
    private let curatedFeeds: [CurationScope: CuratedFeedState] = [
        .home: CuratedFeedState(), .movies: CuratedFeedState(), .series: CuratedFeedState()
    ]
    /// TMDB weekly charts matched to the catalogue (only with a TMDB key).
    @ObservationIgnored private var trendingIDs: [MediaKind: [TitleID]] = [:]
    private var trendingRevision = 0
    @ObservationIgnored private var trendingTask: Task<Void, Never>?
    @ObservationIgnored private var curationTask: Task<Void, Never>?
    private var hiddenCategoriesBySource: [String: [String]] = [:]
    /// Bumped every time `catalog` is replaced (cheap change token for views/tasks).
    public private(set) var catalogRevision = 0
    /// Bumped when `curationProfile`'s content actually changes — the token views
    /// compare instead of the profile's collections (see `CurationRequest`).
    public private(set) var curationProfileRevision = 0
    /// Memoized `curationProfile`: rebuilding it copies the watchlist and hashes
    /// up to 2 000 dismissed ids, and pages ask for a request on every body
    /// evaluation. Dropped by `observeCurationProfile` when its inputs mutate.
    @ObservationIgnored private var curationProfileCache: CurationProfile?
    @ObservationIgnored private var curationProfileDirty = true
    /// The `LibraryStore` instance currently observed for profile inputs.
    @ObservationIgnored private var curationProfileObservedStore: LibraryStore?

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
    @ObservationIgnored private var catalogTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var sourceCountsTask: Task<Void, Never>?
    /// `catalogRevision` that produced the current `sourceCounts`, `nil` while stale.
    @ObservationIgnored private var sourceCountsRevision: Int?
    @ObservationIgnored private var didBootstrap = false
    /// Guide refreshes in flight, one per source: concurrent requests for the same
    /// source share the task instead of downloading the XMLTV twice.
    @ObservationIgnored private var guideTasks: [SourceID: Task<Int, Never>] = [:]
    /// Number of EPG refreshes running (drives `isRefreshingGuide`).
    @ObservationIgnored private var activeGuideRefreshes = 0
    /// Bounded import concurrency: catalogue refreshes fetch + decode whole playlists,
    /// so `refreshAll`/bootstrap/import must not fan out unboundedly.
    @ObservationIgnored private var importSlots = 0
    @ObservationIgnored private var importSlotWaiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
    private static let maxConcurrentImports = 3

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
        self.sportsRepository = SportsRepository(credentials: credentials)
        self.sourceStore = SourceStore(directories: directories)
        self.library = library ?? LibraryStore(directories: directories)
        self.hideAdultContent = UserDefaults.standard.object(forKey: Keys.hideAdult) as? Bool ?? true
        if !isEphemeral {
            self.homeAudioLanguages = settings.homeAudioLanguages
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

    /// Sources currently importing, with their latest progress — same shape as the
    /// former `imports` dictionary, kept for tests/tools. Views should prefer
    /// `isImporting(_:)` / `importProgress(for:)`: reading this computed property
    /// subscribes to every source's progress stream.
    public var imports: [SourceID: ImportProgress] {
        importStates.compactMapValues(\.progress)
    }

    public func source(_ id: SourceID) -> Source? { sources.first { $0.id == id } }
    public func password(for id: SourceID) -> String? { credentials.password(for: id) }
    public func account(for id: SourceID) -> XtreamAccount? { accounts[id] }
    public func isImporting(_ id: SourceID) -> Bool { importStates[id]?.isActive == true }
    /// Throttled progress of one source's import (the detail page's `ProgressView`).
    /// Subscribes only to that source's cell: other sources' ticks don't re-evaluate
    /// the reader. `nil` once the import ends (`progress` is cleared with `isActive`).
    public func importProgress(for id: SourceID) -> ImportProgress? { importStates[id]?.progress }
    public var isImportingAnything: Bool { importStates.values.contains { $0.isActive } }
    public var hasCompletedOnboarding: Bool { UserDefaults.standard.bool(forKey: Keys.onboardingDone) }

    /// Provider categories come from the full source, including categories filtered from the library.
    public func sourceCategories(for id: SourceID) -> [PrismCore.Category] {
        _ = catalogRevision
        return sourceCatalogs[id]?.categories ?? []
    }

    public func hiddenCategoryIDs(for id: SourceID) -> Set<String> {
        Set(hiddenCategoriesBySource[id.rawValue] ?? [])
    }

    public func setHomeAudioLanguages(_ languages: Set<HomeAudioLanguage>) {
        guard !languages.isEmpty, languages != homeAudioLanguages else { return }
        homeAudioLanguages = languages
        if !isEphemeral { settings.homeAudioLanguages = languages }
    }

    fileprivate struct CuratedResult {
        let request: CurationRequest
        let feed: CuratedFeed
    }

    @Observable fileprivate final class CuratedFeedState {
        var result: CuratedResult?
    }

    /// What the curated shelves know about the user (local only).
    ///
    /// Memoized: each rebuild copies the watchlist and hashes up to 2 000
    /// dismissed ids, and view bodies ask for a curation request on every
    /// evaluation. `observeCurationProfile` drops the memo when watchlist,
    /// dismissed or history mutate; the revision only bumps when the rebuilt
    /// profile actually differs, so no-op writes don't invalidate feeds.
    public var curationProfile: CurationProfile {
        observeCurationProfile()
        if curationProfileDirty {
            let profile = CurationProfile(
                watchlist: library.watchlist,
                watched: Self.watchedTitleIDs(in: library.history),
                dismissed: Set(library.dismissed)
            )
            if profile != curationProfileCache {
                curationProfileRevision &+= 1
                curationProfileCache = profile
            }
            curationProfileDirty = false
        }
        return curationProfileCache ?? CurationProfile()
    }

    /// Most recent first, deduplicated — the `watched` input of `CurationProfile`.
    private static func watchedTitleIDs(in history: [HistoryEntry]) -> [TitleID] {
        var watched: [TitleID] = []
        var seen: Set<TitleID> = []
        for entry in history.prefix(48) {
            if case .title(let id) = entry.target, seen.insert(id).inserted { watched.append(id) }
        }
        return watched
    }

    /// (Re)arms one-shot observation of exactly the library collections
    /// `curationProfile` reads. `withObservationTracking` fires on the first
    /// mutation after arming; `onChange` runs synchronously inside the write's
    /// `willSet` (already on the main actor), marks the memo dirty — the next
    /// read rebuilds from post-write state — and re-arms for the next mutation.
    private func observeCurationProfile() {
        let store = library
        guard curationProfileObservedStore !== store else { return }
        curationProfileObservedStore = store
        withObservationTracking {
            MainActor.assumeIsolated {
                _ = store.watchlist
                _ = store.dismissed
                _ = store.history
            }
        } onChange: { [weak self, weak store] in
            MainActor.assumeIsolated {
                guard let self, let store, self.library === store else { return }
                // Keep the old cache: the lazy rebuild compares against it, so a
                // mutation landing on identical content doesn't bump the
                // revision (and needlessly recompose every feed).
                self.curationProfileDirty = true
                // Re-arm for the next mutation; this write is already covered —
                // the rebuild reads the landed state on next access.
                self.curationProfileObservedStore = nil
                self.observeCurationProfile()
                // The dirty flag is @ObservationIgnored: without a tracked write,
                // feed bodies never re-evaluate and dismissed/watchlisted changes
                // stay invisible until an unrelated trigger. Rebuild on the next
                // main-actor turn (this onChange runs inside willSet, pre-write);
                // `curationProfileRevision` bumps only when content differs.
                Task { @MainActor [weak self] in _ = self?.curationProfile }
            }
        }
    }

    public func curationRequest(for scope: CurationScope) -> CurationRequest {
        // Read the profile first: a dirty memo rebuilds here and bumps
        // `curationProfileRevision`, so the revision must be sampled after —
        // arguments evaluate left to right and a stale token would make the
        // request fail `refreshFeed`'s freshness check on its first use.
        let profile = curationProfile
        return CurationRequest(
            scope: scope, catalogRevision: catalogRevision, curationRevision: curationRevision,
            trendingRevision: trendingRevision, languages: homeAudioLanguages,
            profileRevision: curationProfileRevision, profile: profile,
            day: Int(Date.now.timeIntervalSince1970 / 86_400)
        )
    }

    /// The latest feed composed for `scope`. A stale feed stays visible while its replacement is built.
    public func feed(for scope: CurationScope) -> CuratedFeed {
        curatedFeeds[scope]?.result?.feed ?? .empty
    }

    /// `false` until a first feed exists for `scope` (the page then shows a placeholder).
    public func hasFeed(for scope: CurationScope) -> Bool {
        curatedFeeds[scope]?.result != nil
    }

    public func refreshFeed(_ request: CurationRequest) async {
        guard let state = curatedFeeds[request.scope], request == curationRequest(for: request.scope), state.result?.request != request,
              curationIndex.isBuilt, !Task.isCancelled else { return }
        let catalog = self.catalog, index = curationIndex, recommendations = self.recommendations
        let feed = await Curator.feed(
            scope: request.scope, catalog: catalog, index: index, recommendations: recommendations,
            languages: request.languages, profile: request.profile, trending: trendingIDs
        )
        guard !Task.isCancelled, request == curationRequest(for: request.scope) else { return }
        state.result = CuratedResult(request: request, feed: feed)
        if isMetadataEnabled, trendingTask == nil, trendingIDs.isEmpty { refreshTrending() }
    }

    /// The full ranked list behind a curated shelf.
    public func collection(_ query: CurationQuery) async -> [MediaTitle] {
        await Curator.collection(
            query, catalog: catalog, index: curationIndex, recommendations: recommendations,
            languages: homeAudioLanguages, profile: curationProfile
        )
    }

    /// "À voir aussi": titles close to `title` in genres, platforms and era, best first.
    public func similarTitles(to title: MediaTitle, limit: Int = 16) async -> [MediaTitle] {
        guard let signals = signals(for: title), signals.genres.count > 0 else { return [] }
        let query = CurationQuery(kind: title.kind, facet: .because(title.id), title: "")
        return await Curator.collection(
            query, catalog: catalog, index: curationIndex, recommendations: recommendations,
            languages: homeAudioLanguages, profile: curationProfile, limit: limit
        )
    }

    public func signals(for title: MediaTitle) -> TitleSignals? {
        curationIndex.signals(for: title, in: catalog)
    }

    private func refreshTrending() {
        trendingTask?.cancel()
        guard isMetadataEnabled else {
            if !trendingIDs.isEmpty {
                trendingIDs = [:]
                trendingRevision &+= 1
            }
            return
        }
        let catalog = self.catalog, recommendations = self.recommendations, revision = catalogRevision
        trendingTask = Task { [weak self, metadataRepository] in
            var charts: [MediaKind: [TitleID]] = [:]
            for kind in [MediaKind.movie, .series] {
                let chart = await metadataRepository.weeklyTrending(for: kind)
                let matched = await DiscoveryBuilder.trending(
                    chart, for: kind, in: catalog, recommendations: recommendations, languages: HomeAudioLanguage.defaults
                )
                charts[kind] = matched.map(\.id)
            }
            guard !Task.isCancelled, let self, self.catalogRevision == revision else { return }
            self.trendingIDs = charts
            self.trendingRevision &+= 1
            self.trendingTask = nil
        }
    }

    // MARK: Lifecycle

    /// Loads sources and cached catalogs, then refreshes stale data in the background.
    public func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        sources = sourceStore.load()
        isMetadataEnabled = await metadataRepository.isEnabled
        // Le decode des caches démarre dès que `sources` est connu : il ne dépend ni de
        // `library.json` ni des métadonnées, et chaque ms compte avant `.ready`.
        async let cached = catalogRepository.cachedCatalogs(for: sources)
        // `library.json` is decoded off the main actor since `init`: await it on every
        // path (onboarding included) so no caller can mutate the store while the disk
        // snapshot is still in flight — a pre-load mutation would otherwise discard it.
        await library.awaitDiskLoad()
        guard !sources.isEmpty else {
            phase = .onboarding
            return
        }
        for catalog in await cached {
            sourceCatalogs[catalog.sourceID] = catalog
            if let account = catalog.account { accounts[catalog.sourceID] = account }
        }
        // The library decode was already awaited above; `rebuildCatalog` → `publish` →
        // `reconcileTitles` therefore sees the real collections, not empty ones.
        await rebuildCatalog()
        phase = .ready
        // Le guide n'est pas nécessaire à `.ready` : le démarrer ici l'empêche de
        // disputer les cœurs avec le decode catalogue pendant la fenêtre critique
        // (~250 ms mesurées), au prix d'un guide disponible ~1 s plus tard.
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
                    guard !self.isImporting(source.id) else { throw SourceImportBusy() }
                    try Task.checkCancellation()
                    if let password {
                        try self.credentials.setPassword(password, for: source.id)
                    }
                    if isNew { self.pendingSources.insert(source.id) }
                    self.upsert(source)
                    try await self.performImport(source.id) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    if isNew, self.sourceCatalogs[source.id] == nil, !self.isImporting(source.id),
                       self.source(source.id) != nil {
                        self.remove(source.id)
                    } else if !isNew, !(error is CancellationError), !(error is SourceImportBusy) {
                        self.errors[source.id] = UserFacingError.message(for: error)
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

    /// Refreshes one source in the background (progress visible through `importProgress(for:)`).
    public func refresh(_ id: SourceID) async {
        guard !isImporting(id) else { return }
        do {
            try await performImport(id) { _ in }
        } catch is CancellationError {
        } catch is SourceImportBusy {
            // Another import grabbed the slot first: silent no-op, like the
            // early `isImporting` guard above.
        } catch {
            errors[id] = UserFacingError.message(for: error)
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
    @discardableResult
    public func update(_ source: Source, password: String? = nil) -> Bool {
        guard !isImporting(source.id) else { return false }
        if let password {
            do {
                try credentials.setPassword(password, for: source.id)
            } catch {
                errors[source.id] = UserFacingError.message(for: error)
                return false
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
        return true
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
        guard !isImporting(id) else { return }
        pendingSources.remove(id)
        sources.removeAll { $0.id == id }
        if hiddenCategoriesBySource.removeValue(forKey: id.rawValue) != nil { persistHiddenCategories() }
        persistSources()
        try? credentials.setPassword(nil, for: id)
        sourceCatalogs[id] = nil
        accounts[id] = nil
        errors[id] = nil
        importStates[id] = nil
        if sources.isEmpty, phase == .ready { restartOnboarding() }
        Task {
            // Purges disque sur deux actors distincts : elles se chevauchent.
            async let catalogForgotten = catalogRepository.forget(id)
            async let guideForgotten = epgRepository.forget(id)
            await catalogForgotten
            await guideForgotten
            guide = await epgRepository.currentGuide(for: sources)
            await rebuild()
        }
    }

    public func moveSources(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        sources.move(fromOffsets: offsets, toOffset: destination)
        persistSources()
        Task {
            async let updatedGuide = epgRepository.currentGuide(for: sources)
            await rebuild()
            guide = await updatedGuide
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
            trendingIDs = [:]
            refreshTrending()
        }
    }

    public var hasSportsAPIKey: Bool { credentials.secret(named: CredentialKeys.theSportsDB) != nil }

    public func setSportsAPIKey(_ key: String?) throws {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        try credentials.setSecret(trimmed?.isEmpty == false ? trimmed : nil, named: CredentialKeys.theSportsDB)
        sportsSettingsRevision &+= 1
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
        // Le téléchargement XMLTV domine : les chevaucher par paquets de
        // `maxConcurrentImports` (comme les imports) au lieu de les sérialiser —
        // le bootstrap n'attend plus la somme des guides mais ~le plus lent.
        // `refreshGuide(for:)` déduplique déjà les sources et `currentGuide`
        // republie une fusion valide à chaque fin, quel que soit l'ordre.
        for start in stride(from: 0, to: staleSources.count, by: Self.maxConcurrentImports) {
            let chunk = staleSources[start..<min(start + Self.maxConcurrentImports, staleSources.count)]
            await withTaskGroup(of: Void.self) { group in
                for id in chunk {
                    group.addTask { _ = await self.refreshGuide(for: id) }
                }
            }
        }
    }

    @discardableResult
    public func refreshGuide(for id: SourceID) async -> Int {
        guard let source = source(id), source.isEnabled else { return 0 }
        // Une seule requête EPG par source à la fois : les appels concurrents
        // (bouton « Actualiser », fin d'import, bootstrap) partagent la tâche.
        if let task = guideTasks[id] { return await task.value }
        let task = Task { @MainActor in
            defer {
                guideTasks[id] = nil
                activeGuideRefreshes -= 1
                isRefreshingGuide = activeGuideRefreshes > 0
            }
            do {
                let sourceGuide = try await epgRepository.refresh(source, playlistEPGURLs: catalogRepository.playlistEPGURLs(for: id))
                guide = await epgRepository.currentGuide(for: sources)
                return sourceGuide.programCount
            } catch {
                return 0
            }
        }
        guideTasks[id] = task
        activeGuideRefreshes += 1
        isRefreshingGuide = true
        return await task.value
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
        guard source(id) != nil else { return }
        // Au plus `maxConcurrentImports` imports lourds (fetch + décodage) en
        // parallèle, que ce soit via `refreshAll`, le bootstrap ou l'onboarding.
        try await withImportSlot {
            // Une source supprimée ou déjà importée pendant l'attente du slot
            // ne doit pas repartir : `isActive` n'est posé qu'une fois le slot acquis.
            guard !isImporting(id) else { throw SourceImportBusy() }
            try await performImportHeld(id, report: report)
        }
    }

    /// The observable cell tracking `id`'s import, created on first use and kept
    /// afterwards so progress observers stay attached to the same instance.
    private func importState(for id: SourceID) -> SourceImportState {
        if let state = importStates[id] { return state }
        let state = SourceImportState()
        importStates[id] = state
        return state
    }

    private func performImportHeld(_ id: SourceID, report: (ImportProgress) -> Void) async throws {
        try Task.checkCancellation()
        guard let source = source(id) else { return }
        errors[id] = nil
        let state = importState(for: id)
        state.isActive = true
        state.progress = ImportProgress(stage: .connecting, fraction: 0)
        defer {
            state.isActive = false
            state.progress = nil
        }

        var finished: ImportProgress?
        // `state.progress` n'est lu que par la fiche de la source : chaque écriture
        // ne réévalue plus les badges latéraux ni les autres fiches. On n'écrit
        // qu'au changement de pourcent ou au plus ~8×/s. Le flux `report` (fiche
        // d'import) continue de recevoir chaque étape.
        var lastProgressWrite = Date.distantPast
        var lastProgressPercent = -1
        for try await progress in catalogRepository.refresh(source) {
            try Task.checkCancellation()
            if progress.stage == .finished {
                finished = progress
            } else {
                var playlistProgress = progress
                playlistProgress.fraction *= 0.91
                let percent = Int((playlistProgress.fraction * 100).rounded())
                let now = Date.now
                if percent != lastProgressPercent || now.timeIntervalSince(lastProgressWrite) >= 0.12 {
                    state.progress = playlistProgress
                    lastProgressPercent = percent
                    lastProgressWrite = now
                }
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
        await rebuildCatalog()
        prepareSearchIndex()

        var counts = finished.counts
        let guideStart = ImportProgress(stage: .guide(0), counts: counts, fraction: 0.92)
        state.progress = guideStart
        report(guideStart)
        counts.programs = await refreshGuide(for: id)
        let guideDone = ImportProgress(stage: .guide(counts.programs), counts: counts, fraction: 0.98)
        state.progress = guideDone
        report(guideDone)
        // L'index de recherche et l'index de curation continuent de se construire
        // en arrière-plan : la fiche peut afficher « Tout est prêt » sans attendre
        // (les écrans gèrent l'index absent — placeholder de recherche, shelves
        // recomposées à la première `curationRevision`). On attend seulement le
        // catalogue courant, ce qui protège contre un rebuild concurrent.
        await waitForCurrentCatalog()
        try Task.checkCancellation()
        report(ImportProgress(stage: .finished, counts: counts, fraction: 1, catalog: catalog, epgURLs: finished.epgURLs))
    }

    /// Rebuilds the merged catalog and waits until that snapshot is searchable.
    public func rebuild() async {
        await rebuildCatalog(includingSearch: true)
    }

    /// Publish the merged catalog as soon as browsing is possible. Search indexes that snapshot separately.
    private func rebuildCatalog(includingSearch: Bool = false) async {
        // Every publish path funnels here (bootstrap, imports, removals, onboarding
        // restart, preference rebuilds): make sure the async `library.json` decode
        // landed first so `reconcileTitles` and any early mutation see real state.
        // Idempotent — instant once the load task has completed.
        await library.awaitDiskLoad()
        rebuildGeneration &+= 1
        catalogTask?.cancel()
        searchTask?.cancel()
        let sources = self.sources
        let catalogs = sources.compactMap { sourceCatalogs[$0.id] }
        let options = CatalogBuildOptions(
            hideAdult: hideAdultContent,
            hiddenCategoryIDs: Set(hiddenCategoriesBySource.values.joined())
        )
        catalogTask = Task { [weak self] in
            let built = await CatalogBuilder.build(sources: sources, catalogs: catalogs, options: options)
            guard !Task.isCancelled else { return }
            let recommendations = await RecommendationBuilder.build(for: built)
            guard !Task.isCancelled else { return }
            self?.publish(built, recommendations: recommendations)
        }
        await waitForCurrentCatalog(includingSearch: includingSearch)
    }

    private func publish(_ built: Catalog, recommendations: Recommendations) {
        catalog = built
        searchIndex = nil
        self.recommendations = recommendations
        catalogRevision &+= 1
        let publishedRevision = catalogRevision
        // `reconcileTitles` walks every library collection (progress, history,
        // preferences — ~30 ms measured at the collection caps) on the main
        // actor. Inline, it used to sit on `.ready`'s critical path and delay
        // every republish; deferred by one actor turn it lands right after the
        // new snapshot is visible. The revision guard drops it when a newer
        // publish already superseded this one (that publish enqueues its own).
        Task(priority: .utility) { [weak self] in
            guard let self, self.catalogRevision == publishedRevision else { return }
            self.library.reconcileTitles(in: built)
        }
        trendingTask?.cancel()
        trendingTask = nil
        trendingIDs = [:]
        // Positions in the previous index do not match the new catalogue.
        curationIndex = .empty
        curationTask?.cancel()
        curationTask = Task { [weak self] in
            let index = await CurationIndex.build(catalog: built, recommendations: recommendations)
            guard !Task.isCancelled, let self else { return }
            self.curationIndex = index
            // Previous feeds stay visible until each page recomposes with the new index.
            self.curationRevision &+= 1
            if self.isMetadataEnabled { self.refreshTrending() }
        }
        searchTask?.cancel()
        searchTask = nil
        // Comptages par source pour les fiches Sources : un seul passage sur le
        // catalogue, mais seulement quand une fiche de source est ouverte
        // (`prepareSourceCounts`) — plus de scan à chaque publication pour un
        // écran que l'utilisateur ne visite pas toujours.
        sourceCountsTask?.cancel()
        sourceCountsTask = nil
        sourceCountsRevision = nil
    }

    /// One pass over the catalogue: how many grouped items offer a variant per
    /// source (same semantics as `Catalog.counts(for:)`, for every source at once).
    @concurrent private static func countsBySource(in catalog: Catalog) async -> [SourceID: ImportCounts] {
        var channels: [SourceID: Int] = [:]
        var movies: [SourceID: Int] = [:]
        var series: [SourceID: Int] = [:]
        for group in catalog.channels {
            for source in Set(group.variants.map(\.sourceID)) {
                channels[source, default: 0] += 1
            }
        }
        for title in catalog.movies {
            for source in Set(title.variants.map(\.sourceID)) {
                movies[source, default: 0] += 1
            }
        }
        for title in catalog.series {
            for source in Set(title.variants.map(\.sourceID)) {
                series[source, default: 0] += 1
            }
        }
        var result: [SourceID: ImportCounts] = [:]
        for id in Set(channels.keys).union(movies.keys).union(series.keys) {
            result[id] = ImportCounts(channels: channels[id] ?? 0, movies: movies[id] ?? 0,
                                      series: series[id] ?? 0)
        }
        return result
    }

    /// Warm the index when Search opens or when a caller explicitly awaits a searchable catalogue.
    func prepareSearchIndex() {
        guard searchIndex == nil, searchTask == nil else { return }
        let catalog = self.catalog
        let recommendations = self.recommendations
        let revision = catalogRevision
        searchTask = Task(priority: .utility) { [weak self] in
            let index = await SearchIndex.build(from: catalog, recommendations: recommendations)
            guard !Task.isCancelled, let self, self.catalogRevision == revision else { return }
            self.searchIndex = index
            self.searchTask = nil
        }
    }

    /// Warm the per-source grouped counts when a source page opens — their only
    /// reader (`SourceDetailView`). One background pass per catalog publish;
    /// `sourceCounts` keeps the previous snapshot until the new one lands.
    func prepareSourceCounts() {
        guard sourceCountsTask == nil, sourceCountsRevision != catalogRevision else { return }
        let catalog = self.catalog
        let revision = catalogRevision
        sourceCountsTask = Task(priority: .utility) { [weak self] in
            let counts = await Self.countsBySource(in: catalog)
            guard !Task.isCancelled, let self, self.catalogRevision == revision else { return }
            self.sourceCounts = counts
            self.sourceCountsRevision = revision
            self.sourceCountsTask = nil
        }
    }

    /// Runs `body` holding one of `maxConcurrentImports` slots; extra callers wait
    /// FIFO. Cancellation while waiting resumes with `false` so no waiter is stuck.
    private func withImportSlot<T>(_ body: () async throws -> T) async throws -> T {
        guard await acquireImportSlot() else { throw CancellationError() }
        defer { releaseImportSlot() }
        return try await body()
    }

    private func acquireImportSlot() async -> Bool {
        if importSlots < Self.maxConcurrentImports {
            importSlots += 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                importSlotWaiters.append((id, continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self,
                      let index = self.importSlotWaiters.firstIndex(where: { $0.id == id })
                else { return }
                self.importSlotWaiters.remove(at: index).continuation.resume(returning: false)
            }
        }
    }

    private func releaseImportSlot() {
        // The slot transfers straight to the next waiter instead of being freed.
        if let next = importSlotWaiters.first {
            importSlotWaiters.removeFirst()
            next.continuation.resume(returning: true)
        } else {
            importSlots -= 1
        }
    }

    private func waitForCurrentCatalog(includingSearch: Bool = false) async {
        while !Task.isCancelled {
            let generation = rebuildGeneration
            await catalogTask?.value
            guard !Task.isCancelled, generation == rebuildGeneration else { continue }
            if includingSearch {
                prepareSearchIndex()
                await searchTask?.value
                await curationTask?.value
            }
            if generation == rebuildGeneration { return }
        }
    }
}

/// Live import state of one source, held by `AppModel.importStates`.
///
/// Splitting progress out of a shared dictionary is what narrows observation:
/// `isActive` flips only when an import starts or ends, while `progress` ticks
/// (~8/s) invalidate just the views that read it — the source's own detail page.
@MainActor
@Observable
final class SourceImportState {
    /// `true` between import start and the deferred cleanup (the `.finished` report included).
    var isActive = false
    /// Latest throttled progress while active; cleared together with `isActive`.
    var progress: ImportProgress?
}

private struct SourceImportBusy: LocalizedError {
    var errorDescription: String? { "Cette source est déjà en cours d’importation." }
}

/// French, user-facing error messages for `AppModel.errors` and the source sheet.
/// `AddSourceView.displayError` delegates here so both surfaces share the same wording
/// (raw `localizedDescription` can leak English URLError/CocoaError text).
enum UserFacingError {
    static func message(for error: any Error) -> String {
        if error is KeychainError { return error.localizedDescription }
        if let error = error as? SourceError {
            if case .network = error {
                return "Connexion à la source impossible. Vérifiez l’adresse et réessayez."
            }
            return error.localizedDescription
        }
        if let error = error as? XtreamError {
            if case .network = error {
                return "Connexion au serveur impossible. Vérifiez l’adresse et réessayez."
            }
            return error.localizedDescription
        }
        return "L’importation a échoué. Vérifiez les informations de la source et réessayez."
    }
}
