import Foundation
import PrismCore

/// On-disk locations used by Prism. Directories are created lazily when a path is requested.
///
/// Sandbox-safe: resolved through `FileManager` (inside the app container when sandboxed).
public struct AppDirectories: Sendable, Hashable {
    /// `~/Library/Application Support/Prism` and `~/Library/Caches/Prism`.
    public static let standard: AppDirectories = {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return AppDirectories(
            root: support.appending(path: "Prism", directoryHint: .isDirectory),
            caches: caches.appending(path: "Prism", directoryHint: .isDirectory)
        )
    }()

    /// Persistent data (sources, library).
    public let root: URL
    /// Re-creatable caches (catalogs, EPG, details, metadata).
    public let caches: URL

    public init(root: URL, caches: URL) {
        self.root = root
        self.caches = caches
    }

    /// A fresh, unique pair of directories under the temporary directory (tests, previews).
    public static func temporary(_ name: String = UUID().uuidString) -> AppDirectories {
        let base = FileManager.default.temporaryDirectory.appending(path: "Prism-\(name)", directoryHint: .isDirectory)
        return AppDirectories(
            root: base.appending(path: "Support", directoryHint: .isDirectory),
            caches: base.appending(path: "Caches", directoryHint: .isDirectory)
        )
    }

    public var sourcesFile: URL {
        Self.ensure(root).appending(path: "sources.json", directoryHint: .notDirectory)
    }

    public var libraryFile: URL {
        Self.ensure(root).appending(path: "library.json", directoryHint: .notDirectory)
    }

    public func catalogCacheFile(for id: SourceID) -> URL {
        Self.ensure(caches.appending(path: "Catalogs", directoryHint: .isDirectory))
            .appending(path: SafeFileName.make(id.rawValue) + ".catalog", directoryHint: .notDirectory)
    }

    public func epgCacheFile(for id: SourceID) -> URL {
        Self.ensure(caches.appending(path: "EPG", directoryHint: .isDirectory))
            .appending(path: SafeFileName.make(id.rawValue) + ".epg", directoryHint: .notDirectory)
    }

    public var detailCacheDirectory: URL {
        Self.ensure(caches.appending(path: "Details", directoryHint: .isDirectory))
    }

    public var metadataCacheDirectory: URL {
        Self.ensure(caches.appending(path: "Metadata", directoryHint: .isDirectory))
    }

    /// Removes every cache file (catalogs, EPG, details, metadata). Persistent data is kept.
    public func clearCaches() throws {
        if FileManager.default.fileExists(atPath: caches.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: caches)
        }
    }

    @discardableResult
    static func ensure(_ directory: URL) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
