import Foundation

/// Versioned, LZFSE-compressed Codable container used by the disk caches.
///
/// Layout: `"PRSM"` magic · format version (UInt32 LE) · encoding (UInt8) · 3 reserved bytes · LZFSE payload.
/// A version or encoding mismatch makes `decode` return `nil` (the cache is then rebuilt).
enum CompressedCodableFile {
    enum Encoding: UInt8, Sendable {
        case json = 0
        case binaryPropertyList = 1
    }

    static let magic: [UInt8] = Array("PRSM".utf8)
    static let headerSize = 12

    static func encode<T: Encodable>(_ value: T, version: UInt32, encoding: Encoding) throws -> Data {
        let payload: Data
        switch encoding {
        case .json:
            payload = try JSONEncoder().encode(value)
        case .binaryPropertyList:
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            payload = try encoder.encode(value)
        }
        let compressed = try (payload as NSData).compressed(using: .lzfse) as Data
        var data = Data(capacity: headerSize + compressed.count)
        data.append(contentsOf: magic)
        withUnsafeBytes(of: version.littleEndian) { data.append(contentsOf: $0) }
        data.append(encoding.rawValue)
        data.append(contentsOf: [0, 0, 0])
        data.append(compressed)
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, version: UInt32) -> T? {
        guard data.count > headerSize, Array(data.prefix(4)) == magic else { return nil }
        let storedVersion = data.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        guard storedVersion == version, let encoding = Encoding(rawValue: data[data.startIndex + 8]) else { return nil }
        let compressed = data.subdata(in: headerSize..<data.count)
        guard let payload = try? (compressed as NSData).decompressed(using: .lzfse) as Data else { return nil }
        switch encoding {
        case .json:
            return try? JSONDecoder().decode(T.self, from: payload)
        case .binaryPropertyList:
            return try? PropertyListDecoder().decode(T.self, from: payload)
        }
    }

    static func read<T: Decodable>(_ type: T.Type, at url: URL, version: UInt32) -> T? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return decode(type, from: data, version: version)
    }

    static func write<T: Encodable>(_ value: T, to url: URL, version: UInt32, encoding: Encoding) throws {
        let data = try encode(value, version: version, encoding: encoding)
        try data.write(to: url, options: [.atomic])
    }
}
