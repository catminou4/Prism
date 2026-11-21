import Foundation

public struct EPGProgram: Identifiable, Codable, Sendable, Hashable {
    public var id: String { "\(channelID)|\(Int(start.timeIntervalSince1970))" }
    /// XMLTV channel id (matches `Channel.epgID`).
    public var channelID: String
    public var start: Date
    public var end: Date
    public var title: String
    public var subtitle: String?
    public var summary: String?
    public var category: String?
    /// All supplied labels when XMLTV gives multiple categories, including older caches where absent.
    public var categoryLabels: [String]?
    public var iconURL: URL?
    /// e.g. "S2 E5" when available.
    public var episodeLabel: String?
    public var rating: String?
    public var isNew: Bool

    public init(channelID: String, start: Date, end: Date, title: String, subtitle: String? = nil, summary: String? = nil, category: String? = nil, categoryLabels: [String]? = nil, iconURL: URL? = nil, episodeLabel: String? = nil, rating: String? = nil, isNew: Bool = false) {
        self.channelID = channelID
        self.start = start
        self.end = end
        self.title = title
        self.subtitle = subtitle
        self.summary = summary
        self.category = category
        self.categoryLabels = categoryLabels
        self.iconURL = iconURL
        self.episodeLabel = episodeLabel
        self.rating = rating
        self.isNew = isNew
    }

    public var interval: DateInterval { DateInterval(start: start, end: max(end, start)) }
    public func progress(at date: Date = .now) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(max(date.timeIntervalSince(start) / total, 0), 1)
    }
    public func isAiring(at date: Date = .now) -> Bool { start <= date && date < end }
}
