import CoreGraphics
import SwiftUI

nonisolated struct TruchetGenerator: PatternGenerator {
    var displayName: String { "Truchet Tiles" }

    var specs: [ParamSpec] {
        [
            .intSlider("columns", "Columns", min: 3, max: 40, initial: 10),
            .choice("style", "Style", options: ["Arcs", "Diagonals", "Both"], initial: 0),
            .slider("lineWidth", "Line Width", min: 0.03, max: 0.4, initial: 0.12),
            .toggle("multiScale", "Multi-Scale", initial: true),
            .slider("subdivide", "Subdivision", min: 0, max: 0.7, initial: 0.3),
            .toggle("perTileColor", "Color Per Tile", initial: false),
        ] + GenColor.specs
    }

    func generate(params: ParamValues, seed: UInt64, context: GeneratorContext) -> [VectorPrimitive] {
        var rng = SeededRNG(seed: seed)
        let size = context.size
        let columns = max(2, params.int("columns", 10))
        let cell = Double(size.width) / Double(columns)
        let rows = max(1, Int((Double(size.height) / cell).rounded(.up)))
        let style = params.int("style", 0)
        let lineWidth = params.double("lineWidth", 0.12) * cell
        let multiScale = params.bool("multiScale", true)
        let subdivideChance = params.double("subdivide", 0.3)
        let perTileColor = params.bool("perTileColor")

        var out: [VectorPrimitive] = []
        let baseColor = GenColor.pick(params, palette: context.palette, t: 0.5, rng: &rng)

        func tile(rect: CGRect, depth: Int) {
            if multiScale && depth < 2 && rng.chance(subdivideChance) {
                let w = rect.width / 2, h = rect.height / 2
                for dy in 0..<2 {
                    for dx in 0..<2 {
                        tile(rect: CGRect(x: rect.minX + CGFloat(dx) * w,
                                          y: rect.minY + CGFloat(dy) * h,
                                          width: w, height: h),
                             depth: depth + 1)
                    }
                }
                return
            }

            let orientation = rng.chance(0.5)
            let colorT = rng.unit()
            var colorRng = rng
            let color = perTileColor
                ? GenColor.pick(params, palette: context.palette, t: colorT, rng: &colorRng)
                : baseColor
            if perTileColor { rng = colorRng }
            let width = lineWidth * Double(rect.width) / cell
            let drawArcs = style == 0 || (style == 2 && rng.chance(0.5))

            if drawArcs {
                var path = Path()
                let r = rect.width / 2
                if orientation {
                    path.addArc(center: CGPoint(x: rect.minX, y: rect.minY), radius: r,
                                startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
                    path.move(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
                    path.addArc(center: CGPoint(x: rect.maxX, y: rect.maxY), radius: r,
                                startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
                } else {
                    path.addArc(center: CGPoint(x: rect.maxX, y: rect.minY), radius: r,
                                startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
                    path.move(to: CGPoint(x: rect.minX, y: rect.maxY - r))
                    path.addArc(center: CGPoint(x: rect.minX, y: rect.maxY), radius: r,
                                startAngle: .degrees(270), endAngle: .degrees(360), clockwise: false)
                }
                out.append(VectorPrimitive(path: path, stroke: color, lineWidth: max(0.3, width)))
            } else {
                var path = Path()
                if orientation {
                    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                } else {
                    path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
                    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                }
                out.append(VectorPrimitive(path: path, stroke: color, lineWidth: max(0.3, width), lineCap: .butt))
            }
        }

        for row in 0..<rows {
            for col in 0..<columns {
                tile(rect: CGRect(x: Double(col) * cell, y: Double(row) * cell, width: cell, height: cell),
                     depth: 0)
            }
        }
        return out
    }
}
