import Foundation

/// Deterministic PRNG for daily puzzles (same seed → same choices). Index sampling is always safe for `upperBound > 0`.
struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func nextUInt64() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    /// Uniform in [0, 1).
    mutating func nextDouble() -> Double {
        Double(nextUInt64() >> 11) / Double(1 << 53)
    }

    /// Uniform index in `0 ..< n` (never returns `n`).
    mutating func nextIndex(upperBound n: Int) -> Int {
        guard n > 0 else { return 0 }
        let upper = UInt64(n)
        let limit = UInt64.max / upper * upper
        var x = nextUInt64()
        while x >= limit {
            x = nextUInt64()
        }
        return Int(x % upper)
    }

    mutating func shuffleInPlace<T>(_ a: inout [T]) {
        guard a.count > 1 else { return }
        for i in stride(from: a.count - 1, through: 1, by: -1) {
            let j = nextIndex(upperBound: i + 1)
            a.swapAt(i, j)
        }
    }
}

/// SplitMix64-style mixing for date integers.
func dailySeedUInt64(fromYMDInt ymd: Int) -> UInt64 {
    var x = UInt64(bitPattern: Int64(ymd))
    x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9
    x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
    x = x ^ (x >> 31)
    return x == 0 ? 0xDEADBEEFCAFEBABE : x
}
