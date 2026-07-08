import CoreGraphics
import SwiftUI

nonisolated struct RingsGenerator: PatternGenerator {
    var displayName: String { "Concentric Rings" }

    var specs: [ParamSpec] {
        [
            .intSlider("ringCount", "Rings", min: 3, max: 90, initial: 26),
            .slider("wobble", "Wobble", min: 0, max: 1, initial: 0.18),
            .slider("wobbleScale", "Wobble Scale", min: 0.5, max: 8, initial: 2.5),
            .choice("rhythm", "Spacing", options: ["Even", "Golden", "Random"], initial: 0),
            .slider("lineWidth", "Line Width", min: 0.001, max: 0.03, initial: 0.004),
            .toggle("dashed", "Dashed", initial: false),
            .slider("dashRhythm", "Dash Rhythm", min: 0.01, max: 0.2, initial: 0.05),
            .slider("centerX", "Center X", min: 0, max: 1, initial: 0.5),
            .slider("centerY", "Center Y", min: 0, max: 1, initial: 0.5),
            .slider("spread", "Spread", min: 0.3, max: 1.5, initial: 0.95),
        ] + GenColor.specs
    }

    func generate(params: ParamValues, seed: UInt64, context: GeneratorContext) -> [VectorPrimitive] {
        var rng = SeededRNG(seed: seed)
        let noise = PerlinNoise(seed: seed)
        let size = context.size
        let minDim = context.minDimension

        let ringCount = max(2, params.int("ringCount", 26))
        let wobble = params.double("wobble", 0.18)
        let wobbleScale = params.double("wobbleScale", 2.5)
        let rhythm = params.int("rhythm", 0)
        let lineWidth = max(0.3, params.double("lineWidth", 0.004) * minDim)
        let dashed = params.bool("dashed")
        let dashRhythm = params.double("dashRhythm", 0.05) * minDim
        let spread = params.double("spread", 0.95)

        let center = CGPoint(x: Double(size.width) * params.double("centerX", 0.5),
                             y: Double(size.height) * params.double("centerY", 0.5))
        let maxRadius = minDim / 2 * spread

        // Radii according to the chosen rhythm, normalized to maxRadius.
        var radii: [Double] = []
        switch rhythm {
        case 1:
            var r = 1.0
            for _ in 0..<ringCount { radii.append(r); r /= 1.13 }
            radii = radii.map { $0 / (radii.first ?? 1) }
        case 2:
            for _ in 0..<ringCount { radii.append(rng.range(0.04, 1)) }
            radii.sort()
        default:
            for i in 0..<ringCount { radii.append(Double(i + 1) / Double(ringCount)) }
        }

        var out: [VectorPrimitive] = []
        let sampleCount = 180

        for (i, rNorm) in radii.enumerated() {
            let t = Double(i) / Double(max(1, ringCount - 1))
            let radius = rNorm * maxRadius
            let maxWobble = wobble * maxRadius / Double(ringCount) * 3.5

            var path = Path()
            for s in 0...sampleCount {
                let angle = Double(s) / Double(sampleCount) * 2 * .pi
                // Sample noise on a circle so the wobble closes seamlessly.
                let nx = cos(angle) * wobbleScale
                let ny = sin(angle) * wobbleScale
                let displaced = radius + noise.value(nx + Double(i) * 3.7, ny) * maxWobble
                let point = CGPoint(x: center.x + CGFloat(cos(angle) * displaced),
                                    y: center.y + CGFloat(sin(angle) * displaced))
                if s == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()

            let color = GenColor.pick(params, palette: context.palette, t: t, rng: &rng)
            let dash: [CGFloat] = dashed ? [CGFloat(dashRhythm * (1 + t * 2)), CGFloat(dashRhythm)] : []
            out.append(VectorPrimitive(path: path, stroke: color, lineWidth: lineWidth, dash: dash))
        }
        return out
    }
}
