import Foundation

extension SourceCatalog {
    /// Returns the catalogue with every movie and series plot replaced by
    /// `ProviderSynopsis.cleaned(plot)` and `plotsCleaned` set.
    ///
    /// Cleaning splits multi-translation synopses and runs `NLLanguageRecognizer` per
    /// paragraph — ~250 µs per affected plot, ≈1 s of wall time (≈6 s CPU) per launch on a
    /// 25k-series catalogue when the builder did it. Running it once when a catalogue is
    /// imported (and persisting the flag in the cache) takes it off the launch path; the
    /// builder output is identical because it selected and kept the cleaned text anyway.
    @concurrent
    public func cleaningPlots() async -> SourceCatalog {
        guard !plotsCleaned else { return self }
        var catalog = self
        catalog.movies = await Self.cleaned(movies)
        catalog.series = await Self.cleaned(series)
        catalog.plotsCleaned = true
        return catalog
    }

    /// Cleans `items` in parallel chunks, preserving order. Clean plots (the vast majority)
    /// only pay `ProviderSynopsis.cleaned`'s trim + whitespace scan.
    private static func cleaned<Item: SynopsisCarrying>(_ items: [Item]) async -> [Item] {
        guard !items.isEmpty else { return items }
        let chunk = 2_048
        let chunkCount = (items.count + chunk - 1) / chunk
        let parts = await withTaskGroup(of: (Int, [Item]).self) { group in
            for index in 0..<chunkCount {
                let range = (index * chunk)..<min(items.count, (index + 1) * chunk)
                group.addTask {
                    var part = Array(items[range])
                    for offset in part.indices {
                        guard let raw = part[offset].plot else { continue }
                        let cleaned = ProviderSynopsis.cleaned(raw)
                        if cleaned != raw { part[offset].plot = cleaned }
                    }
                    return (index, part)
                }
            }
            var parts = [[Item]](repeating: [], count: chunkCount)
            for await (index, part) in group { parts[index] = part }
            return parts
        }
        var result: [Item] = []
        result.reserveCapacity(items.count)
        for part in parts { result += part }
        return result
    }
}

/// Catalogue items whose `plot` the builder cleans (movies and series; episode plots are
/// shown as provided).
protocol SynopsisCarrying: Sendable {
    var plot: String? { get set }
}

extension Movie: SynopsisCarrying {}
extension Series: SynopsisCarrying {}
