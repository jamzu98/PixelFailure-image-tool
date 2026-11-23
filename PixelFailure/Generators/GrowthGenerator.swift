import CoreGraphics
import SwiftUI

/// Differential growth: a closed chain of nodes that pull toward their
/// neighbors, push away from everything nearby, and split long edges, so the
/// curve folds into coral- and brain-like meanders. "Echoes" draws earlier
/// states of the same curve as concentric rings.
nonisolated struct GrowthGenerator: PatternGenerator {
    var displayName: String { "Differential Growth" }

    var specs: [ParamSpec] {
        [
            .intSlider("steps", "Steps", min: 20, max: 1500, initial: 450, randomizable: false),
            .intSlider("maxNodes", "Max Nodes", min: 200, max: 4000, initial: 2200, randomizable: false),
            .choice("start", "Start Shape", options: ["Circle", "Line", "Triangle"], initial: 0),
            .slider("startSize", "Start Size", min: 0.02, max: 0.4, initial: 0.12),
            .slider("repulsion", "Spacing", min: 0.004, max: 0.04, initial: 0.012),
            .slider("attraction", "Cohesion", min: 0.05, max: 0.8, initial: 0.35),
            .slider("wobble", "Growth", min: 0, max: 1, initial: 0.4),
            .intSlider("echoes", "Echoes", min: 1, max: 12, initial: 1),
            .slider("lineWidth", "Line Width", min: 0.0005, max: 0.012, initial: 0.0025),
            .toggle("filled", "Filled", initial: false),
        ] + GenColor.specs
    }

    func generate(params: ParamValues, seed: UInt64, context: GeneratorContext) -> [VectorPrimitive] {
        var rng = SeededRNG(seed: seed)
        let size = context.size
        let minDim = context.minDimension
        let steps = params.int("steps", 450)
        let maxNodes = params.int("maxNodes", 2200)
        let radius = params.double("repulsion", 0.012) * minDim
        let attraction = params.double("attraction", 0.35)
        let wobble = params.double("wobble", 0.4)
        let echoes = max(1, params.int("echoes", 1))
        let startSize = params.double("startSize", 0.12) * minDim
        let lineWidth = max(0.25, params.double("lineWidth", 0.0025) * minDim)
        let filled = params.bool("filled", false)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxEdge = radius * 0.9

        // Seed shape, resampled to roughly maxEdge spacing.
        var corners: [(Double, Double)]
        switch params.int("start", 0) {
        case 1:
            corners = [(center.x - startSize, center.y - 1), (center.x + startSize, center.y - 1),
                       (center.x + startSize, center.y + 1), (center.x - startSize, center.y + 1)]
        case 2:
            corners = (0..<3).map { k in
                let a = Double(k) * 2 * .pi / 3 - .pi / 2
                return (center.x + cos(a) * startSize, center.y + sin(a) * startSize)
            }
        default:
            let count = max(12, Int(2 * .pi * startSize / maxEdge))
            corners = (0..<count).map { k in
                let a = Double(k) * 2 * .pi / Double(count)
                return (center.x + cos(a) * startSize, center.y + sin(a) * startSize)
            }
        }
        var xs: [Double] = [], ys: [Double] = []
        for k in 0..<corners.count {
            let a = corners[k], b = corners[(k + 1) % corners.count]
            let pieces = max(1, Int(hypot(b.0 - a.0, b.1 - a.1) / maxEdge))
            for p in 0..<pieces {
                let t = Double(p) / Double(pieces)
                xs.append(a.0 + (b.0 - a.0) * t + rng.jitter(0.01))
                ys.append(a.1 + (b.1 - a.1) * t + rng.jitter(0.01))
            }
        }

        var snapshots: [([Double], [Double])] = []
        let echoInterval = max(1, steps / echoes)
        let rest = maxEdge * 0.6          // spring rest length between neighbors
        let cell = radius
        let growthRate = 0.02 + wobble * 0.04
        for step in 0..<steps {
            let n = xs.count
            // Flat grid over the curve's bounds; each cell is a linked list.
            var minX = Double.greatestFiniteMagnitude, minY = minX, maxX = -minX, maxY = -minX
            for i in 0..<n {
                minX = min(minX, xs[i]); maxX = max(maxX, xs[i])
                minY = min(minY, ys[i]); maxY = max(maxY, ys[i])
            }
            let columns = Int((maxX - minX) / cell) + 1, rows = Int((maxY - minY) / cell) + 1
            var head = [Int](repeating: -1, count: columns * rows)
            var link = [Int](repeating: -1, count: n)
            var cellOf = [Int](repeating: 0, count: n)
            for i in 0..<n {
                let c = Int((ys[i] - minY) / cell) * columns + Int((xs[i] - minX) / cell)
                cellOf[i] = c
                link[i] = head[c]
                head[c] = i
            }
            var nx = xs, ny = ys
            for i in 0..<n {
                let prev = (i + n - 1) % n, next = (i + 1) % n
                var fx = 0.0, fy = 0.0
                // Springs to both neighbors keep edges near the rest length.
                do {
                    let dx1 = xs[prev] - xs[i], dy1 = ys[prev] - ys[i]
                    let d1 = max((dx1 * dx1 + dy1 * dy1).squareRoot(), 1e-6)
                    let dx2 = xs[next] - xs[i], dy2 = ys[next] - ys[i]
                    let d2 = max((dx2 * dx2 + dy2 * dy2).squareRoot(), 1e-6)
                    fx += (dx1 / d1 * (d1 - rest) + dx2 / d2 * (d2 - rest)) * attraction * 0.5
                    fy += (dy1 / d1 * (d1 - rest) + dy2 / d2 * (d2 - rest)) * attraction * 0.5
                }
                // Smoothing toward the neighbors' midpoint.
                fx += ((xs[prev] + xs[next]) / 2 - xs[i]) * 0.1
                fy += ((ys[prev] + ys[next]) / 2 - ys[i]) * 0.1
                // Repulsion from every non-neighbor within `radius`.
                let cx = cellOf[i] % columns, cy = cellOf[i] / columns
                for gy in max(0, cy - 1)...min(rows - 1, cy + 1) {
                    for gx in max(0, cx - 1)...min(columns - 1, cx + 1) {
                        var j = head[gy * columns + gx]
                        while j >= 0 {
                            defer { j = link[j] }
                            if j == i || j == prev || j == next { continue }
                            let dx = xs[i] - xs[j], dy = ys[i] - ys[j]
                            let d2 = dx * dx + dy * dy
                            guard d2 < radius * radius, d2 > 1e-9 else { continue }
                            let d = d2.squareRoot()
                            let push = (radius - d) / radius
                            fx += dx / d * push * radius * 0.25
                            fy += dy / d * push * radius * 0.25
                        }
                    }
                }
                // Limit the step so the curve never jumps across itself.
                let magnitude = hypot(fx, fy), limit = rest * 0.5
                if magnitude > limit { fx *= limit / magnitude; fy *= limit / magnitude }
                nx[i] = xs[i] + fx + rng.jitter(wobble * rest * 0.05)
                ny[i] = ys[i] + fy + rng.jitter(wobble * rest * 0.05)
            }
            // Grow: split long edges, plus a trickle of random insertions that
            // forces the curve to buckle into folds.
            var gx: [Double] = [], gy: [Double] = []
            gx.reserveCapacity(min(maxNodes, n * 2)); gy.reserveCapacity(min(maxNodes, n * 2))
            for i in 0..<n {
                gx.append(nx[i]); gy.append(ny[i])
                let j = (i + 1) % n
                let long = hypot(nx[j] - nx[i], ny[j] - ny[i]) > maxEdge
                if gx.count + (n - i) < maxNodes, long || rng.chance(growthRate) {
                    gx.append((nx[i] + nx[j]) / 2); gy.append((ny[i] + ny[j]) / 2)
                }
            }
            xs = gx; ys = gy
            if echoes > 1, (step + 1) % echoInterval == 0, snapshots.count < echoes - 1 {
                snapshots.append((xs, ys))
            }
        }
        snapshots.append((xs, ys))

        var out: [VectorPrimitive] = []
        for (index, snapshot) in snapshots.enumerated() {
            var path = Path()
            let count = snapshot.0.count
            guard count > 2 else { continue }
            // Smooth closed curve through edge midpoints.
            func point(_ k: Int) -> CGPoint { CGPoint(x: snapshot.0[k % count], y: snapshot.1[k % count]) }
            func mid(_ k: Int) -> CGPoint {
                let a = point(k), b = point(k + 1)
                return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            }
            path.move(to: mid(0))
            for k in 1...count { path.addQuadCurve(to: mid(k), control: point(k)) }
            path.closeSubpath()
            let t = snapshots.count == 1 ? 0.5 : Double(index) / Double(snapshots.count - 1)
            let color = GenColor.pick(params, palette: context.palette, t: t, rng: &rng)
            if filled && index == snapshots.count - 1 {
                out.append(VectorPrimitive(path: path, fill: color))
            } else {
                out.append(VectorPrimitive(path: path, stroke: color, lineWidth: lineWidth))
            }
        }
        return out
    }
}
