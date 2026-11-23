import CoreGraphics
import Foundation

/// SVG for pen plotters: only strokes, in canvas coordinates, one layer per
/// pen (color and width), each layer drawn nearest-first with touching ends
/// joined so the pen lifts as little as possible. Fills become outlines;
/// images and fill layers can't be plotted and are left out.
nonisolated enum PlotterSVG {
    struct Stroke: Equatable {
        var points: [CGPoint]
        var color: String
        var width: Double
    }

    static func svg(items: [RenderItem], canvasSize: CGSize) -> String {
        let strokes = order(collect(items, canvasSize: canvasSize))
        var groups: [(key: String, color: String, width: Double, strokes: [Stroke])] = []
        for stroke in strokes {
            let key = "\(stroke.color)-\(String(format: "%.2f", stroke.width))"
            if let index = groups.firstIndex(where: { $0.key == key }) {
                groups[index].strokes.append(stroke)
            } else {
                groups.append((key, stroke.color, stroke.width, [stroke]))
            }
        }
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" \
        width="\(fmt(canvasSize.width))" height="\(fmt(canvasSize.height))" \
        viewBox="0 0 \(fmt(canvasSize.width)) \(fmt(canvasSize.height))">

        """
        for (index, group) in groups.enumerated() {
            out += "<g id=\"pen-\(index + 1)\" inkscape:groupmode=\"layer\" inkscape:label=\"Pen \(index + 1) \(group.color)\" "
            out += "fill=\"none\" stroke=\"\(group.color)\" stroke-width=\"\(fmt(group.width))\" "
            out += "stroke-linecap=\"round\" stroke-linejoin=\"round\">\n"
            for stroke in group.strokes {
                guard let first = stroke.points.first else { continue }
                var d = "M\(fmt(first.x)) \(fmt(first.y))"
                for point in stroke.points.dropFirst() { d += " L\(fmt(point.x)) \(fmt(point.y))" }
                out += "<path d=\"\(d)\"/>\n"
            }
            out += "</g>\n"
        }
        return out + "</svg>\n"
    }

    /// Flattened polylines of every stroked or filled primitive, clipped to
    /// the canvas (and to clipping layers' bounds), in canvas coordinates.
    static func collect(_ items: [RenderItem], canvasSize: CGSize,
                        parent: CGAffineTransform = .identity) -> [Stroke] {
        let canvas = RegionClipper(region: CGPath(rect: CGRect(origin: .zero, size: canvasSize), transform: nil))
        var strokes: [Stroke] = []
        for item in items {
            let world = item.transform.concatenating(parent)
            switch item.content {
            case .group(let children):
                strokes += collect(children, canvasSize: canvasSize, parent: world)
            case .primitives(let primitives):
                let bounds: RegionClipper? = item.clipsToBounds
                    ? RegionClipper(region: CGPath(rect: CGRect(origin: .zero, size: item.naturalSize),
                                                   transform: [world]))
                    : nil
                let scale = max(hypot(world.a, world.b), hypot(world.c, world.d))
                for primitive in primitives {
                    guard let color = primitive.stroke ?? primitive.fill, color.a > 0.01 else { continue }
                    let width = primitive.stroke != nil ? primitive.lineWidth * scale : max(1, scale * 0.5)
                    var path = primitive.path.cgPath.copy(using: [world]) ?? primitive.path.cgPath
                    if let bounds { path = bounds.clip(path, keepInside: true) }
                    path = canvas.clip(path, keepInside: true)
                    for polyline in RegionClipper.flatten(path, closeSubpaths: false) where polyline.count > 1 {
                        strokes.append(Stroke(points: polyline, color: color.hexString, width: width))
                    }
                }
            case .raster, .fill:
                continue
            }
        }
        return strokes
    }

    /// Per pen, chains polylines nearest-first from where the pen is,
    /// reversing them when their far end is closer and merging ones that
    /// continue exactly where the last ended.
    static func order(_ strokes: [Stroke]) -> [Stroke] {
        var pens: [String] = []
        var byPen: [String: [Stroke]] = [:]
        for stroke in strokes {
            let key = "\(stroke.color)-\(String(format: "%.2f", stroke.width))"
            if byPen[key] == nil { pens.append(key) }
            byPen[key, default: []].append(stroke)
        }
        var out: [Stroke] = []
        for pen in pens {
            var remaining = byPen[pen] ?? []
            var position = CGPoint.zero
            var chain: [Stroke] = []
            while !remaining.isEmpty {
                var best = 0, bestDistance = CGFloat.greatestFiniteMagnitude, reverse = false
                for (index, stroke) in remaining.enumerated() {
                    let start = distance(position, stroke.points[0])
                    let end = distance(position, stroke.points[stroke.points.count - 1])
                    if start < bestDistance { bestDistance = start; best = index; reverse = false }
                    if end < bestDistance { bestDistance = end; best = index; reverse = true }
                }
                var next = remaining.remove(at: best)
                if reverse { next.points.reverse() }
                if bestDistance < 0.01, !chain.isEmpty {
                    chain[chain.count - 1].points += next.points.dropFirst()
                } else {
                    chain.append(next)
                }
                position = next.points[next.points.count - 1]
            }
            out += chain
        }
        return out
    }

    /// Pen-up distance when drawing `strokes` in order from the origin.
    static func travel(_ strokes: [Stroke]) -> CGFloat {
        var position = CGPoint.zero, total: CGFloat = 0
        for stroke in strokes {
            total += distance(position, stroke.points[0])
            position = stroke.points[stroke.points.count - 1]
        }
        return total
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    private static func fmt(_ value: CGFloat) -> String { String(format: "%.2f", Double(value)) }
    private static func fmt(_ value: Double) -> String { String(format: "%.2f", value) }
}
