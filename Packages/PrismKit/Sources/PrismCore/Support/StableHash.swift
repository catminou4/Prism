import Foundation

/// Deterministic hashes for identifiers that must stay stable across launches and refreshes
/// (never use `hashValue`, which is randomly seeded per process).
public enum StableHash {
    /// 64-bit FNV-1a over the UTF-8 bytes of `string`.
    public static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// FNV-1a 64 rendered as 16 lowercase hex characters.
    public static func hex(_ string: String) -> String {
        let value = fnv1a64(string)
        var bytes = [UInt8](repeating: 0x30, count: 16) // '0'
        for i in 0..<16 {
            let nibble = Int((value >> UInt64((15 - i) * 4)) & 0xF)
            bytes[i] = nibble < 10 ? UInt8(0x30 + nibble) : UInt8(0x57 + nibble) // 'a' + nibble - 10
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
