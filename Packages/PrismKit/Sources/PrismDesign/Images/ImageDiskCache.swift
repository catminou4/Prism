import CryptoKit
import Foundation
import Synchronization

/// File cache of the *encoded* image bytes, keyed by SHA-256 of the URL.
/// Lives in `~/Library/Caches/Prism/Images`, survives relaunch, trimmed LRU-style to `capacity`.
nonisolated final class ImageDiskCache: Sendable {
    let directory: URL
    let capacity: Int
    private let writesSinceTrim = Mutex(0)

    init(directory: URL? = nil, capacity: Int = 1 << 30) {
        let base = directory ?? (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appending(path: "Prism/Images", directoryHint: .isDirectory)
        self.directory = base
        self.capacity = capacity
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    static func key(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(for url: URL) -> URL {
        let key = Self.key(for: url)
        // Two-level fan-out keeps directories small with 100k+ images.
        return directory.appending(path: String(key.prefix(2)), directoryHint: .isDirectory).appending(path: key)
    }

    func data(for url: URL) -> Data? {
        let file = fileURL(for: url)
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), !data.isEmpty else { return nil }
        // Touch for LRU (cheap, best effort).
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    func store(_ data: Data, for url: URL) {
        let file = fileURL(for: url)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        let shouldTrim = writesSinceTrim.withLock { count -> Bool in
            count += 1
            if count >= 200 { count = 0; return true }
            return false
        }
        if shouldTrim { trim() }
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Deletes the least recently used files until the cache is under 80 % of its capacity.
    func trim() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, date: Date, size: Int)] = []
        var total = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = values.totalFileAllocatedSize ?? 0
            total += size
            files.append((file, values.contentModificationDate ?? .distantPast, size))
        }
        guard total > capacity else { return }
        let target = capacity * 8 / 10
        for file in files.sorted(by: { $0.date < $1.date }) {
            guard total > target else { break }
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }
}
