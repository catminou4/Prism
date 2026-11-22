import Foundation
import PrismCore
import Synchronization

/// Immutable, indexed TV guide (one or several XMLTV feeds merged).
///
/// Programmes are grouped by lowercased XMLTV channel id, sorted by start, with duplicates removed
/// and overlaps trimmed, so that per-channel lists are strictly ordered and binary-searchable.
public struct EPGGuide: Sendable {
    public static let empty = EPGGuide(programs: [])

    let programsByChannel: [String: [EPGProgram]]
    let channelsByID: [String: XMLTVChannel]
    /// Normalized channel name → lowercased channel id (only channels that have programmes).
    let nameIndex: [String: String]
    /// Channel → guide id, filled as views ask (name matching normalizes text: too slow to redo per row).
    private let resolutions = ResolutionMemo()

    public let programCount: Int

    public init(programs: [EPGProgram], channels: [XMLTVChannel] = []) {
        var grouped: [String: [EPGProgram]] = [:]
        // Programmes of a channel share the same raw id: normalize each distinct id once.
        var keys: [String: String] = [:]
        for program in programs {
            let id: String
            if let known = keys[program.channelID] {
                id = known
            } else {
                id = program.channelID.trimmingCharacters(in: .whitespaces).lowercased()
                keys[program.channelID] = id
            }
            guard !id.isEmpty else { continue }
            grouped[id, default: []].append(program)
        }
        var cleaned: [String: [EPGProgram]] = Dictionary(minimumCapacity: grouped.count)
        var count = 0
        for (id, list) in grouped {
            let normalized = Self.normalize(list)
            guard !normalized.isEmpty else { continue }
            cleaned[id] = normalized
            count += normalized.count
        }
        var channelsByID: [String: XMLTVChannel] = [:]
        for channel in channels {
            let id = channel.id.trimmingCharacters(in: .whitespaces).lowercased()
            guard !id.isEmpty, channelsByID[id] == nil else { continue }
            channelsByID[id] = channel
        }
        self.init(programsByChannel: cleaned, channelsByID: channelsByID, programCount: count)
    }

    private init(programsByChannel: [String: [EPGProgram]], channelsByID: [String: XMLTVChannel], programCount: Int) {
        self.programsByChannel = programsByChannel
        self.channelsByID = channelsByID
        self.programCount = programCount
        self.nameIndex = Self.makeNameIndex(programsByChannel: programsByChannel, channelsByID: channelsByID)
    }

    /// Number of channels that have at least one programme.
    public var channelCount: Int { programsByChannel.count }
    public var isEmpty: Bool { programsByChannel.isEmpty }
    /// Lowercased ids of the channels that have programmes.
    public var channelIDs: Dictionary<String, [EPGProgram]>.Keys { programsByChannel.keys }
    /// Every programme (per channel, sorted), e.g. for caching.
    public var allPrograms: [EPGProgram] { programsByChannel.values.flatMap { $0 } }
    /// XMLTV channel descriptions (display names, icons).
    public var xmltvChannels: [XMLTVChannel] { Array(channelsByID.values) }

    public func xmltvChannel(forEPGID id: String) -> XMLTVChannel? {
        channelsByID[id.lowercased()]
    }

    /// Whether the guide has programmes for this XMLTV id (case-insensitive).
    public func hasPrograms(forEPGID id: String) -> Bool {
        programsByChannel[id.lowercased()] != nil
    }

    /// Programmes intersecting `interval`, in order (binary search).
    public func programs(forEPGID id: String, in interval: DateInterval) -> [EPGProgram] {
        guard let list = programsByChannel[id.lowercased()], !list.isEmpty else { return [] }
        var index = Self.firstIndex(in: list, endingAfter: interval.start)
        var result: [EPGProgram] = []
        while index < list.count, list[index].start < interval.end {
            result.append(list[index])
            index += 1
        }
        return result
    }

    /// The programme airing at `date` and the following one.
    public func nowAndNext(forEPGID id: String, at date: Date) -> (now: EPGProgram?, next: EPGProgram?) {
        guard let list = programsByChannel[id.lowercased()], !list.isEmpty else { return (nil, nil) }
        let index = Self.firstIndex(in: list, endingAfter: date)
        guard index < list.count else { return (nil, nil) }
        let candidate = list[index]
        if candidate.start <= date {
            return (candidate, index + 1 < list.count ? list[index + 1] : nil)
        }
        return (nil, candidate)
    }

    /// Guide id to use for a channel group: its `epgID` (or a variant's) when the guide knows it,
    /// otherwise a match of the normalized channel name against the XMLTV display names.
    public func resolveEPGID(for channel: ChannelGroup) -> String? {
        guard !programsByChannel.isEmpty else { return nil }
        // The group id alone could outlive a catalogue rebuild that added variants.
        let key = "\(channel.id)|\(channel.epgID ?? "")|\(channel.variants.count)"
        if let known = resolutions.value(for: key) { return known }
        let id = resolveUncached(channel)
        resolutions.store(id, for: key)
        return id
    }

    private func resolveUncached(_ channel: ChannelGroup) -> String? {
        if let id = matchingEPGID(channel.epgID) { return id }
        for variant in channel.variants where variant.epgID != channel.epgID {
            if let id = matchingEPGID(variant.epgID) { return id }
        }
        guard !nameIndex.isEmpty else { return nil }
        if let id = epgID(named: channel.name) { return id }
        for variant in channel.variants where variant.name != channel.name {
            if let id = epgID(named: variant.name) { return id }
        }
        return nameIndex[channel.id]
    }

    /// Union of both guides; on conflicting programmes `self` wins.
    public func merging(_ other: EPGGuide) -> EPGGuide {
        Self.merged([self, other])
    }

    /// Union of `guides`; on conflicting programmes the earlier guide wins. The name index is built
    /// once for the result (merging pairwise rebuilt it for every intermediate guide).
    public static func merged(_ guides: [EPGGuide]) -> EPGGuide {
        let filled = guides.filter { !$0.programsByChannel.isEmpty || !$0.channelsByID.isEmpty }
        guard filled.count > 1 else { return filled.first ?? .empty }
        var programs = filled[0].programsByChannel
        var channels = filled[0].channelsByID
        var count = filled[0].programCount
        for other in filled.dropFirst() {
            for (id, list) in other.programsByChannel {
                if let existing = programs[id] {
                    // Both lists are already sorted and cleaned: a linear merge replaces a re-sort.
                    let merged = clean(mergeSorted(existing, list))
                    count += merged.count - existing.count
                    programs[id] = merged
                } else {
                    programs[id] = list
                    count += list.count
                }
            }
            for (id, channel) in other.channelsByID where channels[id] == nil {
                channels[id] = channel
            }
        }
        return EPGGuide(programsByChannel: programs, channelsByID: channels, programCount: count)
    }

    // MARK: - Internals

    private func matchingEPGID(_ candidate: String?) -> String? {
        guard let candidate else { return nil }
        let id = candidate.trimmingCharacters(in: .whitespaces).lowercased()
        return programsByChannel[id] == nil ? nil : id
    }

    private func epgID(named name: String) -> String? {
        let cleaned = TitleNormalizer.normalize(name).key
        if let id = nameIndex[cleaned] { return id }
        return nameIndex[TitleNormalizer.key(name)]
    }

    /// Sorted by start; drops empty/duplicate programmes and trims overlaps (earlier programme ends
    /// when the next one starts).
    static func normalize(_ programs: [EPGProgram]) -> [EPGProgram] {
        let sorted = programs.enumerated().sorted {
            $0.element.start != $1.element.start ? $0.element.start < $1.element.start : $0.offset < $1.offset
        }
        return clean(sorted.map(\.element))
    }

    /// Stable merge of two lists sorted by start (`first` wins ties).
    static func mergeSorted(_ first: [EPGProgram], _ second: [EPGProgram]) -> [EPGProgram] {
        var result: [EPGProgram] = []
        result.reserveCapacity(first.count + second.count)
        var i = 0, j = 0
        while i < first.count, j < second.count {
            if second[j].start < first[i].start {
                result.append(second[j]); j += 1
            } else {
                result.append(first[i]); i += 1
            }
        }
        result.append(contentsOf: first[i...])
        result.append(contentsOf: second[j...])
        return result
    }

    /// Drops empty/duplicate programmes of a start-sorted list and trims overlaps.
    static func clean(_ sorted: [EPGProgram]) -> [EPGProgram] {
        var result: [EPGProgram] = []
        result.reserveCapacity(sorted.count)
        for program in sorted {
            guard program.end > program.start else { continue }
            if let last = result.last {
                if program.start == last.start { continue }
                if program.start < last.end {
                    result[result.count - 1].end = program.start
                }
            }
            result.append(program)
        }
        return result
    }

    /// First index whose programme ends after `date` (lists are sorted and non-overlapping, so ends are sorted too).
    static func firstIndex(in list: [EPGProgram], endingAfter date: Date) -> Int {
        var low = 0, high = list.count
        while low < high {
            let mid = (low + high) / 2
            if list[mid].end <= date { low = mid + 1 } else { high = mid }
        }
        return low
    }

    static func nameKeys(_ name: String) -> [String] {
        let plain = TitleNormalizer.key(name)
        let cleaned = TitleNormalizer.normalize(name).key
        var keys: [String] = []
        if !cleaned.isEmpty { keys.append(cleaned) }
        if !plain.isEmpty, plain != cleaned { keys.append(plain) }
        return keys
    }

    /// "TF1.fr" → "TF1", "france2.fr@SD" → "france2".
    static func strippedChannelID(_ id: String) -> String {
        var value = id
        if let at = value.firstIndex(of: "@") { value = String(value[..<at]) }
        if let dot = value.lastIndex(of: "."), value.distance(from: dot, to: value.endIndex) <= 4,
           value.distance(from: value.startIndex, to: dot) > 0 {
            value = String(value[..<dot])
        }
        return value
    }

    private static func makeNameIndex(programsByChannel: [String: [EPGProgram]], channelsByID: [String: XMLTVChannel]) -> [String: String] {
        var index: [String: String] = [:]
        // Deterministic: visit channel ids in sorted order, display names before ids.
        let ids = programsByChannel.keys.sorted()
        for id in ids {
            guard let channel = channelsByID[id] else { continue }
            for name in channel.displayNames {
                for key in nameKeys(name) where index[key] == nil { index[key] = id }
            }
        }
        for id in ids {
            let original = channelsByID[id]?.id ?? programsByChannel[id]?.first?.channelID ?? id
            for key in nameKeys(strippedChannelID(original)) where index[key] == nil { index[key] = id }
        }
        return index
    }
}

/// Thread-safe memo shared by the copies of one guide (a guide is immutable).
private final class ResolutionMemo: Sendable {
    private let storage = Mutex<[String: String?]>([:])

    func value(for key: String) -> String?? {
        storage.withLock { $0[key] }
    }

    func store(_ value: String?, for key: String) {
        storage.withLock { $0[key] = .some(value) }
    }
}
