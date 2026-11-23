import CoreGraphics
import SwiftUI

/// Recursive rectangle splits, Mondrian-style: each region splits along its
/// longer side (usually) until it is small, deep enough, or loses the coin toss.
nonisolated struct SubdivisionGenerator: PatternGenerator {
    var displayName: String { "Subdivision" }

    var specs: [ParamSpec] {
        [
            .intSlider("depth", "Depth", min: 1, max: 11, initial: 7),
            .slider("splitChance", "Split Chance", min: 0.3, max: 1, initial: 0.8),
            .slider("ratioJitter", "Off-Center", min: 0, max: 0.45, initial: 0.3),
            .slider("minSize", "Min Size", min: 0.005, max: 0.2, initial: 0.03),
            .slider("gap", "Gap", min: 0, max: 0.02, initial: 0.004),
            .slider("fillChance", "Fill Amount", min: 0, max: 1, initial: 0.75),
            .slider("lineWidth", "Line Width", min: 0, max: 0.012, initial: 0.002),
            .choice("style", "Style", options: ["Blocks", "Rounded", "Circles", "Lines"], initial: 0),
        ] + GenColor.specs
    }

    func generate(params: ParamValues, seed: UInt64, context: GeneratorContext) -> [VectorPrimitive] {
        var rng = SeededRNG(seed: seed)
        let minDim = context.minDimension
        let maxDepth = params.int("depth", 7)
        let splitChance = params.double("splitChance", 0.8)
        let jitter = params.double("ratioJitter", 0.3)
        let minSize = params.double("minSize", 0.03) * minDim
        let gap = params.double("gap", 0.004) * minDim
        let fillChance = params.double("fillChance", 0.75)
        let lineWidth = params.double("lineWidth", 0.002) * minDim
        let style = params.int("style", 0)

        var leaves: [(CGRect, Int)] = []
        var stack: [(CGRect, Int)] = [(CGRect(origin: .zero, size: context.size), 0)]
        while let (rect, depth) = stack.popLast() {
            let canSplit = depth < maxDepth && max(rect.width, rect.height) > minSize * 2
            guard canSplit, depth < 2 || rng.chance(splitChance) else {
                leaves.append((rect, depth))
                continue
            }
            let vertical = rect.width > rect.height ? !rng.chance(0.15) : rng.chance(0.15)
            let ratio = 0.5 + rng.jitter(jitter)
            if vertical {
                let w = rect.width * ratio
                stack.append((CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height), depth + 1))
                stack.append((CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w, height: rect.height), depth + 1))
            } else {
                let h = rect.height * ratio
                stack.append((CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h), depth + 1))
                stack.append((CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h), depth + 1))
            }
        }

        var out: [VectorPrimitive] = []
        out.reserveCapacity(leaves.count)
        for (rect, depth) in leaves {
            let inner = rect.insetBy(dx: gap / 2, dy: gap / 2)
            guard inner.width > 0.5, inner.height > 0.5 else { continue }
            let t = Double(depth) / Double(max(maxDepth, 1))
            let color = GenColor.pick(params, palette: context.palette, t: t, rng: &rng)
            let filled = rng.chance(fillChance)
            let path: Path
            switch style {
            case 1:
                path = Path(roundedRect: inner, cornerRadius: min(inner.width, inner.height) * 0.22)
            case 2:
                let r = min(inner.width, inner.height) / 2 * 0.86
                path = GenShape.circle(center: CGPoint(x: inner.midX, y: inner.midY), radius: r)
            case 3:
                var lines = Path()
                let horizontal = inner.width < inner.height
                let spacing = max(lineWidth * 3, minDim * 0.006)
                if horizontal {
                    var y = inner.minY + spacing / 2
                    while y < inner.maxY { lines.move(to: CGPoint(x: inner.minX, y: y)); lines.addLine(to: CGPoint(x: inner.maxX, y: y)); y += spacing }
                } else {
                    var x = inner.minX + spacing / 2
                    while x < inner.maxX { lines.move(to: CGPoint(x: x, y: inner.minY)); lines.addLine(to: CGPoint(x: x, y: inner.maxY)); x += spacing }
                }
                out.append(VectorPrimitive(path: lines, stroke: color, lineWidth: max(0.3, lineWidth), lineCap: .butt))
                continue
            default:
                path = Path(inner)
            }
            if filled {
                out.append(VectorPrimitive(path: path, fill: color,
                                           stroke: lineWidth > 0 ? RGBAColor.black.withAlpha(0.85) : nil,
                                           lineWidth: max(0.3, lineWidth), lineJoin: .miter))
            } else if lineWidth > 0 {
                out.append(VectorPrimitive(path: path, stroke: color, lineWidth: max(0.3, lineWidth), lineJoin: .miter))
            }
        }
        return out
    }
}
