import CoreGraphics
import SwiftUI

/// Reinterprets an existing image layer as a generative mosaic: samples the
/// image on a grid and draws shapes sized/colored by what it finds.
nonisolated struct SampledGridGenerator: PatternGenerator {
    var displayName: String { "Sampled Grid" }
    var needsSourceImage: Bool { true }

    var specs: [ParamSpec] {
        [
            .intSlider("columns", "Columns", min: 8, max: 140, initial: 48),
            .choice("shape", "Shape", options: ["Circle", "Square", "Vertical Bar", "Dash", "Diamond"], initial: 0),
            .choice("sizeBy", "Size By", options: ["Darkness", "Brightness", "Constant"], initial: 0),
            .slider("dotScale", "Dot Size", min: 0.2, max: 1.6, initial: 0.9),
            .slider("gamma", "Contrast", min: 0.35, max: 3, initial: 1),
            .choice("colorSource", "Color From", options: ["Image", "Palette Match", "Palette Ramp", "Single"], initial: 1),
            .intSlider("colorIndex", "Swatch", min: 0, max: 7, initial: 0),
            .slider("minSize", "Min Size", min: 0, max: 0.5, initial: 0.04),
            .slider("jitter", "Jitter", min: 0, max: 1, initial: 0),
        ]
    }

    func generate(params: ParamValues, seed: UInt64, context: GeneratorContext) -> [VectorPrimitive] {
        guard let sampler = context.sampler else { return [] }
        var rng = SeededRNG(seed: seed)
        let size = context.size
        let columns = max(4, params.int("columns", 48))
        let cell = Double(size.width) / Double(columns)
        let rows = max(1, Int((Double(size.height) / cell).rounded()))
        let shape = params.int("shape", 0)
        let sizeBy = params.int("sizeBy", 0)
        let dotScale = params.double("dotScale", 0.9)
        let gamma = params.double("gamma", 1)
        let colorSource = params.int("colorSource", 1)
        let jitterAmount = params.double("jitter", 0)
        let minSize = params.double("minSize", 0.04)

        var out: [VectorPrimitive] = []
        out.reserveCapacity(rows * columns)

        for row in 0..<rows {
            for col in 0..<columns {
                let ux = (Double(col) + 0.5) / Double(columns)
                let uy = (Double(row) + 0.5) / Double(rows)
                let sampled = sampler.color(atUnitX: ux, y: uy)
                guard sampled.a > 0.05 else { continue }

                let lum = pow(min(max(sampled.luminance, 0), 1), gamma)
                let magnitude: Double
                switch sizeBy {
                case 0: magnitude = 1 - lum
                case 1: magnitude = lum
                default: magnitude = 0.85
                }
                let radius = cell * 0.5 * dotScale * max(minSize, magnitude)
                guard radius > 0.15 else { continue }

                let jx = rng.jitter(jitterAmount) * cell * 0.4
                let jy = rng.jitter(jitterAmount) * cell * 0.4
                let point = CGPoint(x: (Double(col) + 0.5) * cell + jx,
                                    y: (Double(row) + 0.5) * cell + jy)

                let color: RGBAColor
                switch colorSource {
                case 0: color = sampled.withAlpha(1)
                case 1: color = nearestPaletteColor(to: sampled, in: context.palette)
                case 2: color = context.palette.ramp(lum)
                default: color = context.palette.color(params.int("colorIndex", 0))
                }

                let path: Path
                switch shape {
                case 1: path = GenShape.square(center: point, radius: radius * 0.78)
                case 2:
                    path = Path(CGRect(x: point.x - radius * 0.35, y: Double(point.y) - cell * 0.5,
                                       width: radius * 0.7, height: cell))
                case 3: path = GenShape.dash(center: point, radius: radius, rotation: 0)
                case 4: path = GenShape.diamond(center: point, radius: radius * 0.8)
                default: path = GenShape.circle(center: point, radius: radius)
                }

                if shape == 3 {
                    out.append(VectorPrimitive(path: path, stroke: color, lineWidth: max(0.3, radius * 0.35)))
                } else {
                    out.append(VectorPrimitive(path: path, fill: color))
                }
            }
        }
        return out
    }

    private func nearestPaletteColor(to color: RGBAColor, in palette: Palette) -> RGBAColor {
        guard !palette.colors.isEmpty else { return color }
        return palette.colors.min { a, b in
            distance(a, color) < distance(b, color)
        } ?? color
    }

    private func distance(_ a: RGBAColor, _ b: RGBAColor) -> Double {
        // Weighted RGB distance — cheap but perceptually decent.
        let dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
        return dr * dr * 0.3 + dg * dg * 0.59 + db * db * 0.11
    }
}
