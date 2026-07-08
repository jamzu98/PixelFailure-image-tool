import CoreGraphics
import SwiftUI

/// Everything a generator gets to work with.
nonisolated struct GeneratorContext {
    /// The layer's natural size (the canvas size for pattern layers).
    var size: CGSize
    var palette: Palette
    /// Downsampled pixels of the source image layer, for image-driven generators.
    var sampler: ImageSampler?

    var minDimension: Double { Double(min(size.width, size.height)) }
}

nonisolated protocol PatternGenerator: Sendable {
    var displayName: String { get }
    var specs: [ParamSpec] { get }
    /// True for generators that reinterpret an existing image layer.
    var needsSourceImage: Bool { get }
    func generate(params: ParamValues, seed: UInt64, context: GeneratorContext) -> [VectorPrimitive]
}

nonisolated extension PatternGenerator {
    var needsSourceImage: Bool { false }
}

nonisolated extension GeneratorType {
    var generator: any PatternGenerator {
        switch self {
        case .gridLattice: GridLatticeGenerator()
        case .phyllotaxis: PhyllotaxisGenerator()
        case .flowField: FlowFieldGenerator()
        case .truchet: TruchetGenerator()
        case .waves: WavesGenerator()
        case .rings: RingsGenerator()
        case .sampledGrid: SampledGridGenerator()
        }
    }

    var displayName: String {
        switch self {
        case .gridLattice: "Grid Lattice"
        case .phyllotaxis: "Phyllotaxis Spiral"
        case .flowField: "Flow Field"
        case .truchet: "Truchet Tiles"
        case .waves: "Interference Waves"
        case .rings: "Concentric Rings"
        case .sampledGrid: "Sampled Grid"
        }
    }
}

// MARK: - Shared color picking

/// Shared "Colors" parameter block used by most generators.
nonisolated enum GenColor {
    static var specs: [ParamSpec] {
        [
            .choice("colorMode", "Colors", options: ["Palette ramp", "Random", "Single"], initial: 0),
            .intSlider("colorIndex", "Swatch", min: 0, max: 7, initial: 0),
        ]
    }

    /// `t` is the generator's notion of progress (0...1) used in ramp mode.
    static func pick(_ params: ParamValues, palette: Palette, t: Double, rng: inout SeededRNG) -> RGBAColor {
        switch params.int("colorMode", 0) {
        case 0: return palette.ramp(t)
        case 1: return palette.random(using: &rng)
        default: return palette.color(params.int("colorIndex", 0))
        }
    }
}

// MARK: - Shared shapes

nonisolated enum GenShape {
    static func circle(center: CGPoint, radius: Double) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                               width: radius * 2, height: radius * 2))
    }

    static func square(center: CGPoint, radius: Double, rotation: Double = 0) -> Path {
        polygon(center: center, radius: radius * 1.28, sides: 4, rotation: rotation + .pi / 4)
    }

    static func triangle(center: CGPoint, radius: Double, rotation: Double = 0) -> Path {
        polygon(center: center, radius: radius * 1.25, sides: 3, rotation: rotation - .pi / 2)
    }

    static func diamond(center: CGPoint, radius: Double, rotation: Double = 0) -> Path {
        polygon(center: center, radius: radius * 1.28, sides: 4, rotation: rotation)
    }

    static func polygon(center: CGPoint, radius: Double, sides: Int, rotation: Double = 0) -> Path {
        var path = Path()
        for i in 0..<sides {
            let angle = rotation + Double(i) * 2 * .pi / Double(sides)
            let point = CGPoint(x: center.x + CGFloat(cos(angle) * radius),
                                y: center.y + CGFloat(sin(angle) * radius))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// Organic closed blob: polygon with noise-perturbed radii, smoothed with
    /// quadratic curves through edge midpoints.
    static func blob(center: CGPoint, radius: Double, irregularity: Double, rng: inout SeededRNG) -> Path {
        let count = 8
        var points: [CGPoint] = []
        for i in 0..<count {
            let angle = Double(i) * 2 * .pi / Double(count)
            let r = radius * (1 + rng.jitter(irregularity))
            points.append(CGPoint(x: center.x + CGFloat(cos(angle) * r),
                                  y: center.y + CGFloat(sin(angle) * r)))
        }
        var path = Path()
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        path.move(to: mid(points[count - 1], points[0]))
        for i in 0..<count {
            let next = points[(i + 1) % count]
            path.addQuadCurve(to: mid(points[i], next), control: points[i])
        }
        path.closeSubpath()
        return path
    }

    /// A short horizontal dash centered on `center` (before rotation).
    static func dash(center: CGPoint, radius: Double, rotation: Double = 0) -> Path {
        var path = Path()
        let t = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: rotation)
        path.move(to: CGPoint(x: -radius, y: 0).applying(t))
        path.addLine(to: CGPoint(x: radius, y: 0).applying(t))
        return path
    }
}
