import Foundation

extension SourceCatalog {
    /// Makes items share one copy of the values they repeat.
    ///
    /// Decoding (from the provider or the cache) gives every item its own copy of its source id,
    /// category id and tag or genre list, although a catalogue has one source, a few hundred
    /// categories and a handful of distinct lists. Sharing them saves around 200 bytes per item
    /// (tens of megabytes on large catalogues). Values are unchanged.
    public mutating func shareRepeatedValues() {
        var pool = ValuePool()
        let source = sourceID
        for index in channels.indices {
            if channels[index].sourceID == source { channels[index].sourceID = source }
            channels[index].categoryID = pool.share(channels[index].categoryID)
            channels[index].tags = pool.share(channels[index].tags)
            if !channels[index].httpHeaders.isEmpty { channels[index].httpHeaders = pool.share(channels[index].httpHeaders) }
        }
        for index in movies.indices {
            if movies[index].sourceID == source { movies[index].sourceID = source }
            movies[index].categoryID = pool.share(movies[index].categoryID)
            movies[index].tags = pool.share(movies[index].tags)
            movies[index].genres = pool.share(movies[index].genres)
            movies[index].containerExtension = pool.share(movies[index].containerExtension)
            if !movies[index].httpHeaders.isEmpty { movies[index].httpHeaders = pool.share(movies[index].httpHeaders) }
        }
        for index in series.indices {
            if series[index].sourceID == source { series[index].sourceID = source }
            series[index].categoryID = pool.share(series[index].categoryID)
            series[index].tags = pool.share(series[index].tags)
            series[index].genres = pool.share(series[index].genres)
        }
    }
}

/// Returns the first stored copy of equal values.
private struct ValuePool {
    private var strings: [String: String] = [:]
    private var lists: [[String]: [String]] = [:]
    private var headers: [[String: String]: [String: String]] = [:]

    mutating func share(_ value: String?) -> String? {
        guard let value else { return nil }
        // Up to 15 UTF-8 bytes live inline in the String itself: nothing to share.
        guard value.utf8.count > 15 else { return value }
        if let existing = strings[value] { return existing }
        strings[value] = value
        return value
    }

    mutating func share(_ value: [String]) -> [String] {
        guard !value.isEmpty else { return value }
        if let existing = lists[value] { return existing }
        lists[value] = value
        return value
    }

    mutating func share(_ value: [String: String]) -> [String: String] {
        if let existing = headers[value] { return existing }
        headers[value] = value
        return value
    }
}
