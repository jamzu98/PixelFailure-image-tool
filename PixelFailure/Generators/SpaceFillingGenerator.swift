import CoreGraphics
import SwiftUI

/// Hilbert, Moore, Z-order and Peano curves: one line that visits every cell
/// of a grid. Optionally rounded, jittered, or split into colored runs.
nonisolated struct SpaceFillingGenerator: PatternGenerator {
    var displayName: String { "Space-Filling Curve" }

    var specs: [ParamSpec] {
        [
            .choice("curve", "Curve", options: ["Hilbert", "Moore", "Z-Order", "Peano"], initial: 0),
            .intSlider("order", "Order", min: 1, max: 8, initial: 5),
            .slider("margin", "Margin", min: 0, max: 0.25, initial: 0.06),
            .slider("jitter", "Jitter", min: 0, max: 0.5, initial: 0),
            .toggle("rounded", "Rounded", initial: true),
            .slider("lineWidth", "Line Width", min: 0.0005, max: 0.02, initial: 0.004),
            .intSlider("runLength", "Color Run", min: 0, max: 400, initial: 0),
        ] + GenColor.specs
    }

    func generate(params: ParamValues, seed: UInt64, context: GeneratorContext) -> [VectorPrimitive] {
        var rng = SeededRNG(seed: seed)
        let size = context.size
        let minDim = context.minDimension
        let curve = params.int("curve", 0)
        // Peano grows 9× per order, Moore and Hilbert 4×: cap the point count.
        let order = min(params.int("order", 5), curve == 3 ? 5 : 8)
        let margin = params.double("margin", 0.06) * minDim
        let jitter = params.double("jitter", 0)
        let rounded = params.bool("rounded", true)
        let lineWidth = max(0.25, params.double("lineWidth", 0.004) * minDim)
        let runLength = params.int("runLength", 0)

        let (cells, n): ([(Int, Int)], Int) = switch curve {
        case 1: (Self.moore(order: order), 1 << order)
        case 2: (Self.zOrder(order: order), 1 << order)
        case 3: (Self.peano(order: order), Int(pow(3.0, Double(order))))
        default: (Self.hilbert(order: order), 1 << order)
        }
        guard cells.count > 1 else { return [] }
        // The curve itself is fixed; the seed picks one of its 8 orientations.
        let orientation = rng.int(0..<8)
        let oriented = cells.map { cell -> (Int, Int) in
            var (x, y) = cell
            if orientation & 1 == 1 { x = n - 1 - x }
            if orientation & 2 == 2 { y = n - 1 - y }
            if orientation & 4 == 4 { swap(&x, &y) }
            return (x, y)
        }
        let area = CGRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin)
        let cw = area.width / CGFloat(n), ch = area.height / CGFloat(n)
        let points = oriented.map { cell -> CGPoint in
            CGPoint(x: area.minX + (CGFloat(cell.0) + 0.5 + CGFloat(rng.jitter(jitter))) * cw,
                    y: area.minY + (CGFloat(cell.1) + 0.5 + CGFloat(rng.jitter(jitter))) * ch)
        }

        let run = runLength > 0 ? runLength : points.count
        var out: [VectorPrimitive] = []
        var start = 0
        while start < points.count - 1 {
            let end = min(points.count - 1, start + run)
            let slice = Array(points[start...end])
            let color = GenColor.pick(params, palette: context.palette,
                                      t: Double(start) / Double(points.count), rng: &rng)
            out.append(VectorPrimitive(path: Self.path(slice, rounded: rounded), stroke: color,
                                       lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            start = end
        }
        return out
    }

    /// Polyline, or rounded through edge midpoints with quadratic corners.
    static func path(_ points: [CGPoint], rounded: Bool) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard rounded, points.count > 2 else {
            for p in points.dropFirst() { path.addLine(to: p) }
            return path
        }
        for k in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[k].x + points[k + 1].x) / 2, y: (points[k].y + points[k + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[k])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    static func hilbert(order: Int) -> [(Int, Int)] {
        let n = 1 << order
        return (0..<(n * n)).map { hilbertPoint(n: n, d: $0) }
    }

    /// Standard Hilbert index → (x, y).
    static func hilbertPoint(n: Int, d: Int) -> (Int, Int) {
        var x = 0, y = 0, t = d, s = 1
        while s < n {
            let rx = 1 & (t / 2), ry = 1 & (t ^ rx)
            if ry == 0 {
                if rx == 1 { x = s - 1 - x; y = s - 1 - y }
                swap(&x, &y)
            }
            x += s * rx; y += s * ry
            t /= 4; s *= 2
        }
        return (x, y)
    }

    /// Moore curve: four Hilbert quadrants rotated into a closed loop.
    static func moore(order: Int) -> [(Int, Int)] {
        guard order > 1 else { return [(0, 0), (0, 1), (1, 1), (1, 0), (0, 0)] }
        let half = 1 << (order - 1)
        let h = hilbert(order: order - 1)
        var out: [(Int, Int)] = []
        // Quadrants visited counter-clockwise, each Hilbert sub-curve rotated.
        for (x, y) in h { out.append((half - 1 - y, x)) }                 // bottom-left, going up
        for (x, y) in h { out.append((half - 1 - y, half + x)) }          // top-left
        for (x, y) in h { out.append((half + y, 2 * half - 1 - x)) }      // top-right, going down
        for (x, y) in h { out.append((half + y, half - 1 - x)) }          // bottom-right
        out.append(out[0])
        return out
    }

    static func zOrder(order: Int) -> [(Int, Int)] {
        let n = 1 << order
        return (0..<(n * n)).map { index in
            var x = 0, y = 0
            for bit in 0..<order {
                x |= ((index >> (2 * bit)) & 1) << bit
                y |= ((index >> (2 * bit + 1)) & 1) << bit
            }
            return (x, y)
        }
    }

    /// Peano curve via the classic base-3 digit construction.
    static func peano(order: Int) -> [(Int, Int)] {
        let n = Int(pow(3.0, Double(order)))
        return (0..<(n * n)).map { index in
            var digits = [Int](repeating: 0, count: 2 * order)
            var v = index
            for k in stride(from: 2 * order - 1, through: 0, by: -1) { digits[k] = v % 3; v /= 3 }
            var x = 0, y = 0
            for k in 0..<order {
                var a = digits[2 * k], b = digits[2 * k + 1]
                // Parity of the preceding digits flips each coordinate digit.
                var sumForX = 0, sumForY = 0
                for m in 0..<k { sumForX += digits[2 * m + 1]; sumForY += digits[2 * m] }
                sumForY += a
                if sumForX % 2 == 1 { a = 2 - a }
                if sumForY % 2 == 1 { b = 2 - b }
                x = x * 3 + a; y = y * 3 + b
            }
            return (x, y)
        }
    }
}
