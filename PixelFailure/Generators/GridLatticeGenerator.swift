import CoreGraphics
import SwiftUI

nonisolated struct GridLatticeGenerator: PatternGenerator {
    var displayName: String { "Grid Lattice" }

    var specs: [ParamSpec] {
        [
            .intSlider("columns", "Columns", min: 3, max: 60, initial: 14),
            .choice("shape", "Shape", options: ["Circle", "Square", "Triangle", "Blob", "Dash"], initial: 0),
            .slider("sizeScale", "Size", min: 0.05, max: 1.4, initial: 0.62),
            .slider("jitter", "Jitter", min: 0, max: 1, initial: 0.15),
            .choice("falloff", "Size Falloff", options: ["None", "Radial", "Diagonal", "Noise"], initial: 1),
            .slider("falloffStrength", "Falloff Strength", min: 0, max: 1, initial: 0.55),
            .slider("rotationScatter", "Rotation Scatter", min: 0, max: 1, initial: 0.1),
            .slider("dropout", "Dropout", min: 0, max: 0.7, initial: 0.08),
            .toggle("outline", "Outline Only", initial: false),
            .slider("lineWidth", "Line Width", min: 0.05, max: 0.5, initial: 0.14),
        ] + GenColor.specs
    }

    func generate(params: ParamValues, seed: UInt64, context: GeneratorContext) -> [VectorPrimitive] {
        var rng = SeededRNG(seed: seed)
        let noise = PerlinNoise(seed: seed &+ 77)
        let size = context.size
        let columns = max(2, params.int("columns", 14))
        let cell = Double(size.width) / Double(columns)
        let rows = max(1, Int((Double(size.height) / cell).rounded(.up)))
        let shape = params.int("shape", 0)
        let sizeScale = params.double("sizeScale", 0.62)
        let jitterAmount = params.double("jitter", 0.15)
        let falloff = params.int("falloff", 1)
        let falloffStrength = params.double("falloffStrength", 0.55)
        let rotationScatter = params.double("rotationScatter", 0.1)
        let dropout = params.double("dropout", 0.08)
        let outline = params.bool("outline")
        let lineWidth = params.double("lineWidth", 0.14) * cell * 0.5

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxDist = hypot(Double(center.x), Double(center.y))

        var out: [VectorPrimitive] = []
        out.reserveCapacity(rows * columns)

        for row in 0..<rows {
            for col in 0..<columns {
                // Consume randomness before dropout so toggling params doesn't reshuffle everything.
                let jx = rng.jitter(jitterAmount) * cell * 0.5
                let jy = rng.jitter(jitterAmount) * cell * 0.5
                let rotation = rng.jitter(rotationScatter) * .pi
                let blobSeedJitter = rng.next()
                let colorRoll = rng.unit()
                if rng.chance(dropout) { continue }

                let cx = (Double(col) + 0.5) * cell + jx
                let cy = (Double(row) + 0.5) * cell + jy
                let point = CGPoint(x: cx, y: cy)

                let factor: Double
                switch falloff {
                case 1:
                    let d = hypot(cx - Double(center.x), cy - Double(center.y)) / maxDist
                    factor = 1 - falloffStrength * d
                case 2:
                    let d = (cx / Double(size.width) + cy / Double(size.height)) / 2
                    factor = 1 - falloffStrength * d
                case 3:
                    let n = (noise.value(cx / cell * 0.35, cy / cell * 0.35) + 1) / 2
                    factor = 1 - falloffStrength * n
                default:
                    factor = 1
                }

                let radius = max(0.1, cell * 0.5 * sizeScale * max(0.02, factor))
                var colorRng = SeededRNG(seed: seed &+ UInt64(colorRoll * 1e9))
                let color = GenColor.pick(params, palette: context.palette, t: factor, rng: &colorRng)

                let path: Path
                switch shape {
                case 1: path = GenShape.square(center: point, radius: radius, rotation: rotation)
                case 2: path = GenShape.triangle(center: point, radius: radius, rotation: rotation)
                case 3:
                    var blobRng = SeededRNG(seed: blobSeedJitter)
                    path = GenShape.blob(center: point, radius: radius, irregularity: 0.35, rng: &blobRng)
                case 4: path = GenShape.dash(center: point, radius: radius, rotation: rotation)
                default: path = GenShape.circle(center: point, radius: radius)
                }

                let isStroke = outline || shape == 4
                out.append(VectorPrimitive(path: path,
                                           fill: isStroke ? nil : color,
                                           stroke: isStroke ? color : nil,
                                           lineWidth: max(0.3, lineWidth)))
            }
        }
        return out
    }
}
