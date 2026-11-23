import Foundation
import PrismCore

public enum BroadcastSport: String, CaseIterable, Sendable, Hashable {
    case football, basketball, boxing

    public init(league: SportsLeague) {
        switch league {
        case .championsLeague, .ligue1: self = .football
        case .nba: self = .basketball
        case .boxing: self = .boxing
        }
    }

    public var displayName: String {
        switch self {
        case .football: "Football"
        case .basketball: "Basket-ball"
        case .boxing: "Boxe"
        }
    }
}

/// A programme in the user's XMLTV guide with a matching channel in the active catalog.
public struct SportsBroadcast: Identifiable, Sendable, Hashable {
    public var id: String { "\(channel.id)|\(program.id)" }
    public let channel: ChannelGroup
    public let program: EPGProgram
    public let sport: BroadcastSport
    /// A concrete stream whose explicit XMLTV reference matches the programme, when available.
    public let guideVariantID: ContentID?

    public init(channel: ChannelGroup, program: EPGProgram, sport: BroadcastSport) {
        self.channel = channel
        self.program = program
        self.sport = sport
        let epgID = program.channelID.trimmingCharacters(in: .whitespaces).lowercased()
        self.guideVariantID = channel.variants.first { variant in
            variant.epgID?.trimmingCharacters(in: .whitespaces).lowercased() == epgID
        }?.id
    }
}

extension EPGGuide {
    @concurrent public func sportsSchedule(channels: [ChannelGroup], in interval: DateInterval) async -> [SportsBroadcast] {
        guard !isEmpty else { return [] }
        var result: [SportsBroadcast] = []
        var programsByID: [String: [(EPGProgram, BroadcastSport)]] = [:]
        // Guides repeat the same shows across days and channels: classify each distinct text once.
        var classified: [SportsScheduleMatcher.ClassifyKey: BroadcastSport?] = [:]
        for channel in channels {
            guard !Task.isCancelled else { return [] }
            guard !channel.variants.isEmpty, let id = resolveEPGID(for: channel) else { continue }
            let sports: [(EPGProgram, BroadcastSport)]
            if let cached = programsByID[id] {
                sports = cached
            } else {
                // Scan the channel's sorted list in place: `programs(forEPGID:in:)`
                // would copy every programme of the 8-day window per channel first.
                var matched: [(EPGProgram, BroadcastSport)] = []
                if let list = programsByChannel[id], !list.isEmpty {
                    var index = EPGGuide.firstIndex(in: list, endingAfter: interval.start)
                    while index < list.count, list[index].start < interval.end {
                        let program = list[index]
                        if let sport = SportsScheduleMatcher.classify(program, memo: &classified) {
                            matched.append((program, sport))
                        }
                        index += 1
                    }
                }
                sports = matched
                programsByID[id] = sports
            }
            for (program, sport) in sports {
                result.append(SportsBroadcast(channel: channel, program: program, sport: sport))
            }
        }
        return result.sorted { lhs, rhs in
            if lhs.program.start != rhs.program.start { return lhs.program.start < rhs.program.start }
            if lhs.channel.name != rhs.channel.name { return lhs.channel.name.localizedStandardCompare(rhs.channel.name) == .orderedAscending }
            return lhs.id < rhs.id
        }
    }
}

public enum SportsScheduleMatcher {
    /// Relates a score fixture to verified matches in the user's guide.
    @concurrent public static func match(events: [SportsEvent], broadcasts: [SportsBroadcast]) async -> [String: [SportsBroadcast]] {
        let candidates: [(broadcast: SportsBroadcast, text: String, league: SportsLeague?)] = broadcasts.compactMap { broadcast in
            let title = labelledTitle(broadcast.program)
            guard !containsAny(title, companionShowLabels) else { return nil }
            return (broadcast, title, leagueEvidence(for: broadcast.program))
        }
        var result: [String: [SportsBroadcast]] = [:]
        for event in events {
            guard !Task.isCancelled else { return [:] }
            guard event.status != .cancelled, event.status != .postponed else { continue }
            let expectedSport = BroadcastSport(league: event.league)
            let home = names(for: event.home, in: event.league)
            let away = names(for: event.away, in: event.league)
            let shared = home.intersection(away)
            let homeEvidence = home.subtracting(shared)
            let awayEvidence = away.subtracting(shared)
            guard !homeEvidence.isEmpty, !awayEvidence.isEmpty else { continue }
            for candidate in candidates {
                let broadcast = candidate.broadcast
                let offset = broadcast.program.start.timeIntervalSince(event.startsAt)
                guard broadcast.sport == expectedSport, offset >= -2_700, offset <= 900,
                      event.startsAt < broadcast.program.end else { continue }
                if let league = candidate.league, league != event.league { continue }
                if hasBothTeams(homeEvidence, awayEvidence, in: candidate.text) {
                    result[event.id, default: []].append(broadcast)
                }
            }
        }
        return result
    }

    /// Memo key on the programme's raw inputs: equal inputs always classify identically, so the
    /// lookup never concatenates the texts — the joined string is only built on a miss, for the
    /// byte-level `mayMentionSport` prefilter.
    struct ClassifyKey: Hashable {
        var title: String
        var subtitle: String?
        var categoryLabels: [String]?
        var category: String?
    }

    /// `classify` with a memo keyed by the programme's raw texts, after a byte-level check that
    /// rules out most programmes without normalizing their text.
    static func classify(_ program: EPGProgram, memo: inout [ClassifyKey: BroadcastSport?]) -> BroadcastSport? {
        let key = ClassifyKey(
            title: program.title, subtitle: program.subtitle,
            categoryLabels: program.categoryLabels, category: program.category
        )
        if let known = memo[key] { return known }
        let categories = program.categoryLabels?.joined(separator: " ") ?? program.category ?? ""
        let raw = program.title + "\u{1F}" + (program.subtitle ?? "") + "\u{1F}" + categories
        let sport = mayMentionSport(raw) ? classify(program) : nil
        memo[key] = sport
        return sport
    }

    /// Lowercase ASCII stems of every keyword `classify` accepts.
    private static let sportStems: [[UInt8]] = [
        "box", "basket", "nba", "euroleague", "football", "soccer", "uefa", "ligue", "europa", "conference",
    ].map { Array($0.utf8) }

    /// `false` only when no sport keyword can appear once the text is folded. Text with non-ASCII
    /// characters could fold into one (accents, wide letters): it always goes to the full matcher.
    static func mayMentionSport(_ text: String) -> Bool {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        for byte in text.utf8 {
            if byte >= 0x80 { return true }
            bytes.append(byte >= 65 && byte <= 90 ? byte + 32 : byte)
        }
        return bytes.withUnsafeBufferPointer { haystack in
            sportStems.contains { stem in
                stem.withUnsafeBufferPointer { needle in
                    guard let h = haystack.baseAddress, let n = needle.baseAddress, haystack.count >= needle.count else { return false }
                    return memmem(h, haystack.count, n, needle.count) != nil
                }
            }
        }
    }

    static func classify(_ program: EPGProgram) -> BroadcastSport? {
        let title = labelledTitle(program)
        let category = labelledCategories(program)
        guard !containsAny(title, nonMatchLabels), !containsAny(category, nonMatchLabels) else { return nil }
        if containsAny(title, ["boxe", "boxing"]) || containsAny(category, ["boxe", "boxing"]) { return .boxing }
        if containsAny(title, ["basket", "basketball", "basket ball", "nba", "wnba", "euroleague"])
            || containsAny(category, ["basket", "basketball", "basket ball", "nba", "wnba", "euroleague"]) { return .basketball }
        let otherFootball = [
            "nfl", "american football", "football americain", "ncaa football", "college football", "ncaaf",
            "super bowl", "futsal", "handball", "hockey",
        ]
        guard !containsAny(title, otherFootball), !containsAny(category, otherFootball) else { return nil }
        let football = ["football", "soccer", "uefa", "ligue des champions", "ligue 1", "europa league", "conference league"]
        if containsAny(title, football) || containsAny(category, football) { return .football }
        return nil
    }

    private static func labelledTitle(_ program: EPGProgram) -> String {
        " \(TitleNormalizer.key(program.title + " " + (program.subtitle ?? ""))) "
    }

    private static func labelledCategories(_ program: EPGProgram) -> String {
        let labels = program.categoryLabels?.joined(separator: " ") ?? program.category ?? ""
        return " \(TitleNormalizer.key(labels)) "
    }

    private static func leagueEvidence(for program: EPGProgram) -> SportsLeague? {
        let description = labelledTitle(program) + labelledCategories(program)
        if containsAny(description, ["champions league", "ligue des champions", "ucl"]) { return .championsLeague }
        if containsAny(description, ["ligue 1", "ligue one"]) { return .ligue1 }
        if containsAny(description, ["nba"]) { return .nba }
        if containsAny(description, ["boxe", "boxing"]) { return .boxing }
        return nil
    }

    private static func names(for team: SportsTeam, in league: SportsLeague) -> Set<String> {
        let fullName = TitleNormalizer.key(team.name)
        let abbreviation = TitleNormalizer.key(team.abbreviation)
        var names: Set<String> = []
        if !fullName.isEmpty { names.insert(fullName) }
        if abbreviation.count >= 3 { names.insert(abbreviation) }
        if league == .nba || league == .boxing {
            if let nickname = fullName.split(separator: " ").last, nickname.count >= 4 { names.insert(String(nickname)) }
        } else {
            for aliases in footballAliases where aliases.contains(fullName) || aliases.contains(abbreviation) {
                names.formUnion(aliases)
            }
        }
        return names
    }

    private static func hasBothTeams(_ home: Set<String>, _ away: Set<String>, in title: String) -> Bool {
        home.contains { first in
            guard let homeMatch = title.range(of: " \(first) ") else { return false }
            return away.contains { second in
                guard let awayMatch = title.range(of: " \(second) ") else { return false }
                // Adjacent names can share a delimiting space, while nested aliases are one mention.
                return homeMatch.upperBound <= title.index(after: awayMatch.lowerBound)
                    || awayMatch.upperBound <= title.index(after: homeMatch.lowerBound)
            }
        }
    }

    private static let footballAliases: [[String]] = [
        ["paris saint germain", "paris sg", "psg"],
        ["olympique de marseille", "olympique marseille", "marseille", "om"],
        ["olympique lyonnais", "lyon", "ol"],
        ["as monaco", "monaco"],
        ["inter milan", "inter milano", "internazionale", "inter"],
        ["bayern munchen", "bayern munich", "fc bayern", "bayern"],
        ["manchester united", "man united", "man utd"],
        ["manchester city", "man city"],
        ["fc barcelona", "fc barcelone", "barcelona", "barcelone", "barca"],
    ]

    private static let nonMatchLabels = [
        "magazine", "talk show", "sportscenter", "highlights", "resume", "resumes", "rediffusion", "archives",
        "actualites", "news", "retrospective", "documentaire", "le mag", "sports center",
    ]

    // Studio shows can name the same teams and run past kickoff in the guide.
    private static let companionShowLabels = [
        "avant match", "avant le match", "pre match", "pre game", "pregame", "preview",
        "apres match", "apres le match", "post match", "post game", "postgame", "debrief",
    ]

    private static func containsAny(_ value: String, _ phrases: [String]) -> Bool {
        phrases.contains { value.contains(" \($0) ") }
    }
}
