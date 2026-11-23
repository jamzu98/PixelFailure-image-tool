import CoreGraphics
import SwiftUI

/// Greedy packing: each candidate grows until it touches a neighbor (or hits
/// the size limit), so big shapes settle first and small ones fill the gaps.
/// With "Density From Image", dark areas pack smaller, tighter shapes.
nonisolated struct CirclePackingGenerator: PatternGenerator {
    var displayName: String { "Circle Packing" }

    var specs: [ParamSpec] {
        [
            .intSlider("count", "Shapes", min: 50, max: 4000, initial: 700, randomizable: false),
            .slider("minRadius", "Min Size", min: 0.002, max: 0.05, initial: 0.006),
            .slider("maxRadius", "Max Size", min: 0.02, max: 0.3, initial: 0.09),
            .slider("padding", "Padding", min: 0, max: 0.02, initial: 0.003),
            .choice("shape", "Shape", options: ["Circle", "Square", "Hexagon", "Blob"], initial: 0),
            .choice("style", "Style", options: ["Filled", "Outline", "Rings"], initial: 0),
            .slider("lineWidth", "Line Width", min: 0.0005, max: 0.01, initial: 0.002),
            .toggle("imageDensity", "Density From Image", initial: false, randomizable: false),
        ] + GenColor.specs
    }

    func wantsSourceImage(_ params: ParamValues) -> Bool { params.bool("imageDensity", false) }

    func generate(params: ParamValues, seed: UInt64, context: GeneratorContext) -> [VectorPrimitive] {
        var rng = SeededRNG(seed: seed)
        let size = context.size
        let minDim = context.minDimension
        let count = params.int("count", 700)
        let minR = params.double("minRadius", 0.006) * minDim
        let maxR = max(minR, params.double("maxRadius", 0.09) * minDim)
        let padding = params.double("padding", 0.003) * minDim
        let shape = params.int("shape", 0)
        let style = params.int("style", 0)
        let lineWidth = max(0.3, params.double("lineWidth", 0.002) * minDim)
        let sampler = params.bool("imageDensity", false) ? context.sampler : nil

        // Uniform grid: a cell holds the circles whose centers fall in it.
        let cell = maxR * 2 + padding
        let columns = max(1, Int(Double(size.width) / cell) + 1)
        let rows = max(1, Int(Double(size.height) / cell) + 1)
        var grid = [[Int]](repeating: [], count: columns * rows)
        var circles: [(x: Double, y: Double, r: Double)] = []
        circles.reserveCapacity(count)

        var attempts = 0
        let maxAttempts = count * 40
        while circles.count < count, attempts < maxAttempts {
            attempts += 1
            let x = rng.range(0, Double(size.width))
            let y = rng.range(0, Double(size.height))
            var limit = maxR
            if let sampler {
                let lum = sampler.luminance(atUnitX: x / Double(size.width), y: y / Double(size.height))
                limit = minR + (maxR - minR) * lum
            }
            let cx = min(columns - 1, Int(x / cell)), cy = min(rows - 1, Int(y / cell))
            var fits = true
            search: for gy in max(0, cy - 2)...min(rows - 1, cy + 2) {
                for gx in max(0, cx - 2)...min(columns - 1, cx + 2) {
                    for index in grid[gy * columns + gx] {
                        let other = circles[index]
                        let gap = hypot(other.x - x, other.y - y) - other.r - padding
                        if gap < minR { fits = false; break search }
                        limit = min(limit, gap)
                    }
                }
            }
            guard fits, limit >= minR else { continue }
            grid[cy * columns + cx].append(circles.count)
            circles.append((x, y, limit))
        }

        var out: [VectorPrimitive] = []
        out.reserveCapacity(circles.count * (style == 2 ? 3 : 1))
        for circle in circles {
            let center = CGPoint(x: circle.x, y: circle.y)
            let t = (circle.r - minR) / max(maxR - minR, 1e-9)
            let color = GenColor.pick(params, palette: context.palette, t: min(max(t, 0), 1), rng: &rng)
            let rotation = rng.range(0, .pi * 2)
            func path(_ r: Double) -> Path {
                switch shape {
                case 1: GenShape.square(center: center, radius: r * 0.78, rotation: rotation)
                case 2: GenShape.polygon(center: center, radius: r, sides: 6, rotation: rotation)
                case 3: GenShape.blob(center: center, radius: r * 0.92, irregularity: 0.18, rng: &rng)
                default: GenShape.circle(center: center, radius: r)
                }
            }
            switch style {
            case 1:
                out.append(VectorPrimitive(path: path(circle.r - lineWidth / 2), stroke: color, lineWidth: lineWidth))
            case 2:
                for ring in 0..<3 {
                    let r = circle.r * (1 - Double(ring) * 0.3) - lineWidth / 2
                    guard r > lineWidth else { break }
                    out.append(VectorPrimitive(path: path(r), stroke: color, lineWidth: lineWidth))
                }
            default:
                out.append(VectorPrimitive(path: path(circle.r), fill: color))
            }
        }
        return out
    }
}
