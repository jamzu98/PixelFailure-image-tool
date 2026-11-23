import CoreGraphics
import SwiftUI

/// Weighted Voronoi stippling: dots scattered by image darkness, then
/// relaxed with a few Lloyd iterations (each dot moves to the darkness-
/// weighted centroid of its Voronoi cell, computed on a sampling grid).
nonisolated struct StippleGenerator: PatternGenerator {
    var displayName: String { "Stipple" }
    var needsSourceImage: Bool { true }

    var specs: [ParamSpec] {
        [
            .intSlider("dots", "Dots", min: 300, max: 20000, initial: 5000, randomizable: false),
            .intSlider("iterations", "Relaxation", min: 0, max: 30, initial: 8, randomizable: false),
            .slider("minDot", "Min Dot", min: 0.0003, max: 0.006, initial: 0.0012),
            .slider("maxDot", "Max Dot", min: 0.001, max: 0.015, initial: 0.0045),
            .slider("gamma", "Contrast", min: 0.4, max: 3, initial: 1.4),
            .toggle("invert", "Invert", initial: false),
            .choice("shape", "Shape", options: ["Dot", "Square", "Dash"], initial: 0),
        ] + GenColor.specs
    }

    func generate(params: ParamValues, seed: UInt64, context: GeneratorContext) -> [VectorPrimitive] {
        guard let sampler = context.sampler else { return [] }
        var rng = SeededRNG(seed: seed)
        let size = context.size
        let minDim = context.minDimension
        let dotCount = params.int("dots", 5000)
        let iterations = params.int("iterations", 8)
        let minDot = params.double("minDot", 0.0012) * minDim
        let maxDot = max(minDot, params.double("maxDot", 0.0045) * minDim)
        let gamma = params.double("gamma", 1.4)
        let invert = params.bool("invert", false)
        let shape = params.int("shape", 0)

        // Darkness grid, longer side 256 cells.
        let aspect = Double(size.width) / Double(size.height)
        let gw = aspect >= 1 ? 256 : max(16, Int(256 * aspect))
        let gh = aspect >= 1 ? max(16, Int(256 / aspect)) : 256
        var density = [Double](repeating: 0, count: gw * gh)
        for j in 0..<gh {
            for i in 0..<gw {
                let lum = sampler.luminance(atUnitX: (Double(i) + 0.5) / Double(gw),
                                            y: (Double(j) + 0.5) / Double(gh))
                let d = invert ? lum : 1 - lum
                density[j * gw + i] = pow(min(max(d, 0), 1), gamma)
            }
        }
        func densityAt(_ x: Double, _ y: Double) -> Double {
            let i = min(gw - 1, max(0, Int(x))), j = min(gh - 1, max(0, Int(y)))
            return density[j * gw + i]
        }

        // Rejection sampling in grid coordinates.
        var points: [(x: Double, y: Double)] = []
        points.reserveCapacity(dotCount)
        var tries = 0
        while points.count < dotCount, tries < dotCount * 60 {
            tries += 1
            let x = rng.range(0, Double(gw)), y = rng.range(0, Double(gh))
            if rng.unit() < densityAt(x, y) { points.append((x, y)) }
        }
        guard !points.isEmpty else { return [] }

        // Lloyd relaxation using a bucket grid to find each cell's nearest dot.
        let bucket = max(1.0, (Double(gw * gh) / Double(points.count)).squareRoot() * 1.2)
        let bw = Int(Double(gw) / bucket) + 1, bh = Int(Double(gh) / bucket) + 1
        for _ in 0..<iterations {
            var buckets = [[Int]](repeating: [], count: bw * bh)
            for (index, p) in points.enumerated() {
                buckets[min(bh - 1, Int(p.y / bucket)) * bw + min(bw - 1, Int(p.x / bucket))].append(index)
            }
            var sumX = [Double](repeating: 0, count: points.count)
            var sumY = [Double](repeating: 0, count: points.count)
            var weight = [Double](repeating: 0, count: points.count)
            for j in 0..<gh {
                for i in 0..<gw {
                    let w = density[j * gw + i]
                    guard w > 0.002 else { continue }
                    let x = Double(i) + 0.5, y = Double(j) + 0.5
                    let bx = min(bw - 1, Int(x / bucket)), by = min(bh - 1, Int(y / bucket))
                    // Nearest dot: the 3×3 bucket block, widened only when empty.
                    var best = -1, bestD = Double.greatestFiniteMagnitude
                    var radius = 1
                    while best < 0, radius <= max(bw, bh) {
                        for yy in max(0, by - radius)...min(bh - 1, by + radius) {
                            for xx in max(0, bx - radius)...min(bw - 1, bx + radius) {
                                for index in buckets[yy * bw + xx] {
                                    let dx = points[index].x - x, dy = points[index].y - y
                                    let d = dx * dx + dy * dy
                                    if d < bestD { bestD = d; best = index }
                                }
                            }
                        }
                        radius += 1
                    }
                    guard best >= 0 else { continue }
                    sumX[best] += x * w; sumY[best] += y * w; weight[best] += w
                }
            }
            for index in points.indices where weight[index] > 0 {
                points[index] = (sumX[index] / weight[index], sumY[index] / weight[index])
            }
        }

        let sx = Double(size.width) / Double(gw), sy = Double(size.height) / Double(gh)
        var out: [VectorPrimitive] = []
        out.reserveCapacity(points.count)
        for p in points {
            let d = densityAt(p.x, p.y)
            let r = minDot + (maxDot - minDot) * d
            let center = CGPoint(x: p.x * sx, y: p.y * sy)
            let color = GenColor.pick(params, palette: context.palette, t: d, rng: &rng)
            switch shape {
            case 1:
                out.append(VectorPrimitive(path: GenShape.square(center: center, radius: r * 0.9), fill: color))
            case 2:
                out.append(VectorPrimitive(path: GenShape.dash(center: center, radius: r * 1.8, rotation: rng.range(0, .pi)),
                                           stroke: color, lineWidth: max(0.3, r * 0.7)))
            default:
                out.append(VectorPrimitive(path: GenShape.circle(center: center, radius: r), fill: color))
            }
        }
        return out
    }
}
