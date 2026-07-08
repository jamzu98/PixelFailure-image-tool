import CoreGraphics
import SwiftUI

/// Writes the document as an SVG: pattern and text layers stay true vectors,
/// image layers are embedded as base64 PNG.
enum SVGExporter {
    static func svg(items: [RenderItem],
                    background: RGBAColor,
                    canvasSize: CGSize) -> String {
        let w = Int(canvasSize.width)
        let h = Int(canvasSize.height)
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" \
        width="\(w)" height="\(h)" viewBox="0 0 \(w) \(h)">
        <rect width="\(w)" height="\(h)" fill="\(background.svgString)"/>

        """

        for item in items {
            let t = item.transform
            let transform = "matrix(\(fmt(t.a)),\(fmt(t.b)),\(fmt(t.c)),\(fmt(t.d)),\(fmt(t.tx)),\(fmt(t.ty)))"
            var style = ""
            if item.blendMode != .normal {
                style = " style=\"mix-blend-mode:\(item.blendMode.svgName)\""
            }
            let opacity = item.opacity < 0.999 ? " opacity=\"\(fmt(item.opacity))\"" : ""
            out += "<g transform=\"\(transform)\"\(opacity)\(style)>\n"

            switch item.content {
            case .primitives(let primitives):
                for primitive in primitives {
                    out += pathElement(primitive)
                }
            case .raster(let image):
                if let png = PNGExporter.pngData(image) {
                    let base64 = png.base64EncodedString()
                    out += "<image width=\"\(fmt(Double(item.naturalSize.width)))\" height=\"\(fmt(Double(item.naturalSize.height)))\" "
                    out += "preserveAspectRatio=\"none\" xlink:href=\"data:image/png;base64,\(base64)\"/>\n"
                }
            }
            out += "</g>\n"
        }

        out += "</svg>\n"
        return out
    }

    private static func pathElement(_ primitive: VectorPrimitive) -> String {
        let d = pathData(primitive.path.cgPath)
        guard !d.isEmpty else { return "" }
        var attrs = "d=\"\(d)\""
        if let fill = primitive.fill {
            attrs += " fill=\"\(fill.svgString)\""
            if fill.a < 0.999 { /* alpha already in rgba() */ }
        } else {
            attrs += " fill=\"none\""
        }
        if let stroke = primitive.stroke {
            attrs += " stroke=\"\(stroke.svgString)\" stroke-width=\"\(fmt(primitive.lineWidth))\""
            attrs += " stroke-linecap=\"\(capName(primitive.lineCap))\" stroke-linejoin=\"\(joinName(primitive.lineJoin))\""
            if !primitive.dash.isEmpty {
                attrs += " stroke-dasharray=\"\(primitive.dash.map { fmt(Double($0)) }.joined(separator: " "))\""
            }
        }
        return "<path \(attrs)/>\n"
    }

    private static func pathData(_ path: CGPath) -> String {
        var d = ""
        path.applyWithBlock { elementPtr in
            let element = elementPtr.pointee
            switch element.type {
            case .moveToPoint:
                let p = element.points[0]
                d += "M\(fmt(p.x)) \(fmt(p.y))"
            case .addLineToPoint:
                let p = element.points[0]
                d += "L\(fmt(p.x)) \(fmt(p.y))"
            case .addQuadCurveToPoint:
                let c = element.points[0], p = element.points[1]
                d += "Q\(fmt(c.x)) \(fmt(c.y)) \(fmt(p.x)) \(fmt(p.y))"
            case .addCurveToPoint:
                let c1 = element.points[0], c2 = element.points[1], p = element.points[2]
                d += "C\(fmt(c1.x)) \(fmt(c1.y)) \(fmt(c2.x)) \(fmt(c2.y)) \(fmt(p.x)) \(fmt(p.y))"
            case .closeSubpath:
                d += "Z"
            @unknown default:
                break
            }
        }
        return d
    }

    private static func capName(_ cap: CGLineCap) -> String {
        switch cap {
        case .round: "round"
        case .square: "square"
        default: "butt"
        }
    }

    private static func joinName(_ join: CGLineJoin) -> String {
        switch join {
        case .round: "round"
        case .bevel: "bevel"
        default: "miter"
        }
    }

    private static func fmt(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e7 {
            return String(Int(value))
        }
        var s = String(format: "%.2f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    private static func fmt(_ value: CGFloat) -> String { fmt(Double(value)) }
}
