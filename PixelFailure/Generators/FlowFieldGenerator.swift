import CoreGraphics
import SwiftUI

nonisolated struct FlowFieldGenerator: PatternGenerator {
    var displayName: String { "Flow Field" }

    var specs: [ParamSpec] {
        [
            .intSlider("lineCount", "Lines", min: 30, max: 2500, initial: 550, randomizable: false),
            .intSlider("steps", "Length", min: 5, max: 220, initial: 80),
            .slider("stepSize", "Step Size", min: 0.002, max: 0.02, initial: 0.006),
            .slider("noiseScale", "Noise Scale", min: 0.6, max: 9, initial: 2.6),
            .slider("curl", "Curl", min: 0.2, max: 3, initial: 1.2),
            .intSlider("octaves", "Detail", min: 1, max: 4, initial: 2),
            .toggle("curlFlow", "Curl Flow", initial: false),
            .slider("lineWidth", "Line Width", min: 0.0008, max: 0.02, initial: 0.0035),
            .slider("widthVariation", "Width Variation", min: 0, max: 1, initial: 0.5),
            .choice("colorBy", "Color By", options: ["Direction", "Line", "Random", "Position"], initial: 3),
        ] + GenNoise.specs + GenColor.specs
    }

    func generate(params: ParamValues, seed: UInt64, context: GeneratorContext) -> [VectorPrimitive] {
        var rng = SeededRNG(seed: seed)
        let noise = PerlinNoise(seed: seed)
        let size = context.size
        let minDim = context.minDimension

        let lineCount = params.int("lineCount", 550)
        let steps = params.int("steps", 80)
        let stepSize = params.double("stepSize", 0.006) * minDim
        let noiseScale = params.double("noiseScale", 2.6) / minDim
        let curl = params.double("curl", 1.2)
        let octaves = params.int("octaves", 2)
        let baseWidth = params.double("lineWidth", 0.0035) * minDim
        let widthVariation = params.double("widthVariation", 0.5)
        let colorBy = params.int("colorBy", 3)
        let curlFlow = params.bool("curlFlow", false)
        // The original Perlin fbm path stays bit-identical for old documents.
        let field: NoiseField? = GenNoise.isLegacy(params) && !curlFlow
            ? nil : GenNoise.field(params, seed: seed, octaves: octaves)

        // Seed points across a slightly expanded canvas so lines flow in from the edges.
        let inset = -0.08 * minDim
        let bounds = CGRect(x: inset, y: inset,
                            width: Double(size.width) - 2 * inset,
                            height: Double(size.height) - 2 * inset)

        var out: [VectorPrimitive] = []
        out.reserveCapacity(lineCount)

        for lineIndex in 0..<lineCount {
            var x = rng.range(bounds.minX, bounds.maxX)
            var y = rng.range(bounds.minY, bounds.maxY)
            var path = Path()
            path.move(to: CGPoint(x: x, y: y))
            var lastAngle = 0.0

            for _ in 0..<steps {
                let angle: Double
                if let field, curlFlow {
                    // Divergence-free flow: lines swirl instead of converging.
                    let c = field.curl(x * noiseScale, y * noiseScale)
                    angle = atan2(c.1, c.0) * curl
                } else if let field {
                    angle = field.value(x * noiseScale, y * noiseScale) * .pi * 2 * curl
                } else {
                    angle = noise.fbm(x * noiseScale, y * noiseScale, octaves: octaves) * .pi * 2 * curl
                }
                lastAngle = angle
                x += cos(angle) * stepSize
                y += sin(angle) * stepSize
                if x < bounds.minX || x > bounds.maxX || y < bounds.minY || y > bounds.maxY { break }
                path.addLine(to: CGPoint(x: x, y: y))
            }

            let t: Double
            switch colorBy {
            case 0: t = (lastAngle / (.pi * 2 * max(0.2, curl)) + 1) / 2
            case 1: t = Double(lineIndex) / Double(max(1, lineCount - 1))
            case 2: t = rng.unit()
            default: t = min(max(y / Double(size.height), 0), 1)
            }
            let color = GenColor.pick(params, palette: context.palette, t: t, rng: &rng)
            let width = baseWidth * (1 + rng.jitter(widthVariation))
            out.append(VectorPrimitive(path: path, stroke: color, lineWidth: max(0.2, width)))
        }
        return out
    }
}
