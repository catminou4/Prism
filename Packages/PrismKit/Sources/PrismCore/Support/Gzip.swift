import Foundation
import zlib

/// Streaming gzip / zlib inflater (zlib `inflateInit2` with automatic header detection).
public enum Gzip {
    /// True when `data` starts with the gzip magic bytes `1F 8B`.
    public static func isCompressed(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    /// Inflates gzip (or zlib) data in 256 KB chunks. Multi-member gzip files are concatenated.
    /// Truncated input returns what could be decoded; throws only when nothing could be inflated.
    public static func decompress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }
        var stream = z_stream()
        // 32 + MAX_WBITS: auto-detect gzip or zlib headers (16 + MAX_WBITS would be gzip only).
        guard inflateInit2_(&stream, 32 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw XMLTVError.decompressionFailed
        }
        defer { inflateEnd(&stream) }

        let chunkSize = 1 << 18
        var output = Data()
        output.reserveCapacity(min(data.count * 8, 512 << 20))
        let chunk = UnsafeMutablePointer<Bytef>.allocate(capacity: chunkSize)
        defer { chunk.deallocate() }
        var failed = false

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return }
            var offset = 0
            let total = raw.count
            var status = Z_OK
            while true {
                if stream.avail_in == 0, offset < total {
                    let take = min(total - offset, Int(UInt32.max / 2))
                    stream.next_in = UnsafeMutablePointer(mutating: base + offset)
                    stream.avail_in = uInt(take)
                    offset += take
                }
                stream.next_out = chunk
                stream.avail_out = uInt(chunkSize)
                status = inflate(&stream, Z_NO_FLUSH)
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 { output.append(chunk, count: produced) }

                if status == Z_STREAM_END {
                    // Another gzip member may follow.
                    if stream.avail_in > 0 || offset < total {
                        if inflateReset(&stream) != Z_OK { break }
                        continue
                    }
                    break
                }
                if status == Z_BUF_ERROR {
                    if stream.avail_in == 0 && offset >= total { break } // truncated input
                    if produced == 0 { failed = true; break }
                    continue
                }
                if status != Z_OK {
                    failed = true
                    break
                }
            }
        }
        if failed && output.isEmpty { throw XMLTVError.decompressionFailed }
        return output
    }
}
