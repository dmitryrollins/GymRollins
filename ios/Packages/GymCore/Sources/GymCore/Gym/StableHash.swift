import Foundation

/// FNV-1a (64-bit) over a string's UTF-8 bytes. Unlike `Hasher`, it is the same on every run and device, so the
/// builder's tie-breaks are reproducible.
enum StableHash {
    static func fnv1a(_ text: String) -> UInt64 {
        text.utf8.reduce(0xcbf2_9ce4_8422_2325 as UInt64) { hash, byte in
            (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
    }

    /// Whole days since 1970 (UTC) for `date`: the builder's seed.
    static func day(of date: Date) -> Int { Int((date.timeIntervalSince1970 / 86_400).rounded(.down)) }
}
