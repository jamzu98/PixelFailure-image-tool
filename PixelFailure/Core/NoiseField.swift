import Foundation

/// Seeded 2D simplex noise (Gustavson's formulation). Roughly [-1, 1].
/// Fewer directional artifacts than Perlin and cheaper per octave.
nonisolated struct SimplexNoise: Sendable {
    private var perm: [Int]

    init(seed: UInt64) {
        var table = Array(0..<256)
        var rng = SeededRNG(seed: seed ^ 0x51A7_5EED)
        for i in stride(from: 255, through: 1, by: -1) {
            table.swapAt(i, rng.int(0..<(i + 1)))
        }
        perm = table + table
    }

    private static let gradients: [(Double, Double)] = [
        (1, 1), (-1, 1), (1, -1), (-1, -1), (1, 0), (-1, 0), (0, 1), (0, -1),
    ]
    private static let f2 = 0.5 * (sqrt(3.0) - 1)
    private static let g2 = (3 - sqrt(3.0)) / 6

    func value(_ x: Double, _ y: Double) -> Double {
        let s = (x + y) * Self.f2
        let i = floor(x + s), j = floor(y + s)
        let t = (i + j) * Self.g2
        let x0 = x - (i - t), y0 = y - (j - t)
        let (i1, j1) = x0 > y0 ? (1, 0) : (0, 1)
        let x1 = x0 - Double(i1) + Self.g2, y1 = y0 - Double(j1) + Self.g2
        let x2 = x0 - 1 + 2 * Self.g2, y2 = y0 - 1 + 2 * Self.g2
        let ii = Int(i) & 255, jj = Int(j) & 255

        func corner(_ gi: Int, _ dx: Double, _ dy: Double) -> Double {
            var t = 0.5 - dx * dx - dy * dy
            guard t > 0 else { return 0 }
            t *= t
            let g = Self.gradients[gi & 7]
            return t * t * (g.0 * dx + g.1 * dy)
        }
        let n0 = corner(perm[ii + perm[jj]], x0, y0)
        let n1 = corner(perm[ii + i1 + perm[jj + j1]], x1, y1)
        let n2 = corner(perm[ii + 1 + perm[jj + 1]], x2, y2)
        return 70 * (n0 + n1 + n2)
    }
}

/// Seeded cellular (Worley) noise: distance to the nearest and second
/// nearest feature point on a jittered unit grid.
nonisolated struct WorleyNoise: Sendable {
    let seed: UInt64

    init(seed: UInt64) { self.seed = seed }

    /// Deterministic feature point inside cell (cx, cy), in [0, 1)².
    func feature(_ cx: Int, _ cy: Int) -> (Double, Double) {
        var h = seed ^ (UInt64(bitPattern: Int64(cx)) &* 0x9E3779B97F4A7C15)
        h ^= UInt64(bitPattern: Int64(cy)) &* 0xC2B2AE3D27D4EB4F
        h = (h ^ (h >> 30)) &* 0xBF58476D1CE4E5B9
        h = (h ^ (h >> 27)) &* 0x94D049BB133111EB
        h ^= h >> 31
        return (Double(h & 0xFFFF_FFFF) / 4294967296.0, Double(h >> 32) / 4294967296.0)
    }

    /// (F1, F2) distances, each roughly in [0, 1.5].
    func distances(_ x: Double, _ y: Double) -> (Double, Double) {
        let cx = Int(floor(x)), cy = Int(floor(y))
        var f1 = Double.greatestFiniteMagnitude, f2 = Double.greatestFiniteMagnitude
        for dy in -1...1 {
            for dx in -1...1 {
                let (fx, fy) = feature(cx + dx, cy + dy)
                let px = Double(cx + dx) + fx - x, py = Double(cy + dy) + fy - y
                let d = sqrt(px * px + py * py)
                if d < f1 { f2 = f1; f1 = d } else if d < f2 { f2 = d }
            }
        }
        return (f1, f2)
    }

    /// F1 mapped to roughly [-1, 1].
    func value(_ x: Double, _ y: Double) -> Double {
        min(distances(x, y).0, 1) * 2 - 1
    }
}

nonisolated enum NoiseKind: Int, CaseIterable, Sendable {
    case perlin, simplex, worley, ridged, billow

    var displayName: String {
        switch self {
        case .perlin: "Perlin"
        case .simplex: "Simplex"
        case .worley: "Worley"
        case .ridged: "Ridged"
        case .billow: "Billow"
        }
    }
}

/// One configurable 2D noise source shared by every generator: a basis,
/// fractal octaves, and optional domain warping. Output roughly [-1, 1].
nonisolated struct NoiseField: Sendable {
    let kind: NoiseKind
    let octaves: Int
    let lacunarity: Double
    let gain: Double
    /// Domain-warp strength in noise units (0 = off).
    let warp: Double
    private let perlin: PerlinNoise
    private let simplex: SimplexNoise
    private let worley: WorleyNoise
    private let warpX: SimplexNoise
    private let warpY: SimplexNoise

    init(kind: NoiseKind, seed: UInt64, octaves: Int = 3, lacunarity: Double = 2,
         gain: Double = 0.5, warp: Double = 0) {
        self.kind = kind
        self.octaves = max(1, octaves)
        self.lacunarity = lacunarity
        self.gain = gain
        self.warp = warp
        perlin = PerlinNoise(seed: seed)
        simplex = SimplexNoise(seed: seed)
        worley = WorleyNoise(seed: seed)
        warpX = SimplexNoise(seed: seed ^ 0xA5A5_0001)
        warpY = SimplexNoise(seed: seed ^ 0x5A5A_0002)
    }

    private func basis(_ x: Double, _ y: Double) -> Double {
        switch kind {
        case .perlin: perlin.value(x, y)
        case .simplex, .ridged, .billow: simplex.value(x, y)
        case .worley: worley.value(x, y)
        }
    }

    func value(_ x: Double, _ y: Double) -> Double {
        var px = x, py = y
        if warp > 0 {
            px += warp * fractal(warpX, x + 5.2, y + 1.3)
            py += warp * fractal(warpY, x + 1.7, y + 9.2)
        }
        var amplitude = 1.0, frequency = 1.0, sum = 0.0, norm = 0.0
        for _ in 0..<octaves {
            var n = basis(px * frequency, py * frequency)
            switch kind {
            case .ridged:
                let r = 1 - abs(n)
                n = r * r * 2 - 1
            case .billow:
                n = abs(n) * 2 - 1
            default:
                break
            }
            sum += amplitude * n
            norm += amplitude
            amplitude *= gain
            frequency *= lacunarity
        }
        return min(max(sum / norm, -1), 1)
    }

    /// Divergence-free flow direction: the curl of the scalar field, by
    /// central differences. Returns (dx, dy); not normalized.
    func curl(_ x: Double, _ y: Double, epsilon: Double = 0.01) -> (Double, Double) {
        let dndy = (value(x, y + epsilon) - value(x, y - epsilon)) / (2 * epsilon)
        let dndx = (value(x + epsilon, y) - value(x - epsilon, y)) / (2 * epsilon)
        return (dndy, -dndx)
    }

    private func fractal(_ noise: SimplexNoise, _ x: Double, _ y: Double) -> Double {
        noise.value(x, y) * 0.66 + noise.value(x * 2, y * 2) * 0.34
    }
}

/// Shared "Noise" parameter block for generators that read a noise field.
/// Perlin with no warp is the default, so documents made before these
/// parameters existed keep rendering exactly as they did.
nonisolated enum GenNoise {
    static var specs: [ParamSpec] {
        [
            .choice("noiseType", "Noise", options: NoiseKind.allCases.map(\.displayName), initial: 0),
            .slider("noiseWarp", "Warp", min: 0, max: 2, initial: 0),
        ]
    }

    static func kind(_ params: ParamValues) -> NoiseKind {
        NoiseKind(rawValue: params.int("noiseType", 0)) ?? .perlin
    }

    /// True when the parameters still describe the original Perlin noise.
    static func isLegacy(_ params: ParamValues) -> Bool {
        kind(params) == .perlin && params.double("noiseWarp", 0) == 0
    }

    static func field(_ params: ParamValues, seed: UInt64, octaves: Int) -> NoiseField {
        NoiseField(kind: kind(params), seed: seed, octaves: octaves,
                   warp: params.double("noiseWarp", 0))
    }
}
