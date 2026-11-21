import Foundation
import PrismCore

/// Persists the user's sources (without passwords) as JSON in Application Support.
public struct SourceStore: Sendable {
    public let directories: AppDirectories

    public init(directories: AppDirectories) {
        self.directories = directories
    }

    private struct File: Codable {
        var version: Int
        var sources: [Source]
    }

    static let formatVersion = 1

    /// Saved sources in user order; empty when missing or unreadable.
    public func load() -> [Source] {
        guard let data = try? Data(contentsOf: directories.sourcesFile) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let file = try? decoder.decode(File.self, from: data) { return file.sources }
        // Tolerate a bare array (older/hand-written files).
        return (try? decoder.decode([Source].self, from: data)) ?? []
    }

    public func save(_ sources: [Source]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(File(version: Self.formatVersion, sources: sources))
        try data.write(to: directories.sourcesFile, options: [.atomic])
    }
}
