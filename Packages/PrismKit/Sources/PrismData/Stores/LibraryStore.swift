import Foundation
import Synchronization
import Observation
import PrismCore

/// An entry of the "Continuer" shelf.
public struct ContinueWatchingItem: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Resume a movie or an episode in progress.
        case resume
        /// The previous episode is finished: play the next one.
        case nextEpisode
        /// A series opened recently but without any recorded progress.
        case startSeries
    }

    /// The grouped title id (one item per title).
    public var id: String
    public var title: MediaTitle
    /// Content to play (movie variant, episode…).
    public var contentID: ContentID
    public var episode: Episode?
    public var progress: PlaybackProgress?
    public var kind: Kind
    public var updatedAt: Date

    public init(id: String, title: MediaTitle, contentID: ContentID, episode: Episode? = nil, progress: PlaybackProgress? = nil, kind: Kind, updatedAt: Date) {
        self.id = id
        self.title = title
        self.contentID = contentID
        self.episode = episode
        self.progress = progress
        self.kind = kind
        self.updatedAt = updatedAt
    }
}

/// The user's library: watchlist ("Ma liste"), favourite channels, resume points, watched state,
/// history and preferred variants. Persisted as a small JSON file; writes are debounced.
@MainActor
@Observable
public final class LibraryStore {
    /// Most recent first.
    public private(set) var watchlist: [TitleID] = [] {
        didSet { watchlistSet = Set(watchlist) }
    }
    /// Channel group ids, in user order.
    public private(set) var favoriteChannels: [String] = [] {
        didSet { favoriteChannelSet = Set(favoriteChannels) }
    }
    public private(set) var progress: [ContentID: PlaybackProgress] = [:] {
        didSet {
            latestByTitle = nil
            continueWatchingRevision &+= 1
        }
    }
    public private(set) var watched: Set<ContentID> = [] {
        didSet { continueWatchingRevision &+= 1 }
    }
    /// Newest first, deduplicated by entry id, at most `maxHistory` entries.
    public private(set) var history: [HistoryEntry] = [] {
        didSet { continueWatchingRevision &+= 1 }
    }
    public private(set) var continueWatchingRevision = 0
    public private(set) var preferredVariants: [TitleID: ContentID] = [:]
    public private(set) var preferredChannelVariants: [String: ContentID] = [:]
    /// Titles the user marked “Pas intéressé”: never suggested again by the curated shelves.
    public private(set) var dismissed: [TitleID] = [] {
        didSet { dismissedSet = Set(dismissed) }
    }

    /// O(1) membership mirrors of the ordered arrays above — context menus and cards
    /// probe `isInWatchlist`/`isDismissed`/`isFavorite` per item, and linear scans over
    /// ~2 000-entry arrays were measurable on every library mutation. Tracked (not
    /// `@ObservationIgnored`) so readers keep their observation subscription.
    private var watchlistSet: Set<TitleID> = []
    private var dismissedSet: Set<TitleID> = []
    private var favoriteChannelSet: Set<String> = []

    public var lastChannelGroupID: String? {
        get { storedLastChannelGroupID }
        set {
            guard newValue != storedLastChannelGroupID else { return }
            storedLastChannelGroupID = newValue
            scheduleSave()
        }
    }

    private var storedLastChannelGroupID: String?

    public static let maxHistory = 200
    static let maxDismissed = 2_000
    static let maxProgressEntries = 3_000
    static let maxWatched = 20_000
    static let maxWatchlist = 2_000
    static let maxFavoriteChannels = 1_000
    static let maxPreferredEntries = 5_000

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let saveDelay: Duration
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Disk decode started in `init`, finishing off the main actor; `nil` for
    /// in-memory stores. Tests await it before asserting persisted state.
    @ObservationIgnored private(set) var loadTask: Task<Void, Never>?
    /// `true` once a mutator diverged the in-memory state from the file (every
    /// mutation path goes through `scheduleSave`). Guards the asynchronous disk
    /// apply: a change landing before the decode finishes wins over `library.json`.
    @ObservationIgnored private var hasLocalChanges = false
    /// Number of disk writes performed (tests).
    @ObservationIgnored private(set) var saveCount = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let writer = LibraryWriter()
    @ObservationIgnored private var latestByTitle: [TitleID: PlaybackProgress]?

    /// Loads `library.json` off the main actor (a few MB at the collection caps
    /// would otherwise decode synchronously inside `AppModel.init`, on the first
    /// frame's critical path). The launch/onboarding phases never read the
    /// library, so nothing observes the briefly-empty state.
    public convenience init(directories: AppDirectories, saveDelay: Duration = .milliseconds(1_500)) {
        self.init(fileURL: directories.libraryFile, saveDelay: saveDelay)
    }

    init(fileURL: URL?, saveDelay: Duration) {
        self.fileURL = fileURL
        self.saveDelay = saveDelay
        self.loadTask = nil
        if let fileURL {
            loadTask = Task { [weak self] in
                guard let file = await Self.decode(fileURL), let self,
                      !Task.isCancelled, !self.hasLocalChanges else { return }
                self.apply(file)
            }
        }
    }

    /// Reads and decodes `library.json` on a worker: JSON decoding a multi-MB
    /// file on the main actor stalls first-frame work.
    nonisolated private static func decode(_ url: URL) async -> LibraryFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LibraryFile.self, from: data)
    }

    /// Non-persistent store for previews and tests.
    public static func inMemory() -> LibraryStore {
        LibraryStore(fileURL: nil, saveDelay: .zero)
    }

    /// Resolves once the background `library.json` decode has been applied — or
    /// skipped because the store was mutated first. Instant for in-memory stores
    /// and once the file is loaded; `AppModel.bootstrap` awaits it so the first
    /// catalogue publish reconciles the real collections, not empty ones.
    public func awaitDiskLoad() async {
        await loadTask?.value
    }

    // MARK: - Watchlist

    public func isInWatchlist(_ id: TitleID) -> Bool { watchlistSet.contains(id) }

    public func toggleWatchlist(_ id: TitleID) {
        if isInWatchlist(id) { removeFromWatchlist(id) } else { addToWatchlist(id) }
    }

    public func addToWatchlist(_ id: TitleID) {
        watchlist.removeAll { $0 == id }
        watchlist.insert(id, at: 0)
        if watchlist.count > Self.maxWatchlist { watchlist.removeLast(watchlist.count - Self.maxWatchlist) }
        scheduleSave()
    }

    public func removeFromWatchlist(_ id: TitleID) {
        guard isInWatchlist(id) else { return }
        watchlist.removeAll { $0 == id }
        scheduleSave()
    }

    // MARK: - Dismissed suggestions

    public func isDismissed(_ id: TitleID) -> Bool { dismissedSet.contains(id) }

    /// Hides a title from recommendations (and from Ma liste, which it contradicts).
    public func dismiss(_ id: TitleID) {
        guard !isDismissed(id) else { return }
        dismissed.insert(id, at: 0)
        if dismissed.count > Self.maxDismissed { dismissed.removeLast(dismissed.count - Self.maxDismissed) }
        watchlist.removeAll { $0 == id }
        scheduleSave()
    }

    public func undismiss(_ id: TitleID) {
        guard isDismissed(id) else { return }
        dismissed.removeAll { $0 == id }
        scheduleSave()
    }

    public func clearDismissed() {
        guard !dismissed.isEmpty else { return }
        dismissed.removeAll()
        scheduleSave()
    }

    // MARK: - Favourite channels

    public func isFavorite(_ groupID: String) -> Bool { favoriteChannelSet.contains(groupID) }

    public func toggleFavorite(_ groupID: String) {
        if isFavorite(groupID) {
            favoriteChannels.removeAll { $0 == groupID }
        } else {
            favoriteChannels.append(groupID)
            if favoriteChannels.count > Self.maxFavoriteChannels {
                favoriteChannels.removeLast(favoriteChannels.count - Self.maxFavoriteChannels)
            }
        }
        scheduleSave()
    }

    public func moveFavorites(fromOffsets source: IndexSet, toOffset destination: Int) {
        let valid = source.filter { favoriteChannels.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let moving = valid.map { favoriteChannels[$0] }
        let insertion = destination - valid.filter { $0 < destination }.count
        for index in valid.sorted(by: >) { favoriteChannels.remove(at: index) }
        favoriteChannels.insert(contentsOf: moving, at: min(max(insertion, 0), favoriteChannels.count))
        if favoriteChannels.count > Self.maxFavoriteChannels {
            favoriteChannels.removeLast(favoriteChannels.count - Self.maxFavoriteChannels)
        }
        scheduleSave()
    }

    // MARK: - Progress & watched state

    public func progress(for id: ContentID) -> PlaybackProgress? { progress[id] }

    /// Latest progress recorded for any content of a grouped title.
    public func latestProgress(forTitle id: TitleID) -> PlaybackProgress? {
        // Read the observed change token even when the index is already built.
        _ = continueWatchingRevision
        if latestByTitle == nil {
            latestByTitle = Self.latestEntries(in: progress)
        }
        return latestByTitle?[id]
    }

    /// Updates the resume point in memory immediately; the disk write is debounced.
    public func updateProgress(_ newValue: PlaybackProgress) {
        guard newValue.position.isFinite, newValue.duration.isFinite, newValue.position >= 0 else { return }
        var value = newValue
        if value.titleID == nil { value.titleID = progress[value.contentID]?.titleID }
        progress[value.contentID] = value
        if value.isFinished, !watched.contains(value.contentID) { watched.insert(value.contentID) }
        pruneProgressIfNeeded()
        pruneWatchedIfNeeded()
        scheduleSave()
    }

    public func clearProgress(for id: ContentID) {
        guard progress[id] != nil else { return }
        progress[id] = nil
        scheduleSave()
    }

    public func markWatched(_ id: ContentID, titleID: TitleID?) {
        watched.insert(id)
        let existing = progress[id]
        let duration = max(existing?.duration ?? 0, 1)
        progress[id] = PlaybackProgress(
            contentID: id, titleID: titleID ?? existing?.titleID, position: duration, duration: duration, updatedAt: .now
        )
        pruneProgressIfNeeded()
        pruneWatchedIfNeeded()
        scheduleSave()
    }

    public func markUnwatched(_ id: ContentID) {
        watched.remove(id)
        progress[id] = nil
        scheduleSave()
    }

    public func isWatched(_ id: ContentID) -> Bool {
        watched.contains(id) || progress[id]?.isFinished == true
    }

    // MARK: - History

    public func recordPlayback(target: HistoryEntry.Target, contentID: ContentID) {
        let entry = HistoryEntry(target: target, lastContentID: contentID, watchedAt: .now)
        history.removeAll { $0.id == entry.id }
        history.insert(entry, at: 0)
        if history.count > Self.maxHistory { history.removeLast(history.count - Self.maxHistory) }
        scheduleSave()
    }

    public func clearHistory() {
        guard !history.isEmpty else { return }
        history.removeAll()
        scheduleSave()
    }

    // MARK: - Preferred variants

    public func setPreferredVariant(_ content: ContentID?, for title: TitleID) {
        guard preferredVariants[title] != content else { return }
        preferredVariants[title] = content
        scheduleSave()
    }

    public func preferredVariant(for title: TitleID) -> ContentID? { preferredVariants[title] }

    public func setPreferredChannelVariant(_ content: ContentID?, for groupID: String) {
        guard preferredChannelVariants[groupID] != content else { return }
        preferredChannelVariants[groupID] = content
        scheduleSave()
    }

    public func preferredChannelVariant(for groupID: String) -> ContentID? { preferredChannelVariants[groupID] }

    /// Resolve legacy title aliases after a catalog refresh. Concrete content IDs can also recover
    /// progress, history and preferred variants when a historically shared name becomes ambiguous.
    public func reconcileTitles(in catalog: Catalog) {
        var didChange = false

        var seenTitles: Set<TitleID> = []
        let resolvedWatchlist = watchlist.compactMap { id -> TitleID? in
            let resolved = catalog.title(id)?.id ?? id
            return seenTitles.insert(resolved).inserted ? resolved : nil
        }
        if resolvedWatchlist != watchlist {
            watchlist = resolvedWatchlist
            didChange = true
        }

        for (contentID, var entry) in progress {
            let resolved = catalog.titleID(containing: contentID) ?? entry.titleID.flatMap { catalog.title($0)?.id }
            if let resolved, resolved != entry.titleID {
                entry.titleID = resolved
                progress[contentID] = entry
                didChange = true
            }
        }

        var seenHistory: Set<String> = []
        let resolvedHistory = history.compactMap { entry -> HistoryEntry? in
            var entry = entry
            if case .title(let id) = entry.target,
               let resolved = catalog.titleID(containing: entry.lastContentID) ?? catalog.title(id)?.id {
                entry.target = .title(resolved)
            }
            return seenHistory.insert(entry.id).inserted ? entry : nil
        }
        if resolvedHistory != history {
            history = resolvedHistory
            didChange = true
        }

        var resolvedPreferences: [TitleID: ContentID] = [:]
        for (titleID, contentID) in preferredVariants.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let resolved = catalog.titleID(containing: contentID) ?? catalog.title(titleID)?.id ?? titleID
            if titleID == resolved || resolvedPreferences[resolved] == nil { resolvedPreferences[resolved] = contentID }
        }
        if resolvedPreferences != preferredVariants {
            preferredVariants = resolvedPreferences
            didChange = true
        }

        if didChange { scheduleSave() }
    }

    // MARK: - Continue watching

    nonisolated private static func latestEntries(
        in progress: [ContentID: PlaybackProgress], catalog: Catalog? = nil
    ) -> [TitleID: PlaybackProgress] {
        var latest: [TitleID: PlaybackProgress] = [:]
        for entry in progress.values {
            guard let titleID = entry.titleID ?? catalog?.titleID(containing: entry.contentID) else { continue }
            if let existing = latest[titleID],
               existing.updatedAt > entry.updatedAt || (existing.updatedAt == entry.updatedAt && existing.contentID > entry.contentID) {
                continue
            }
            latest[titleID] = entry
        }
        return latest
    }

    /// Movies in progress, episodes to resume and next episodes, newest activity first.
    public func continueWatching(in catalog: Catalog, limit: Int = 20) -> [ContinueWatchingItem] {
        Self.continueWatching(in: catalog, limit: limit, progress: progress, watched: watched, history: history)
    }

    /// Snapshot the library on the main actor, then resolve and sort the shelf on a worker.
    public func loadContinueWatching(in catalog: Catalog, limit: Int) async -> [ContinueWatchingItem] {
        await Self.buildContinueWatching(in: catalog, limit: limit, progress: progress, watched: watched, history: history)
    }

    @concurrent private static func buildContinueWatching(
        in catalog: Catalog, limit: Int, progress: [ContentID: PlaybackProgress],
        watched: Set<ContentID>, history: [HistoryEntry]
    ) async -> [ContinueWatchingItem] {
        continueWatching(in: catalog, limit: limit, progress: progress, watched: watched, history: history)
    }

    nonisolated private static func continueWatching(
        in catalog: Catalog, limit: Int, progress: [ContentID: PlaybackProgress],
        watched: Set<ContentID>, history: [HistoryEntry]
    ) -> [ContinueWatchingItem] {
        guard limit > 0, !Task.isCancelled else { return [] }
        let latest = latestEntries(in: progress, catalog: catalog)
        let ordered = latest.sorted {
            $0.value.updatedAt != $1.value.updatedAt ? $0.value.updatedAt > $1.value.updatedAt : $0.key.rawValue < $1.key.rawValue
        }
        var items: [ContinueWatchingItem] = []
        for (titleID, entry) in ordered {
            if Task.isCancelled { return [] }
            if items.count == limit { break }
            guard let title = catalog.title(titleID) else { continue }
            switch title.kind {
            case .series:
                guard entry.isFinished || entry.position >= 5 else { continue }
                let location = Self.locateEpisode(entry.contentID, in: title)
                if !entry.isFinished {
                    items.append(ContinueWatchingItem(
                        id: titleID.rawValue, title: title, contentID: entry.contentID, episode: location?.episode,
                        progress: entry, kind: .resume, updatedAt: entry.updatedAt
                    ))
                } else if let location {
                    guard let next = nextUnwatchedEpisode(after: location.episode, in: location.seasons, isWatched: {
                        watched.contains($0) || progress[$0]?.isFinished == true
                    }) else { continue }
                    items.append(ContinueWatchingItem(
                        id: titleID.rawValue, title: title, contentID: next.id, episode: next,
                        progress: progress[next.id], kind: .nextEpisode, updatedAt: entry.updatedAt
                    ))
                } else {
                    // Episode list unknown (Xtream series not loaded yet): offer the last one.
                    items.append(ContinueWatchingItem(
                        id: titleID.rawValue, title: title, contentID: entry.contentID, episode: nil,
                        progress: entry, kind: .resume, updatedAt: entry.updatedAt
                    ))
                }
            default:
                guard !entry.isFinished, entry.position >= 5 else { continue }
                items.append(ContinueWatchingItem(
                    id: titleID.rawValue, title: title, contentID: entry.contentID, episode: nil,
                    progress: entry, kind: .resume, updatedAt: entry.updatedAt
                ))
            }
        }

        // Series opened recently without any recorded progress.
        var addedFromHistory: Set<TitleID> = []
        for entry in history {
            guard case .title(let titleID) = entry.target, latest[titleID] == nil,
                  let title = catalog.title(titleID), title.kind == .series,
                  addedFromHistory.insert(titleID).inserted else { continue }
            items.append(ContinueWatchingItem(
                id: titleID.rawValue, title: title, contentID: entry.lastContentID, episode: nil,
                progress: nil, kind: .startSeries, updatedAt: entry.watchedAt
            ))
        }

        items.sort { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id }
        return Array(items.prefix(limit))
    }

    nonisolated static func locateEpisode(_ id: ContentID, in title: MediaTitle) -> (episode: Episode, seasons: [Season])? {
        let source = id.sourceID
        for variant in title.variants {
            guard let series = variant.series, series.sourceID == source, let seasons = series.seasons else { continue }
            for season in seasons {
                if let episode = season.episodes.first(where: { $0.id == id }) { return (episode, seasons) }
            }
        }
        return nil
    }

    nonisolated private static func nextUnwatchedEpisode(
        after episode: Episode, in seasons: [Season], isWatched: (ContentID) -> Bool
    ) -> Episode? {
        let ordered = seasons.sorted { $0.number < $1.number }
            .flatMap { $0.episodes.sorted { $0.number < $1.number } }
        guard let index = ordered.firstIndex(where: { $0.id == episode.id }) else { return nil }
        return ordered[(index + 1)...].first { !isWatched($0.id) }
    }

    // MARK: - Persistence

    /// Writes immediately (call on app termination).
    public func flush() {
        // A pending disk decode must not land after this write (it would replace
        // the flushed state in memory); an unchanged store already matches the
        // file, so quitting without mutations skips the encode entirely — unless
        // the file vanished or was corrupted externally mid-session.
        loadTask?.cancel()
        loadTask = nil
        saveTask?.cancel()
        saveTask = nil
        guard let fileURL,
              hasLocalChanges || !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        generation += 1
        let makeFile = snapshot()
        writer.writeNow(makeFile(), generation: generation, to: fileURL)
        saveCount += 1
    }

    private func scheduleSave() {
        hasLocalChanges = true
        guard fileURL != nil else { return }
        saveTask?.cancel()
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Capture the current collections here. Sorting, encoding and the write run off the main actor.
    private func saveNow() {
        guard let fileURL else { return }
        generation += 1
        let makeFile = snapshot(), generation = generation, writer = writer
        saveCount += 1
        Task.detached(priority: .utility) { writer.writeNow(makeFile(), generation: generation, to: fileURL) }
    }

    private func pruneProgressIfNeeded() {
        guard progress.count > Self.maxProgressEntries else { return }
        let keep = progress.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.maxProgressEntries)
        progress = Dictionary(uniqueKeysWithValues: keep.map { ($0.contentID, $0) })
    }

    /// `watched` has no timestamps: entries without a progress entry are the oldest (progress
    /// itself keeps only the 3 000 most recent), then the oldest resume points go first.
    private func pruneWatchedIfNeeded() {
        guard watched.count > Self.maxWatched else { return }
        let ordered = watched.sorted { lhs, rhs in
            let l = progress[lhs]?.updatedAt ?? .distantPast
            let r = progress[rhs]?.updatedAt ?? .distantPast
            return l == r ? lhs.rawValue < rhs.rawValue : l > r
        }
        watched = Set(ordered.prefix(Self.maxWatched))
    }

    /// Capture the current collections here. Encoding and the write run off the
    /// main actor; the large set/dictionary collections are written unsorted —
    /// `apply(_:)` rebuilds them by key, so file order carries no meaning and
    /// sorting ~30k ids per save (and synchronously in `flush()`) was wasted work.
    /// The small preferred-variant maps stay sorted (see below).
    private func snapshot() -> @Sendable () -> LibraryFile {
        { [watchlist, favoriteChannels, progress, watched, history, preferredVariants,
           preferredChannelVariants, storedLastChannelGroupID, dismissed] in
            LibraryFile(
                watchlist: watchlist,
                favoriteChannels: favoriteChannels,
                progress: Array(progress.values),
                watched: Array(watched),
                history: history,
                // These two stay sorted: `apply` keeps a capped prefix in file order, so an
                // unsorted write would make which entries survive nondeterministic. They are
                // small user-driven picks — sorting costs nothing next to `progress`/`watched`.
                preferredVariants: preferredVariants.map { .init(key: $0.key.rawValue, contentID: $0.value) }.sorted { $0.key < $1.key },
                preferredChannelVariants: preferredChannelVariants.map { .init(key: $0.key, contentID: $0.value) }.sorted { $0.key < $1.key },
                lastChannelGroupID: storedLastChannelGroupID,
                dismissed: dismissed
            )
        }
    }

    /// A hand-edited or corrupt `library.json` must not grow the in-memory state without bound:
    /// every collection is capped here (and again on mutation).
    private func apply(_ file: LibraryFile) {
        watchlist = Array(file.watchlist.prefix(Self.maxWatchlist))
        favoriteChannels = Array(file.favoriteChannels.prefix(Self.maxFavoriteChannels))
        progress = Dictionary(file.progress.map { ($0.contentID, $0) }, uniquingKeysWith: { $0.updatedAt >= $1.updatedAt ? $0 : $1 })
        pruneProgressIfNeeded()
        watched = Set(file.watched)
        pruneWatchedIfNeeded()
        history = Array(file.history.prefix(Self.maxHistory))
        preferredVariants = Dictionary(
            file.preferredVariants.prefix(Self.maxPreferredEntries).map { (TitleID(rawValue: $0.key), $0.contentID) },
            uniquingKeysWith: { a, _ in a }
        )
        preferredChannelVariants = Dictionary(
            file.preferredChannelVariants.prefix(Self.maxPreferredEntries).map { ($0.key, $0.contentID) },
            uniquingKeysWith: { a, _ in a }
        )
        storedLastChannelGroupID = file.lastChannelGroupID
        dismissed = Array(file.dismissed.prefix(Self.maxDismissed))
    }
}

/// Serialises library writes: a snapshot older than the last one written is dropped, so a slow
/// background write can never overwrite a newer state (e.g. the one `flush()` wrote at quit).
nonisolated final class LibraryWriter: Sendable {
    private let lastWritten = Mutex(0)

    func writeNow(_ file: LibraryFile, generation: Int, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(file) else { return }
        lastWritten.withLock { last in
            guard generation > last else { return }
            do {
                try data.write(to: url, options: [.atomic])
                last = generation
            } catch {
                // Keep the in-memory state; the next mutation retries.
            }
        }
    }
}

/// On-disk representation of the library (tolerant decoding: missing keys default to empty).
struct LibraryFile: Codable {
    struct Preferred: Codable {
        var key: String
        var contentID: ContentID
    }

    var version = 1
    var watchlist: [TitleID] = []
    var favoriteChannels: [String] = []
    var progress: [PlaybackProgress] = []
    var watched: [ContentID] = []
    var history: [HistoryEntry] = []
    var preferredVariants: [Preferred] = []
    var preferredChannelVariants: [Preferred] = []
    var lastChannelGroupID: String?
    var dismissed: [TitleID] = []

    init(
        watchlist: [TitleID], favoriteChannels: [String], progress: [PlaybackProgress], watched: [ContentID],
        history: [HistoryEntry], preferredVariants: [Preferred], preferredChannelVariants: [Preferred],
        lastChannelGroupID: String?, dismissed: [TitleID] = []
    ) {
        self.watchlist = watchlist
        self.favoriteChannels = favoriteChannels
        self.progress = progress
        self.watched = watched
        self.history = history
        self.preferredVariants = preferredVariants
        self.preferredChannelVariants = preferredChannelVariants
        self.lastChannelGroupID = lastChannelGroupID
        self.dismissed = dismissed
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        watchlist = (try? container.decodeIfPresent([TitleID].self, forKey: .watchlist)) ?? []
        favoriteChannels = (try? container.decodeIfPresent([String].self, forKey: .favoriteChannels)) ?? []
        progress = (try? container.decodeIfPresent([PlaybackProgress].self, forKey: .progress)) ?? []
        watched = (try? container.decodeIfPresent([ContentID].self, forKey: .watched)) ?? []
        history = (try? container.decodeIfPresent([HistoryEntry].self, forKey: .history)) ?? []
        preferredVariants = (try? container.decodeIfPresent([Preferred].self, forKey: .preferredVariants)) ?? []
        preferredChannelVariants = (try? container.decodeIfPresent([Preferred].self, forKey: .preferredChannelVariants)) ?? []
        lastChannelGroupID = try? container.decodeIfPresent(String.self, forKey: .lastChannelGroupID)
        dismissed = (try? container.decodeIfPresent([TitleID].self, forKey: .dismissed)) ?? []
    }
}
