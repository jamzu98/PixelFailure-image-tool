import CoreGraphics
import SwiftUI

/// Writes the document as an SVG: pattern and text layers stay true vectors,
/// image layers are embedded as base64 PNG.
enum SVGExporter {
    static func svg(items: [RenderItem],
                    background: RGBAColor,
                    canvasSize: CGSize,
                    skippedGlobalEffects: Bool = false,
                    workingSpace: WorkingColorSpace = .sRGB) -> String {
        // SVG's rgb() is sRGB by definition — convert wide-gamut documents
        // up front (out-of-gamut colors clip; rasters keep their profiles
        // inside their embedded PNGs).
        let items = workingSpace == .sRGB ? items : items.map { srgbItem($0, from: workingSpace) }
        let background = background.converted(from: workingSpace, to: .sRGB)
        let w = Int(canvasSize.width)
        let h = Int(canvasSize.height)
        var defs = ""
        var body = ""
        var idCounter = 0

        for item in items {
            body += element(for: item, defs: &defs, idCounter: &idCounter)
        }

        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" \
        width="\(w)" height="\(h)" viewBox="0 0 \(w) \(h)">

        """
        if skippedGlobalEffects {
            out += "<!-- Canvas-level effects are raster-only and were not applied to this SVG. -->\n"
        }
        if !defs.isEmpty {
            out += "<defs>\n\(defs)</defs>\n"
        }
        out += "<rect width=\"\(w)\" height=\"\(h)\" fill=\"\(background.svgString)\"/>\n"
        out += body
        out += "</svg>\n"
        return out
    }

    /// Re-expresses every color an item carries in sRGB.
    private static func srgbItem(_ item: RenderItem, from space: WorkingColorSpace) -> RenderItem {
        var item = item
        item.styles = item.styles.map { style in
            var style = style
            style.color = style.color.converted(from: space, to: .sRGB)
            return style
        }
        switch item.content {
        case .primitives(let primitives):
            item.content = .primitives(primitives.map { primitive in
                var primitive = primitive
                primitive.fill = primitive.fill?.converted(from: space, to: .sRGB)
                primitive.stroke = primitive.stroke?.converted(from: space, to: .sRGB)
                return primitive
            })
        case .fill(var config):
            config.colors = config.colors.map { $0.converted(from: space, to: .sRGB) }
            item.content = .fill(config)
        case .group(let children):
            item.content = .group(children.map { srgbItem($0, from: space) })
        case .raster:
            break
        }
        return item
    }

    /// One item (recursively for groups) as a transformed, masked <g>.
    private static func element(for item: RenderItem, defs: inout String, idCounter: inout Int) -> String {
        idCounter += 1
        let index = idCounter
        var body = ""
        if let warning = item.svgWarning {
            body += "<!-- \(warning) -->\n"
        }

        let t = item.transform
        let transform = "matrix(\(fmt(t.a)),\(fmt(t.b)),\(fmt(t.c)),\(fmt(t.d)),\(fmt(t.tx)),\(fmt(t.ty)))"
        var style = ""
        if item.blendMode != .normal {
            style = " style=\"mix-blend-mode:\(item.blendMode.svgName)\""
        }
        let opacity = item.opacity < 0.999 ? " opacity=\"\(fmt(item.opacity))\"" : ""
        let filter = styleFilter(item.styles, index: index, defs: &defs)
        body += "<g transform=\"\(transform)\"\(opacity)\(style)\(filter)>\n"

        // Masks live on an untransformed inner group so their coordinates
        // are the layer's local space.
        if let mask = item.mask, let maskPNG = PNGExporter.pngData(mask.luminance) {
            let maskID = "mask\(index)"
            let mw = fmt(Double(item.naturalSize.width))
            let mh = fmt(Double(item.naturalSize.height))
            defs += "<mask id=\"\(maskID)\" maskUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" width=\"\(mw)\" height=\"\(mh)\">\n"
            defs += "<image width=\"\(mw)\" height=\"\(mh)\" preserveAspectRatio=\"none\" "
            defs += "xlink:href=\"data:image/png;base64,\(maskPNG.base64EncodedString())\"/>\n</mask>\n"
            body += "<g mask=\"url(#\(maskID))\">\n"
        }

        if let deformation = item.deformation {
            for (triangleIndex, triangle) in deformation.triangles(size: item.naturalSize).enumerated() {
                guard let map = triangle.affine else { continue }
                let clipID = "mesh\(index)_\(triangleIndex)"
                let points = [triangle.destination.0, triangle.destination.1, triangle.destination.2]
                    .map { "\(fmt(Double($0.x))),\(fmt(Double($0.y)))" }.joined(separator: " ")
                defs += "<clipPath id=\"\(clipID)\" clipPathUnits=\"userSpaceOnUse\"><polygon points=\"\(points)\"/></clipPath>\n"
                body += "<g clip-path=\"url(#\(clipID))\"><g transform=\"\(matrix(map))\">\n"
                body += contentElement(item.content, size: item.naturalSize,
                                       index: index * 1000 + triangleIndex,
                                       defs: &defs, idCounter: &idCounter)
                body += "</g></g>\n"
            }
        } else {
            body += contentElement(item.content, size: item.naturalSize, index: index,
                                   defs: &defs, idCounter: &idCounter)
        }

        if item.mask != nil {
            body += "</g>\n"
        }
        body += "</g>\n"
        return body
    }

    private static func contentElement(_ content: RenderItem.Content, size: CGSize,
                                       index: Int, defs: inout String,
                                       idCounter: inout Int) -> String {
        switch content {
        case .primitives(let primitives):
            return primitives.map(pathElement).joined()
        case .raster(let image):
            guard let png = PNGExporter.pngData(image) else { return "" }
            return "<image width=\"\(fmt(Double(size.width)))\" height=\"\(fmt(Double(size.height)))\" preserveAspectRatio=\"none\" xlink:href=\"data:image/png;base64,\(png.base64EncodedString())\"/>\n"
        case .fill(let config):
            return fillElement(config, size: size, index: index, defs: &defs)
        case .group(let children):
            return children.map { element(for: $0, defs: &defs, idCounter: &idCounter) }.joined()
        }
    }

    private static func matrix(_ t: CGAffineTransform) -> String {
        "matrix(\(fmt(t.a)),\(fmt(t.b)),\(fmt(t.c)),\(fmt(t.d)),\(fmt(t.tx)),\(fmt(t.ty)))"
    }

    private static func styleFilter(_ styles: [LayerStyle], index: Int,
                                    defs: inout String) -> String {
        let active = styles.filter(\.isEnabled)
        guard !active.isEmpty else { return "" }
        let id = "style\(index)"
        var filter = "<filter id=\"\(id)\" x=\"-50%\" y=\"-50%\" width=\"200%\" height=\"200%\">\n"
        var results: [String] = []
        for (styleIndex, layerStyle) in active.enumerated() {
            let result = "styleResult\(styleIndex)"
            let color = "rgb(\(Int(layerStyle.color.r * 255)),\(Int(layerStyle.color.g * 255)),\(Int(layerStyle.color.b * 255)))"
            let alpha = layerStyle.color.a * layerStyle.opacity
            switch layerStyle.type {
            case .dropShadow:
                filter += "<feDropShadow dx=\"\(fmt(layerStyle.offsetX))\" dy=\"\(fmt(layerStyle.offsetY))\" stdDeviation=\"\(fmt(layerStyle.size / 2))\" flood-color=\"\(color)\" flood-opacity=\"\(fmt(alpha))\" result=\"\(result)\"/>\n"
            case .outerGlow:
                let blur = "glowBlur\(styleIndex)", flood = "glowFlood\(styleIndex)"
                filter += "<feGaussianBlur in=\"SourceAlpha\" stdDeviation=\"\(fmt(layerStyle.size / 2))\" result=\"\(blur)\"/>\n"
                filter += "<feFlood flood-color=\"\(color)\" flood-opacity=\"\(fmt(alpha))\" result=\"\(flood)\"/>\n"
                filter += "<feComposite in=\"\(flood)\" in2=\"\(blur)\" operator=\"in\" result=\"\(result)\"/>\n"
            case .stroke:
                let grown = "strokeAlpha\(styleIndex)", flood = "strokeFlood\(styleIndex)"
                filter += "<feMorphology in=\"SourceAlpha\" operator=\"dilate\" radius=\"\(fmt(layerStyle.size))\" result=\"\(grown)\"/>\n"
                filter += "<feFlood flood-color=\"\(color)\" flood-opacity=\"\(fmt(alpha))\" result=\"\(flood)\"/>\n"
                filter += "<feComposite in=\"\(flood)\" in2=\"\(grown)\" operator=\"in\" result=\"\(result)\"/>\n"
            }
            results.append(result)
        }
        filter += "<feMerge>\n"
        for result in results { filter += "<feMergeNode in=\"\(result)\"/>\n" }
        filter += "<feMergeNode in=\"SourceGraphic\"/>\n</feMerge>\n</filter>\n"
        defs += filter
        return " filter=\"url(#\(id))\""
    }

    private static func fillElement(_ config: FillConfig, size: CGSize, index: Int, defs: inout String) -> String {
        let w = fmt(Double(size.width))
        let h = fmt(Double(size.height))
        guard config.colors.count > 1, config.style != .solid else {
            let color = config.colors.first ?? .black
            return "<rect width=\"\(w)\" height=\"\(h)\" fill=\"\(color.svgString)\"/>\n"
        }

        let gradientID = "grad\(index)"
        let stops = config.colors.indices.map { i -> String in
            let offset = Double(i) / Double(config.colors.count - 1)
            return "<stop offset=\"\(fmt(offset))\" stop-color=\"\(config.colors[i].svgString)\"/>"
        }.joined(separator: "\n")

        switch config.style {
        case .linearGradient:
            let points = ShapeGeometry.linearGradientPoints(angleDegrees: config.angle, in: size)
            defs += "<linearGradient id=\"\(gradientID)\" gradientUnits=\"userSpaceOnUse\" "
            defs += "x1=\"\(fmt(points.start.x))\" y1=\"\(fmt(points.start.y))\" x2=\"\(fmt(points.end.x))\" y2=\"\(fmt(points.end.y))\">\n\(stops)\n</linearGradient>\n"
        case .radialGradient:
            defs += "<radialGradient id=\"\(gradientID)\" gradientUnits=\"userSpaceOnUse\" "
            defs += "cx=\"\(fmt(Double(size.width) / 2))\" cy=\"\(fmt(Double(size.height) / 2))\" r=\"\(fmt(Double(hypot(size.width, size.height)) / 2))\">\n\(stops)\n</radialGradient>\n"
        case .solid:
            break
        }
        return "<rect width=\"\(w)\" height=\"\(h)\" fill=\"url(#\(gradientID))\"/>\n"
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
