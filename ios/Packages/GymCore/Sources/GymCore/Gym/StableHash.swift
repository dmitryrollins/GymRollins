import Foundation

/// FNV-1a (64-bit) over a string's UTF-8 bytes. Unlike `Hasher`, it is the same on every run and device, so the
/// builder's tie-breaks are reproducible.
enum StableHash {
    static func fnv1a(_ text: String) -> UInt64 {
        text.utf8.reduce(0xcbf2_9ce4_8422_2325 as UInt64) { hash, byte in
            (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
    }

    /// The builder's tie-break for an exercise on a day. FNV-1a alone keeps similar ids next to each other, so
    /// near-duplicate exercises land together and consecutive days look alike; a SplitMix64 finalizer spreads them.
    static func tieBreak(day: Int, id: String) -> UInt64 {
        let seed = fnv1a("\(day)|\(id)") &+ 0x9e37_79b9_7f4a_7c15
        let mixed = (seed ^ (seed >> 30)) &* 0xbf58_476d_1ce4_e5b9
        let final = (mixed ^ (mixed >> 27)) &* 0x94d0_49bb_1331_11eb
        return final ^ (final >> 31)
    }

    /// Whole days since 1970 (UTC) for `date`: the builder's seed.
    static func day(of date: Date) -> Int { Int((date.timeIntervalSince1970 / 86_400).rounded(.down)) }
}
