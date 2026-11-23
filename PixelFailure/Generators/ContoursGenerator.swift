import CoreGraphics
import SwiftUI

/// Topographic lines: marching squares over a noise field, with segments
/// chained into continuous polylines and optionally smoothed.
nonisolated struct ContoursGenerator: PatternGenerator {
    var displayName: String { "Contours" }

    var specs: [ParamSpec] {
        [
            .intSlider("levels", "Levels", min: 3, max: 48, initial: 16),
            .intSlider("resolution", "Resolution", min: 40, max: 260, initial: 140, randomizable: false),
            .slider("noiseScale", "Noise Scale", min: 0.4, max: 8, initial: 2.2),
            .intSlider("octaves", "Detail", min: 1, max: 6, initial: 3),
            .slider("lineWidth", "Line Width", min: 0.0005, max: 0.012, initial: 0.0025),
            .toggle("smooth", "Smooth", initial: true),
            .slider("emphasis", "Index Lines", min: 0, max: 1, initial: 0.4),
        ] + GenNoise.specs + GenColor.specs
    }

    func generate(params: ParamValues, seed: UInt64, context: GeneratorContext) -> [VectorPrimitive] {
        var rng = SeededRNG(seed: seed)
        let size = context.size
        let minDim = context.minDimension
        let levels = max(2, params.int("levels", 16))
        let resolution = max(8, params.int("resolution", 140))
        let scale = params.double("noiseScale", 2.2)
        let lineWidth = max(0.25, params.double("lineWidth", 0.0025) * minDim)
        let smooth = params.bool("smooth", true)
        let emphasis = params.double("emphasis", 0.4)
        // Contours default to simplex; the shared Noise picker still applies
        // once it's moved off its Perlin default.
        let field = GenNoise.isLegacy(params)
            ? NoiseField(kind: .simplex, seed: seed, octaves: params.int("octaves", 3))
            : GenNoise.field(params, seed: seed, octaves: params.int("octaves", 3))

        let aspect = Double(size.width) / Double(size.height)
        let nx = aspect >= 1 ? resolution : max(8, Int(Double(resolution) * aspect))
        let ny = aspect >= 1 ? max(8, Int(Double(resolution) / aspect)) : resolution
        let stepX = Double(size.width) / Double(nx), stepY = Double(size.height) / Double(ny)
        var values = [Double](repeating: 0, count: (nx + 1) * (ny + 1))
        for j in 0...ny {
            for i in 0...nx {
                let x = Double(i) / Double(nx) * scale * aspect.squareRootClamped
                let y = Double(j) / Double(ny) * scale / aspect.squareRootClamped
                values[j * (nx + 1) + i] = (field.value(x, y) + 1) / 2
            }
        }

        var out: [VectorPrimitive] = []
        for level in 1..<levels {
            let threshold = Double(level) / Double(levels)
            let chains = Self.contourChains(values: values, nx: nx, ny: ny, threshold: threshold)
            guard !chains.isEmpty else { continue }
            var path = Path()
            for var chain in chains {
                if smooth { chain = Self.chaikin(chain, closed: chain.first == chain.last) }
                for (index, point) in chain.enumerated() {
                    let p = CGPoint(x: point.x * stepX, y: point.y * stepY)
                    if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
            }
            let t = threshold
            let color = GenColor.pick(params, palette: context.palette, t: t, rng: &rng)
            let isIndex = level % 5 == 0
            let width = lineWidth * (isIndex ? 1 + emphasis * 1.5 : 1)
            out.append(VectorPrimitive(path: path, stroke: color, lineWidth: width))
        }
        return out
    }

    /// Marching squares at one threshold, segments joined through shared
    /// grid edges into polylines in grid coordinates.
    static func contourChains(values: [Double], nx: Int, ny: Int, threshold: Double) -> [[CGPoint]] {
        let stride = nx + 1
        func v(_ i: Int, _ j: Int) -> Double { values[j * stride + i] }
        // Edge ids: horizontal edge (i,j)-(i+1,j) and vertical edge (i,j)-(i,j+1).
        func hEdge(_ i: Int, _ j: Int) -> Int { (j * stride + i) * 2 }
        func vEdge(_ i: Int, _ j: Int) -> Int { (j * stride + i) * 2 + 1 }
        func point(_ edge: Int) -> CGPoint {
            let base = edge / 2, i = base % stride, j = base / stride
            if edge % 2 == 0 {
                let a = v(i, j), b = v(i + 1, j)
                let t = (threshold - a) / (b - a == 0 ? 1e-9 : b - a)
                return CGPoint(x: Double(i) + t, y: Double(j))
            } else {
                let a = v(i, j), b = v(i, j + 1)
                let t = (threshold - a) / (b - a == 0 ? 1e-9 : b - a)
                return CGPoint(x: Double(i), y: Double(j) + t)
            }
        }
        var segments: [(Int, Int)] = []
        for j in 0..<ny {
            for i in 0..<nx {
                let tl = v(i, j) >= threshold, tr = v(i + 1, j) >= threshold
                let br = v(i + 1, j + 1) >= threshold, bl = v(i, j + 1) >= threshold
                let code = (tl ? 8 : 0) | (tr ? 4 : 0) | (br ? 2 : 0) | (bl ? 1 : 0)
                let top = hEdge(i, j), bottom = hEdge(i, j + 1)
                let left = vEdge(i, j), right = vEdge(i + 1, j)
                switch code {
                case 1, 14: segments.append((left, bottom))
                case 2, 13: segments.append((bottom, right))
                case 3, 12: segments.append((left, right))
                case 4, 11: segments.append((top, right))
                case 6, 9: segments.append((top, bottom))
                case 7, 8: segments.append((left, top))
                case 5:
                    segments.append((left, top)); segments.append((bottom, right))
                case 10:
                    segments.append((top, right)); segments.append((left, bottom))
                default: break
                }
            }
        }
        // Chain segments through shared edge ids.
        var byEdge: [Int: [Int]] = [:]
        for (index, segment) in segments.enumerated() {
            byEdge[segment.0, default: []].append(index)
            byEdge[segment.1, default: []].append(index)
        }
        var used = [Bool](repeating: false, count: segments.count)
        var chains: [[CGPoint]] = []
        func walk(from edge: Int, into chain: inout [Int]) {
            var current = edge
            while let next = byEdge[current]?.first(where: { !used[$0] }) {
                used[next] = true
                let s = segments[next]
                current = s.0 == current ? s.1 : s.0
                chain.append(current)
            }
        }
        for start in segments.indices where !used[start] {
            used[start] = true
            var forward = [segments[start].0, segments[start].1]
            walk(from: segments[start].1, into: &forward)
            var backward: [Int] = []
            walk(from: segments[start].0, into: &backward)
            let edges = backward.reversed() + forward
            chains.append(edges.map(point))
        }
        return chains
    }

    /// One pass of Chaikin corner cutting.
    static func chaikin(_ points: [CGPoint], closed: Bool) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var out: [CGPoint] = closed ? [] : [points[0]]
        let last = points.count - 1
        for k in 0..<last {
            let a = points[k], b = points[k + 1]
            out.append(CGPoint(x: a.x * 0.75 + b.x * 0.25, y: a.y * 0.75 + b.y * 0.25))
            out.append(CGPoint(x: a.x * 0.25 + b.x * 0.75, y: a.y * 0.25 + b.y * 0.75))
        }
        if closed, let first = out.first { out.append(first) } else { out.append(points[last]) }
        return out
    }
}

private extension Double {
    /// Square root used to keep noise features round on non-square canvases.
    nonisolated var squareRootClamped: Double { Swift.max(0.25, self).squareRoot() }
}
