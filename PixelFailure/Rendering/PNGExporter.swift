import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

/// Renders the document into a bitmap at an exact pixel size and encodes PNG.
/// If the target aspect differs from the canvas, the artwork scales to fill
/// and center-crops — the wallpaper-friendly behavior.
enum PNGExporter {
    static func render(items: [RenderItem],
                       background: RGBAColor,
                       canvasSize: CGSize,
                       targetPixelSize: CGSize) -> CGImage? {
        let width = Int(targetPixelSize.width)
        let height = Int(targetPixelSize.height)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        ctx.interpolationQuality = .high

        // Flip into y-down canvas coordinates.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        // Scale-to-fill mapping from canvas to target.
        let scale = max(targetPixelSize.width / canvasSize.width,
                        targetPixelSize.height / canvasSize.height)
        ctx.translateBy(x: (targetPixelSize.width - canvasSize.width * scale) / 2,
                        y: (targetPixelSize.height - canvasSize.height * scale) / 2)
        ctx.scaleBy(x: scale, y: scale)

        ctx.clip(to: CGRect(origin: .zero, size: canvasSize))
        ctx.setFillColor(background.cgColor)
        ctx.fill(CGRect(origin: .zero, size: canvasSize))

        for item in items {
            drawItem(item, context: ctx)
        }

        return ctx.makeImage()
    }

    /// Draws one item (recursively for groups) with opacity, blend mode,
    /// transform, and mask.
    private static func drawItem(_ item: RenderItem, context ctx: CGContext) {
        ctx.saveGState()
        ctx.setAlpha(CGFloat(item.opacity))
        ctx.setBlendMode(item.blendMode.cgBlendMode)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.concatenate(item.transform)

        let naturalRect = CGRect(origin: .zero, size: item.naturalSize)

        for style in item.styles where style.isEnabled {
            drawStyle(style, content: item.content, naturalRect: naturalRect, context: ctx)
        }
        drawContent(item.content, naturalRect: naturalRect, context: ctx)

        // Mask inside the layer's transparency layer: keep only the pixels
        // where the mask's alpha is set.
        if let mask = item.mask {
            ctx.saveGState()
            ctx.setBlendMode(.destinationIn)
            drawUpright(mask.alpha, in: naturalRect, context: ctx)
            ctx.restoreGState()
        }

        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private static func drawContent(_ content: RenderItem.Content, naturalRect: CGRect,
                                    context ctx: CGContext) {
        switch content {
        case .primitives(let primitives):
            for primitive in primitives {
                let cgPath = primitive.path.cgPath
                if let fill = primitive.fill {
                    ctx.addPath(cgPath)
                    ctx.setFillColor(fill.cgColor)
                    ctx.fillPath()
                }
                if let stroke = primitive.stroke {
                    ctx.addPath(cgPath)
                    ctx.setStrokeColor(stroke.cgColor)
                    ctx.setLineWidth(CGFloat(primitive.lineWidth))
                    ctx.setLineCap(primitive.lineCap)
                    ctx.setLineJoin(primitive.lineJoin)
                    ctx.setLineDash(phase: 0, lengths: primitive.dash)
                    ctx.strokePath()
                }
            }
        case .raster(let image):
            drawUpright(image, in: naturalRect, context: ctx)
        case .fill(let config):
            drawFill(config, in: naturalRect, context: ctx)
        case .group(let children):
            for child in children {
                drawItem(child, context: ctx)
            }
        }
    }

    private static func drawStyle(_ style: LayerStyle, content: RenderItem.Content,
                                  naturalRect: CGRect, context ctx: CGContext) {
        let color = style.color.withAlpha(style.color.a * style.opacity).cgColor
        func drawShadow(offset: CGSize, blur: CGFloat) {
            ctx.saveGState()
            ctx.setShadow(offset: offset, blur: blur, color: color)
            drawContent(content, naturalRect: naturalRect, context: ctx)
            ctx.restoreGState()
        }
        switch style.type {
        case .dropShadow:
            drawShadow(offset: CGSize(width: style.offsetX, height: style.offsetY), blur: style.size)
        case .outerGlow:
            drawShadow(offset: .zero, blur: style.size)
        case .stroke:
            for index in 0..<8 {
                let angle = Double(index) * .pi / 4
                drawShadow(offset: CGSize(width: cos(angle) * style.size,
                                          height: sin(angle) * style.size), blur: 0)
            }
        }
    }

    /// Draws a CGImage upright inside our y-down coordinate space.
    private static func drawUpright(_ image: CGImage, in rect: CGRect, context ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    private static func drawFill(_ config: FillConfig, in rect: CGRect, context ctx: CGContext) {
        guard config.colors.count > 1, config.style != .solid else {
            ctx.setFillColor((config.colors.first ?? .black).cgColor)
            ctx.fill(rect)
            return
        }
        let cgColors = config.colors.map(\.cgColor) as CFArray
        let locations: [CGFloat] = config.colors.indices.map {
            CGFloat($0) / CGFloat(config.colors.count - 1)
        }
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: cgColors,
                                        locations: locations) else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        switch config.style {
        case .linearGradient:
            let points = ShapeGeometry.linearGradientPoints(angleDegrees: config.angle, in: rect.size)
            ctx.drawLinearGradient(gradient, start: points.start, end: points.end,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .radialGradient:
            let center = CGPoint(x: rect.midX, y: rect.midY)
            ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                   endCenter: center,
                                   endRadius: hypot(rect.width, rect.height) / 2,
                                   options: [.drawsAfterEndLocation])
        case .solid:
            break
        }
        ctx.restoreGState()
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
