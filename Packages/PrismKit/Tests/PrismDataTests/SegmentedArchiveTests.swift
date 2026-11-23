import Foundation
import Testing
@testable import PrismData

/// Codec compatibility for `SegmentedArchive` payloads: archives are LZFSE-compressed JSON and
/// `decompressPayload` also accepts LZ4 (`"bv41"` magic) so either generation decodes.
@Suite("Segmented archive codec")
struct SegmentedArchiveCodecTests {
    private struct Item: Codable, Equatable, Sendable {
        var name: String
        var url: String
        var count: Int
    }

    private static func payload(_ items: [Item], algorithm: NSData.CompressionAlgorithm, formatting: JSONEncoder.OutputFormatting = []) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = formatting
        let json = try encoder.encode(items)
        return try (json as NSData).compressed(using: algorithm) as Data
    }

    private static func segment(_ items: [Item], algorithm: NSData.CompressionAlgorithm, tag: UInt8 = 1) throws -> SegmentedArchive.Segment {
        SegmentedArchive.Segment(tag: tag, payload: try payload(items, algorithm: algorithm))
    }

    @Test func newSegmentsAreLZFSEAndRoundTrip() throws {
        let items = (0..<100).map { Item(name: "Film \($0)", url: "https://panel.example.com/movie/\($0)/stream.mkv", count: $0) }
        let segment = try SegmentedArchive.encodeSegment(items, tag: 7)
        // LZFSE stream magic is "bvx…".
        #expect(segment.payload.count >= 3)
        #expect(segment.payload.prefix(3) == Data("bvx".utf8))
        #expect(SegmentedArchive.decodeSegment([Item].self, from: segment) == items)
    }

    @Test func lz4PayloadsAlsoDecode() throws {
        // Forward compatibility: an LZ4 payload (e.g. written by a future codec switch) decodes.
        let items = (0..<50).map { Item(name: "Rapide \($0)", url: "http://fast.example/live/\($0)", count: $0) }
        let lz4 = try Self.segment(items, algorithm: .lz4)
        #expect(lz4.payload.prefix(4) == Data("bv41".utf8))
        #expect(SegmentedArchive.decodeSegment([Item].self, from: lz4) == items)
    }

    @Test func escapedSlashJSONStillDecodes() throws {
        // Payloads written with the default encoder escape `/` as `\/`; both forms are plain JSON.
        let items = [Item(name: "A/B", url: "https://x.example/a/b", count: 1)]
        let legacy = try Self.segment(items, algorithm: .lzfse)
        let json = try #require(SegmentedArchive.decompressPayload(legacy.payload))
        #expect(String(decoding: json, as: UTF8.self).contains("\\/"))
        #expect(SegmentedArchive.decodeSegment([Item].self, from: legacy) == items)
    }

    @Test func mixedCodecArchiveRoundTrips() async throws {
        let items = (0..<200).map { Item(name: "Mix \($0)", url: "https://mix.example/\($0)", count: $0) }
        let lzfse = try Self.segment(items, algorithm: .lzfse, tag: 3)
        let lz4 = try Self.segment(items, algorithm: .lz4, tag: 3)
        let data = SegmentedArchive.pack([lzfse, lz4], version: 1)
        let segments = try #require(SegmentedArchive.unpack(data, version: 1))
        #expect(segments.count == 2)
        #expect(SegmentedArchive.decodeSegment([Item].self, from: segments[0]) == items)
        #expect(SegmentedArchive.decodeSegment([Item].self, from: segments[1]) == items)
        // Wrong version is still rejected wholesale.
        #expect(SegmentedArchive.unpack(data, version: 2) == nil)
    }

    @Test func corruptPayloadsReturnNil() {
        let junk = SegmentedArchive.Segment(tag: 1, payload: Data("not compressed".utf8))
        #expect(SegmentedArchive.decodeSegment([Item].self, from: junk) == nil)
        #expect(SegmentedArchive.decompressPayload(Data([0x62, 0x76, 0x34, 0x31])) == nil)
        #expect(SegmentedArchive.decompressPayload(Data()) == nil)
    }

    @Test func encodeChunksPreservesOrder() async throws {
        let items = (0..<500).map { Item(name: "Ordre \($0)", url: "https://o.example/\($0)", count: $0) }
        let segments = try await SegmentedArchive.encodeChunks(items, tag: 2, chunkSize: 64)
        #expect(segments.count == 8)
        var decoded: [Item] = []
        for segment in segments {
            #expect(segment.payload.prefix(3) == Data("bvx".utf8))
            decoded += try #require(SegmentedArchive.decodeSegment([Item].self, from: segment))
        }
        #expect(decoded == items)
    }
}
