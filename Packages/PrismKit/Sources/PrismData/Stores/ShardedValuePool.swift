import Foundation
import Synchronization
import PrismCore

extension SourceCatalog {
    /// Parallel variant of `shareRepeatedValues()` with the same outcome: values are unchanged
    /// and repeated values share one copy afterwards.
    ///
    /// Interning is split across independent shard pools: every value hashes deterministically
    /// to exactly one shard, so equal values always land in the same table and still converge
    /// to a single shared instance catalogue-wide — no cross-shard dedup is ever needed.
    /// Each shard interns its own values under its own lock, and the item arrays are processed
    /// in parallel contiguous chunks. Element writes are disjoint by construction (each chunk
    /// owns its index range exclusively); shards are few enough that lock contention is rare.
    mutating func shareRepeatedValuesParallel() {
        let pool = ShardedValuePool()
        let source = sourceID
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 10))

        shareInParallel(&channels, workers: workers) { item in
            if item.sourceID == source { item.sourceID = source }
            item.categoryID = pool.share(item.categoryID)
            item.tags = pool.share(item.tags)
            if !item.httpHeaders.isEmpty { item.httpHeaders = pool.share(item.httpHeaders) }
        }
        shareInParallel(&movies, workers: workers) { item in
            if item.sourceID == source { item.sourceID = source }
            item.categoryID = pool.share(item.categoryID)
            item.tags = pool.share(item.tags)
            item.genres = pool.share(item.genres)
            item.containerExtension = pool.share(item.containerExtension)
            if !item.httpHeaders.isEmpty { item.httpHeaders = pool.share(item.httpHeaders) }
        }
        shareInParallel(&series, workers: workers) { item in
            if item.sourceID == source { item.sourceID = source }
            item.categoryID = pool.share(item.categoryID)
            item.tags = pool.share(item.tags)
            item.genres = pool.share(item.genres)
        }
    }
}

/// Mutates `items` in place, one contiguous index range per worker. Small arrays stay serial.
private func shareInParallel<T>(_ items: inout [T], workers: Int, intern: @Sendable (inout T) -> Void) {
    let count = items.count
    guard count > 0 else { return }
    guard count >= 2_048, workers > 1 else {
        for index in items.indices { intern(&items[index]) }
        return
    }
    let chunkSize = (count + workers - 1) / workers
    items.withUnsafeMutableBufferPointer { buffer in
        // Disjoint writes only: each iteration owns its index range exclusively, and
        // disjoint struct elements never share storage. The buffer cannot escape the
        // synchronous scope because `concurrentPerform` returns after the last iteration.
        let shared = SharedElements(buffer: buffer)
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            let lower = worker * chunkSize, upper = min(lower + chunkSize, count)
            guard lower < upper else { return }
            for index in lower..<upper {
                intern(&shared.buffer[index])
            }
        }
    }
}

/// Sendable box for a buffer written in parallel at disjoint positions (see usage).
private struct SharedElements<Element>: @unchecked Sendable {
    var buffer: UnsafeMutableBufferPointer<Element>
}

/// Shard pools of interned values. A value's shard is a pure function of the value, so the
/// interning of equal values converges inside the one shard that owns them.
private final class ShardedValuePool: Sendable {
    static let shardCount = 16

    private struct Shard {
        var strings: [String: String] = [:]
        var lists: [[String]: [String]] = [:]
        var headers: [[String: String]: [String: String]] = [:]
    }

    // `Mutex` is noncopyable and cannot sit in an array; box the shards in references.
    private final class ShardBox: @unchecked Sendable {
        let mutex = Mutex(Shard())
    }

    private let shards: [ShardBox]

    init() {
        shards = (0..<Self.shardCount).map { _ in ShardBox() }
    }

    /// Cheap deterministic shard key: length plus edge bytes. Skew only costs contention,
    /// never correctness — equal values always hash identically.
    @inline(__always)
    private static func shard(of value: String) -> Int {
        var hash = value.utf8.count &* 31
        var iterator = value.utf8.makeIterator()
        if let first = iterator.next() { hash = hash &+ Int(first) }
        return hash & (shardCount - 1)
    }

    @inline(__always)
    private static func shard(of value: [String]) -> Int {
        var hash = value.count &* 31
        if let first = value.first { hash = hash &+ first.utf8.count &* 7 &+ Int(first.utf8.first ?? 0) }
        return hash & (shardCount - 1)
    }

    @inline(__always)
    private static func shard(of value: [String: String]) -> Int {
        var hash = value.count &* 31
        if let first = value.keys.first { hash = hash &+ first.utf8.count }
        return hash & (shardCount - 1)
    }

    func share(_ value: String?) -> String? {
        guard let value else { return nil }
        // Up to 15 UTF-8 bytes live inline in the String itself: nothing to share.
        guard value.utf8.count > 15 else { return value }
        let shard = Self.shard(of: value)
        return shards[shard].mutex.withLock { pool in
            if let existing = pool.strings[value] { return existing }
            pool.strings[value] = value
            return value
        }
    }

    func share(_ value: [String]) -> [String] {
        guard !value.isEmpty else { return value }
        let shard = Self.shard(of: value)
        return shards[shard].mutex.withLock { pool in
            if let existing = pool.lists[value] { return existing }
            pool.lists[value] = value
            return value
        }
    }

    func share(_ value: [String: String]) -> [String: String] {
        guard !value.isEmpty else { return value }
        let shard = Self.shard(of: value)
        return shards[shard].mutex.withLock { pool in
            if let existing = pool.headers[value] { return existing }
            pool.headers[value] = value
            return value
        }
    }
}
