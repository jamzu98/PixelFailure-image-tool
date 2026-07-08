import Foundation

/// Classic 2D Perlin gradient noise with a seed-shuffled permutation table.
/// Output roughly in [-1, 1]. Includes fractal Brownian motion stacking.
nonisolated struct PerlinNoise: Sendable {
    private var perm: [Int]

    init(seed: UInt64) {
        var table = Array(0..<256)
        var rng = SeededRNG(seed: seed)
        for i in stride(from: 255, through: 1, by: -1) {
            let j = rng.int(0..<(i + 1))
            table.swapAt(i, j)
        }
        perm = table + table
    }

    private func fade(_ t: Double) -> Double { t * t * t * (t * (t * 6 - 15) + 10) }

    private func grad(_ hash: Int, _ x: Double, _ y: Double) -> Double {
        switch hash & 7 {
        case 0: return  x + y
        case 1: return -x + y
        case 2: return  x - y
        case 3: return -x - y
        case 4: return  x
        case 5: return -x
        case 6: return  y
        default: return -y
        }
    }

    func value(_ x: Double, _ y: Double) -> Double {
        let xi = Int(floor(x)) & 255
        let yi = Int(floor(y)) & 255
        let xf = x - floor(x)
        let yf = y - floor(y)
        let u = fade(xf)
        let v = fade(yf)

        let aa = perm[perm[xi] + yi]
        let ab = perm[perm[xi] + yi + 1]
        let ba = perm[perm[xi + 1] + yi]
        let bb = perm[perm[xi + 1] + yi + 1]

        let x1 = lerp(grad(aa, xf, yf), grad(ba, xf - 1, yf), u)
        let x2 = lerp(grad(ab, xf, yf - 1), grad(bb, xf - 1, yf - 1), u)
        return lerp(x1, x2, v) * 1.42
    }

    /// Fractal Brownian motion: stacked octaves of noise, roughly [-1, 1].
    func fbm(_ x: Double, _ y: Double, octaves: Int = 3, lacunarity: Double = 2.0, gain: Double = 0.5) -> Double {
        var amplitude = 1.0
        var frequency = 1.0
        var sum = 0.0
        var norm = 0.0
        for _ in 0..<max(1, octaves) {
            sum += amplitude * value(x * frequency, y * frequency)
            norm += amplitude
            amplitude *= gain
            frequency *= lacunarity
        }
        return sum / norm
    }

    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}
