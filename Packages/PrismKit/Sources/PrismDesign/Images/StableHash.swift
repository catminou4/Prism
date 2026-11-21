import Foundation

/// Deterministic hashing (unlike `hashValue`, stable across launches).
nonisolated public enum StableHash {
    /// 64-bit FNV-1a over the UTF-8 bytes.
    public static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// A deterministic pseudo-random generator seeded from a string (SplitMix64).
    public struct Generator: RandomNumberGenerator, Sendable {
        private var state: UInt64
        public init(seed: String) { state = StableHash.fnv1a(seed) }
        public init(seed: UInt64) { state = seed }
        public mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        /// Uniform double in 0..<1.
        public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }
}
