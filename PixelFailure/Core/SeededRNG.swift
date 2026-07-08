import Foundation

/// Deterministic RNG (xoshiro256**) seeded via SplitMix64.
/// Same seed always produces the same sequence — the backbone of reproducible art.
nonisolated struct SeededRNG: RandomNumberGenerator, Sendable {
    private var state: (UInt64, UInt64, UInt64, UInt64)

    init(seed: UInt64) {
        var sm = seed
        func splitmix() -> UInt64 {
            sm &+= 0x9E3779B97F4A7C15
            var z = sm
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        state = (splitmix(), splitmix(), splitmix(), splitmix())
    }

    mutating func next() -> UInt64 {
        func rotl(_ x: UInt64, _ k: UInt64) -> UInt64 { (x << k) | (x >> (64 - k)) }
        let result = rotl(state.1 &* 5, 7) &* 9
        let t = state.1 << 17
        state.2 ^= state.0
        state.3 ^= state.1
        state.1 ^= state.2
        state.0 ^= state.3
        state.2 ^= t
        state.3 = rotl(state.3, 45)
        return result
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }

    /// Uniform in [min, max).
    mutating func range(_ min: Double, _ max: Double) -> Double {
        min + unit() * (max - min)
    }

    /// Symmetric jitter in [-amount, amount).
    mutating func jitter(_ amount: Double) -> Double {
        range(-amount, amount)
    }

    mutating func chance(_ probability: Double) -> Bool {
        unit() < probability
    }

    mutating func int(_ range: Range<Int>) -> Int {
        range.lowerBound + Int(unit() * Double(range.count))
    }

    mutating func pick<T>(_ array: [T]) -> T {
        array[Swift.min(int(0..<array.count), array.count - 1)]
    }

    static func randomSeed() -> UInt64 {
        UInt64.random(in: UInt64.min...UInt64.max)
    }
}
