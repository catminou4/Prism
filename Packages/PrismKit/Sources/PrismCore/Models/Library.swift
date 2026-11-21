import Foundation

/// Resume point of a movie or episode.
public struct PlaybackProgress: Codable, Sendable, Hashable, Identifiable {
    public var id: ContentID { contentID }
    public var contentID: ContentID
    /// Grouped title (movie or series) this content belongs to, when known.
    public var titleID: TitleID?
    public var position: TimeInterval
    public var duration: TimeInterval
    public var updatedAt: Date

    public init(contentID: ContentID, titleID: TitleID? = nil, position: TimeInterval, duration: TimeInterval, updatedAt: Date = .now) {
        self.contentID = contentID
        self.titleID = titleID
        self.position = position
        self.duration = duration
        self.updatedAt = updatedAt
    }

    public var fraction: Double { duration > 0 ? min(max(position / duration, 0), 1) : 0 }
    /// Short episodes must reach 95 %. Longer programmes allow two minutes for the credits.
    public var isFinished: Bool {
        duration > 0 && (fraction >= 0.95 || (duration >= 20 * 60 && remaining < 120))
    }
    public var remaining: TimeInterval { max(duration - position, 0) }
}

/// An entry of the "Récemment regardés" history.
public struct HistoryEntry: Codable, Sendable, Hashable, Identifiable {
    public enum Target: Codable, Sendable, Hashable {
        case title(TitleID)
        case channel(groupID: String)
    }

    public var id: String {
        switch target {
        case .title(let t): "t:\(t.rawValue)"
        case .channel(let c): "c:\(c)"
        }
    }
    public var target: Target
    /// The concrete content last played (episode, movie variant or channel variant).
    public var lastContentID: ContentID
    public var watchedAt: Date

    public init(target: Target, lastContentID: ContentID, watchedAt: Date = .now) {
        self.target = target
        self.lastContentID = lastContentID
        self.watchedAt = watchedAt
    }
}
