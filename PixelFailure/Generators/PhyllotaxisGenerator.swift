import CoreGraphics
import SwiftUI

nonisolated struct PhyllotaxisGenerator: PatternGenerator {
    var displayName: String { "Phyllotaxis Spiral" }

    var specs: [ParamSpec] {
        [
            .intSlider("count", "Count", min: 50, max: 4000, initial: 900),
            .slider("angle", "Angle", min: 130, max: 145, initial: 137.508),
            .slider("dotScale", "Dot Size", min: 0.1, max: 2.2, initial: 0.75),
            .choice("sizeRamp", "Size Ramp", options: ["Grow", "Shrink", "Constant", "Pulse"], initial: 0),
            .slider("hollow", "Hollow Center", min: 0, max: 0.6, initial: 0),
            .slider("spread", "Spread", min: 0.5, max: 1.1, initial: 0.95),
            .choice("shape", "Shape", options: ["Circle", "Square", "Triangle"], initial: 0),
        ] + GenColor.specs
    }

    func generate(params: ParamValues, seed: UInt64, context: GeneratorContext) -> [VectorPrimitive] {
        var rng = SeededRNG(seed: seed)
        let count = max(10, params.int("count", 900))
        let angleDeg = params.double("angle", 137.508)
        let dotScale = params.double("dotScale", 0.75)
        let sizeRamp = params.int("sizeRamp", 0)
        let hollow = params.double("hollow", 0)
        let spread = params.double("spread", 0.95)
        let shape = params.int("shape", 0)

        let size = context.size
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxRadius = context.minDimension / 2 * spread
        let c = maxRadius / (Double(count).squareRoot())
        let angle = angleDeg * .pi / 180

        var out: [VectorPrimitive] = []
        out.reserveCapacity(count)

        for i in 0..<count {
            let t = Double(i) / Double(max(1, count - 1))
            let r = c * Double(i).squareRoot()
            guard r >= hollow * maxRadius else { continue }
            let theta = Double(i) * angle
            let point = CGPoint(x: center.x + CGFloat(cos(theta) * r),
                                y: center.y + CGFloat(sin(theta) * r))

            let base = c * 0.5 * dotScale
            let dot: Double
            switch sizeRamp {
            case 0: dot = base * (0.25 + t * 1.4)
            case 1: dot = base * (1.65 - t * 1.4)
            case 3: dot = base * (0.6 + 0.9 * abs(sin(t * .pi * 6)))
            default: dot = base
            }

            let color = GenColor.pick(params, palette: context.palette, t: t, rng: &rng)
            let path: Path
            switch shape {
            case 1: path = GenShape.square(center: point, radius: dot, rotation: theta)
            case 2: path = GenShape.triangle(center: point, radius: dot, rotation: theta)
            default: path = GenShape.circle(center: point, radius: dot)
            }
            out.append(VectorPrimitive(path: path, fill: color))
        }
        return out
    }
}
