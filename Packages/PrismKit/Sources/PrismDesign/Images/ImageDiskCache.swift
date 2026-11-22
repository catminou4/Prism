import CryptoKit
import Foundation
import Synchronization

/// File cache of the *encoded* image bytes, keyed by SHA-256 of the URL.
/// Lives in `~/Library/Caches/Prism/Images`, survives relaunch, trimmed LRU-style to `capacity`.
nonisolated final class ImageDiskCache: Sendable {
    let directory: URL
    let capacity: Int

    private struct Usage {
        /// Bytes on disk, once a background scan has counted them.
        var bytes: Int?
        /// Written while the scan was running (added to its total).
        var pending = 0
        var isScanning = false
        var isTrimming = false
        /// Files whose date was refreshed this session (LRU touch happens once per launch).
        var touched: Set<String> = []
    }

    private let usage = Mutex(Usage())

    init(directory: URL? = nil, capacity: Int = 1 << 30) {
        let base = directory ?? (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appending(path: "Prism/Images", directoryHint: .isDirectory)
        self.directory = base
        self.capacity = capacity
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    static func key(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        for byte in digest {
            bytes.append(hexDigits[Int(byte >> 4)])
            bytes.append(hexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func fileURL(forKey key: String) -> URL {
        // Two-level fan-out keeps directories small with 100k+ images.
        directory.appending(path: String(key.prefix(2)), directoryHint: .isDirectory).appending(path: key, directoryHint: .notDirectory)
    }

    func data(for url: URL) -> Data? {
        let key = Self.key(for: url)
        let file = fileURL(forKey: key)
        // Artwork files are small: a plain read beats mapping them.
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        // LRU touch, once per launch: the date only has to order files across sessions.
        if usage.withLock({ $0.touched.insert(key).inserted }) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        }
        return data
    }

    func store(_ data: Data, for url: URL) {
        let key = Self.key(for: url)
        let file = fileURL(forKey: key)
        if (try? data.write(to: file, options: .atomic)) == nil {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? data.write(to: file, options: .atomic)) != nil else { return }
        }
        enum Next { case none, scan, trim }
        let next: Next = usage.withLock { state in
            state.touched.insert(key)
            guard let bytes = state.bytes else {
                state.pending += data.count
                guard !state.isScanning else { return .none }
                state.isScanning = true
                return .scan
            }
            state.bytes = bytes + data.count
            guard bytes + data.count > capacity, !state.isTrimming else { return .none }
            state.isTrimming = true
            return .trim
        }
        switch next {
        case .none: break
        case .scan: Task.detached(priority: .background) { self.scan() }
        case .trim: Task.detached(priority: .background) { self.trim() }
        }
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        usage.withLock { state in
            state.bytes = state.isScanning ? nil : 0
            state.pending = 0
            state.touched.removeAll()
        }
    }

    /// Counts the cache once per launch (off the image path), then trims if needed.
    private func scan() {
        let total = files().reduce(0) { $0 + $1.size }
        let shouldTrim = usage.withLock { state -> Bool in
            state.isScanning = false
            state.bytes = total + state.pending
            state.pending = 0
            guard (state.bytes ?? 0) > capacity, !state.isTrimming else { return false }
            state.isTrimming = true
            return true
        }
        if shouldTrim { trim() }
    }

    /// Deletes the least recently used files until the cache is under 80 % of its capacity.
    func trim() {
        var files = files()
        var total = files.reduce(0) { $0 + $1.size }
        let target = capacity * 8 / 10
        if total > target {
            files.sort { $0.date < $1.date }
            for file in files {
                guard total > target else { break }
                try? FileManager.default.removeItem(at: file.url)
                total -= file.size
            }
        }
        usage.withLock { state in
            state.isTrimming = false
            if state.bytes != nil { state.bytes = total }
        }
    }

    private func files() -> [(url: URL, date: Date, size: Int)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return [] }
        var files: [(url: URL, date: Date, size: Int)] = []
        let wanted = Set(keys)
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: wanted), values.isRegularFile == true else { continue }
            files.append((file, values.contentModificationDate ?? .distantPast, values.totalFileAllocatedSize ?? 0))
        }
        return files
    }
}
