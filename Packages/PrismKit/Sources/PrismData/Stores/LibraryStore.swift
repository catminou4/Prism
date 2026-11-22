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
    public private(set) var watchlist: [TitleID] = []
    /// Channel group ids, in user order.
    public private(set) var favoriteChannels: [String] = []
    public private(set) var progress: [ContentID: PlaybackProgress] = [:]
    public private(set) var watched: Set<ContentID> = []
    /// Newest first, deduplicated by entry id, at most `maxHistory` entries.
    public private(set) var history: [HistoryEntry] = []
    public private(set) var preferredVariants: [TitleID: ContentID] = [:]
    public private(set) var preferredChannelVariants: [String: ContentID] = [:]
    /// Titles the user marked “Pas intéressé”: never suggested again by the curated shelves.
    public private(set) var dismissed: [TitleID] = []

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

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let saveDelay: Duration
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Number of disk writes performed (tests).
    @ObservationIgnored private(set) var saveCount = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let writer = LibraryWriter()

    /// Loads `library.json` synchronously (small file).
    public convenience init(directories: AppDirectories, saveDelay: Duration = .milliseconds(1_500)) {
        self.init(fileURL: directories.libraryFile, saveDelay: saveDelay)
    }

    init(fileURL: URL?, saveDelay: Duration) {
        self.fileURL = fileURL
        self.saveDelay = saveDelay
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let file = try? decoder.decode(LibraryFile.self, from: data) {
                apply(file)
            }
        }
    }

    /// Non-persistent store for previews and tests.
    public static func inMemory() -> LibraryStore {
        LibraryStore(fileURL: nil, saveDelay: .zero)
    }

    // MARK: - Watchlist

    public func isInWatchlist(_ id: TitleID) -> Bool { watchlist.contains(id) }

    public func toggleWatchlist(_ id: TitleID) {
        if isInWatchlist(id) { removeFromWatchlist(id) } else { addToWatchlist(id) }
    }

    public func addToWatchlist(_ id: TitleID) {
        watchlist.removeAll { $0 == id }
        watchlist.insert(id, at: 0)
        scheduleSave()
    }

    public func removeFromWatchlist(_ id: TitleID) {
        guard isInWatchlist(id) else { return }
        watchlist.removeAll { $0 == id }
        scheduleSave()
    }

    // MARK: - Dismissed suggestions

    public func isDismissed(_ id: TitleID) -> Bool { dismissed.contains(id) }

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

    public func isFavorite(_ groupID: String) -> Bool { favoriteChannels.contains(groupID) }

    public func toggleFavorite(_ groupID: String) {
        if isFavorite(groupID) {
            favoriteChannels.removeAll { $0 == groupID }
        } else {
            favoriteChannels.append(groupID)
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
        scheduleSave()
    }

    // MARK: - Progress & watched state

    public func progress(for id: ContentID) -> PlaybackProgress? { progress[id] }

    /// Latest progress recorded for any content of a grouped title.
    public func latestProgress(forTitle id: TitleID) -> PlaybackProgress? {
        progress.values.filter { $0.titleID == id }.max { $0.updatedAt < $1.updatedAt }
    }

    /// Updates the resume point in memory immediately; the disk write is debounced.
    public func updateProgress(_ newValue: PlaybackProgress) {
        guard newValue.position.isFinite, newValue.duration.isFinite, newValue.position >= 0 else { return }
        var value = newValue
        if value.titleID == nil { value.titleID = progress[value.contentID]?.titleID }
        progress[value.contentID] = value
        if value.isFinished { watched.insert(value.contentID) }
        pruneProgressIfNeeded()
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

    /// Movies in progress, episodes to resume and next episodes, newest activity first.
    public func continueWatching(in catalog: Catalog, limit: Int = 20) -> [ContinueWatchingItem] {
        guard limit > 0 else { return [] }
        var latest: [TitleID: PlaybackProgress] = [:]
        for entry in progress.values {
            guard let titleID = entry.titleID ?? catalog.titleID(containing: entry.contentID) else { continue }
            if let existing = latest[titleID],
               existing.updatedAt > entry.updatedAt || (existing.updatedAt == entry.updatedAt && existing.contentID > entry.contentID) {
                continue
            }
            latest[titleID] = entry
        }

        var items: [ContinueWatchingItem] = []
        for (titleID, entry) in latest {
            guard let title = catalog.title(titleID) else { continue }
            switch title.kind {
            case .series:
                let location = Self.locateEpisode(entry.contentID, in: title)
                if !entry.isFinished {
                    guard entry.position >= 5 else { continue }
                    items.append(ContinueWatchingItem(
                        id: titleID.rawValue, title: title, contentID: entry.contentID, episode: location?.episode,
                        progress: entry, kind: .resume, updatedAt: entry.updatedAt
                    ))
                } else if let location {
                    guard let next = nextUnwatchedEpisode(after: location.episode, in: location.seasons) else { continue }
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
        let known = Set(latest.keys)
        for entry in history {
            guard case .title(let titleID) = entry.target, !known.contains(titleID),
                  let title = catalog.title(titleID), title.kind == .series,
                  !items.contains(where: { $0.id == titleID.rawValue }) else { continue }
            items.append(ContinueWatchingItem(
                id: titleID.rawValue, title: title, contentID: entry.lastContentID, episode: nil,
                progress: nil, kind: .startSeries, updatedAt: entry.watchedAt
            ))
        }

        items.sort { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id }
        return Array(items.prefix(limit))
    }

    static func locateEpisode(_ id: ContentID, in title: MediaTitle) -> (episode: Episode, seasons: [Season])? {
        let source = id.sourceID
        for variant in title.variants {
            guard let series = variant.series, series.sourceID == source, let seasons = series.seasons else { continue }
            for season in seasons {
                if let episode = season.episodes.first(where: { $0.id == id }) { return (episode, seasons) }
            }
        }
        return nil
    }

    private func nextUnwatchedEpisode(after episode: Episode, in seasons: [Season]) -> Episode? {
        let ordered = seasons.sorted { $0.number < $1.number }
            .flatMap { $0.episodes.sorted { $0.number < $1.number } }
        guard let index = ordered.firstIndex(where: { $0.id == episode.id }) else { return nil }
        return ordered[(index + 1)...].first { !isWatched($0.id) }
    }

    // MARK: - Persistence

    /// Writes immediately (call on app termination).
    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard let fileURL else { return }
        generation += 1
        writer.writeNow(snapshot(), generation: generation, to: fileURL)
        saveCount += 1
    }

    private func scheduleSave() {
        guard fileURL != nil else { return }
        saveTask?.cancel()
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// The state is captured here; encoding and the atomic write run off the main actor
    /// (they took 10–50 ms with a full history, during playback).
    private func saveNow() {
        guard let fileURL else { return }
        generation += 1
        let file = snapshot(), generation = generation, writer = writer
        saveCount += 1
        Task.detached(priority: .utility) { writer.writeNow(file, generation: generation, to: fileURL) }
    }

    private func pruneProgressIfNeeded() {
        guard progress.count > Self.maxProgressEntries else { return }
        let keep = progress.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.maxProgressEntries)
        progress = Dictionary(uniqueKeysWithValues: keep.map { ($0.contentID, $0) })
    }

    private func snapshot() -> LibraryFile {
        LibraryFile(
            watchlist: watchlist,
            favoriteChannels: favoriteChannels,
            progress: progress.values.sorted { $0.contentID < $1.contentID },
            watched: watched.sorted(),
            history: history,
            preferredVariants: preferredVariants.map { .init(key: $0.key.rawValue, contentID: $0.value) }.sorted { $0.key < $1.key },
            preferredChannelVariants: preferredChannelVariants.map { .init(key: $0.key, contentID: $0.value) }.sorted { $0.key < $1.key },
            lastChannelGroupID: storedLastChannelGroupID,
            dismissed: dismissed
        )
    }

    private func apply(_ file: LibraryFile) {
        watchlist = file.watchlist
        favoriteChannels = file.favoriteChannels
        progress = Dictionary(file.progress.map { ($0.contentID, $0) }, uniquingKeysWith: { $0.updatedAt >= $1.updatedAt ? $0 : $1 })
        watched = Set(file.watched)
        history = Array(file.history.prefix(Self.maxHistory))
        preferredVariants = Dictionary(file.preferredVariants.map { (TitleID(rawValue: $0.key), $0.contentID) }, uniquingKeysWith: { a, _ in a })
        preferredChannelVariants = Dictionary(file.preferredChannelVariants.map { ($0.key, $0.contentID) }, uniquingKeysWith: { a, _ in a })
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
