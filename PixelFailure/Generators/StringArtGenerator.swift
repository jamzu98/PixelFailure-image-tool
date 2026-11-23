import CoreGraphics
import SwiftUI

/// Threads stretched between pins on a frame. "Times Table" connects pin i
/// to pin i × k (cardioids and nephroids appear as k changes, and k animates
/// smoothly). "Image" greedily picks the darkest remaining line each time,
/// approximating the source image with overlapping thread.
nonisolated struct StringArtGenerator: PatternGenerator {
    var displayName: String { "String Art" }

    var specs: [ParamSpec] {
        [
            .choice("mode", "Mode", options: ["Times Table", "Image"], initial: 0, randomizable: false),
            .choice("frame", "Frame", options: ["Circle", "Square"], initial: 0),
            .intSlider("pins", "Pins", min: 24, max: 400, initial: 200, randomizable: false),
            .slider("multiplier", "Multiplier", min: 2, max: 99, initial: 2),
            .intSlider("lines", "Lines", min: 100, max: 4000, initial: 1500, randomizable: false),
            .slider("threadOpacity", "Thread Opacity", min: 0.05, max: 1, initial: 0.35),
            .slider("lineWidth", "Line Width", min: 0.0002, max: 0.005, initial: 0.0008),
            .slider("margin", "Margin", min: 0, max: 0.2, initial: 0.05),
        ] + GenColor.specs
    }

    func wantsSourceImage(_ params: ParamValues) -> Bool { params.int("mode", 0) == 1 }

    func generate(params: ParamValues, seed: UInt64, context: GeneratorContext) -> [VectorPrimitive] {
        var rng = SeededRNG(seed: seed)
        let size = context.size
        let minDim = context.minDimension
        let pinCount = max(8, params.int("pins", 200))
        let margin = params.double("margin", 0.05) * minDim
        let opacity = params.double("threadOpacity", 0.35)
        let lineWidth = max(0.15, params.double("lineWidth", 0.0008) * minDim)
        let frameRect = CGRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin)
        // The seed turns where pin 0 sits, so rerolling rotates the figure.
        let startAngle = rng.range(0, 2 * .pi)
        let pins = Self.pins(count: pinCount, square: params.int("frame", 0) == 1, in: frameRect,
                             startAngle: startAngle)

        var lines: [(Int, Int)] = []
        if params.int("mode", 0) == 1, let sampler = context.sampler {
            lines = Self.greedy(pins: pins, sampler: sampler, size: size,
                                count: params.int("lines", 1500), rng: &rng)
        } else {
            let k = params.double("multiplier", 2)
            for i in 0..<pinCount {
                let j = Int((Double(i) * k).rounded()) % pinCount
                if i != j { lines.append((i, j)) }
            }
        }

        // Group into a handful of primitives so color can drift along the run.
        let groups = 8
        var out: [VectorPrimitive] = []
        for g in 0..<groups {
            let lo = lines.count * g / groups, hi = lines.count * (g + 1) / groups
            guard hi > lo else { continue }
            var path = Path()
            for (a, b) in lines[lo..<hi] { path.move(to: pins[a]); path.addLine(to: pins[b]) }
            let color = GenColor.pick(params, palette: context.palette, t: Double(g) / Double(groups - 1), rng: &rng)
            out.append(VectorPrimitive(path: path, stroke: color.withAlpha(color.a * opacity),
                                       lineWidth: lineWidth, lineCap: .butt))
        }
        return out
    }

    static func pins(count: Int, square: Bool, in rect: CGRect, startAngle: Double = 0) -> [CGPoint] {
        if !square {
            let r = min(rect.width, rect.height) / 2
            return (0..<count).map { k in
                let a = Double(k) / Double(count) * 2 * .pi - .pi / 2 + startAngle
                return CGPoint(x: rect.midX + cos(a) * r, y: rect.midY + sin(a) * r)
            }
        }
        let perimeter = 2 * (rect.width + rect.height)
        let shift = startAngle / (2 * .pi) * perimeter
        return (0..<count).map { k in
            var d = (Double(k) / Double(count) * perimeter + shift).truncatingRemainder(dividingBy: perimeter)
            if d < rect.width { return CGPoint(x: rect.minX + d, y: rect.minY) }
            d -= rect.width
            if d < rect.height { return CGPoint(x: rect.maxX, y: rect.minY + d) }
            d -= rect.height
            if d < rect.width { return CGPoint(x: rect.maxX - d, y: rect.maxY) }
            d -= rect.width
            return CGPoint(x: rect.minX, y: rect.maxY - d)
        }
    }

    /// Greedy thread path: from the current pin, take the line whose pixels
    /// are darkest on average, then lighten them so later lines go elsewhere.
    static func greedy(pins: [CGPoint], sampler: ImageSampler, size: CGSize,
                       count: Int, rng: inout SeededRNG) -> [(Int, Int)] {
        let grid = 200
        var darkness = [Double](repeating: 0, count: grid * grid)
        for j in 0..<grid {
            for i in 0..<grid {
                darkness[j * grid + i] = 1 - sampler.luminance(atUnitX: (Double(i) + 0.5) / Double(grid),
                                                               y: (Double(j) + 0.5) / Double(grid))
            }
        }
        let n = pins.count
        let gridPins = pins.map { CGPoint(x: $0.x / size.width * CGFloat(grid), y: $0.y / size.height * CGFloat(grid)) }
        func samples(_ a: Int, _ b: Int) -> [Int] {
            let p = gridPins[a], q = gridPins[b]
            let steps = max(2, Int(hypot(q.x - p.x, q.y - p.y)))
            return (0...steps).compactMap { s in
                let t = CGFloat(s) / CGFloat(steps)
                let x = Int(p.x + (q.x - p.x) * t), y = Int(p.y + (q.y - p.y) * t)
                guard x >= 0, x < grid, y >= 0, y < grid else { return nil }
                return y * grid + x
            }
        }
        var current = rng.int(0..<n)
        var lines: [(Int, Int)] = []
        var recent: [Int] = []
        let skip = max(2, n / 20)
        for _ in 0..<count {
            var best = -1, bestScore = -1.0
            for offset in skip..<(n - skip) {
                let candidate = (current + offset) % n
                if recent.contains(candidate) { continue }
                let cells = samples(current, candidate)
                guard !cells.isEmpty else { continue }
                let score = cells.reduce(0) { $0 + darkness[$1] } / Double(cells.count)
                if score > bestScore { bestScore = score; best = candidate }
            }
            guard best >= 0, bestScore > 0.02 else { break }
            for cell in samples(current, best) { darkness[cell] = max(0, darkness[cell] - 0.25) }
            lines.append((current, best))
            recent.append(current)
            if recent.count > 4 { recent.removeFirst() }
            current = best
        }
        return lines
    }
}
