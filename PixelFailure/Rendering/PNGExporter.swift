import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

/// Renders the document into a bitmap at an exact pixel size and encodes PNG.
/// If the target aspect differs from the canvas, the artwork scales to fill
/// and center-crops — the wallpaper-friendly behavior.
nonisolated enum PNGExporter {
    static func render(items: [RenderItem],
                       background: RGBAColor,
                       canvasSize: CGSize,
                       targetPixelSize: CGSize,
                       colorSettings: ColorSettings = .default) -> CGImage? {
        let width = Int(targetPixelSize.width)
        let height = Int(targetPixelSize.height)
        guard width > 0, height > 0,
              let ctx = colorSettings.makeRGBAContext(width: width, height: height) else { return nil }
        let space = colorSettings.workingSpace

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

        drawCanvas(items: items, background: background, canvasSize: canvasSize,
                   context: ctx, space: space)

        return ctx.makeImage()
    }

    /// Shared Core Graphics ground truth for export and retained viewport tiles.
    /// The caller supplies the canvas-to-destination transform; drawing here
    /// always happens in the document's y-down canvas coordinate system.
    static func drawCanvas(items: [RenderItem],
                           background: RGBAColor,
                           canvasSize: CGSize,
                           context ctx: CGContext,
                           space: WorkingColorSpace) {
        ctx.saveGState()
        ctx.clip(to: CGRect(origin: .zero, size: canvasSize))
        ctx.setFillColor(background.cgColor(in: space))
        ctx.fill(CGRect(origin: .zero, size: canvasSize))
        for item in items {
            drawItem(item, context: ctx, space: space)
        }
        ctx.restoreGState()
    }

    /// Draws one item (recursively for groups) with opacity, blend mode,
    /// transform, and mask.
    private static func drawItem(_ item: RenderItem, context ctx: CGContext,
                                 space: WorkingColorSpace) {
        ctx.saveGState()
        ctx.setAlpha(CGFloat(item.opacity))
        ctx.setBlendMode(item.blendMode.cgBlendMode)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.concatenate(item.transform)

        let naturalRect = CGRect(origin: .zero, size: item.naturalSize)
        if let deformation = item.deformation {
            drawDeformed(item, deformation: deformation, naturalRect: naturalRect,
                         context: ctx, space: space)
        } else {
            for style in item.styles where style.isEnabled {
                drawStyle(style, content: item.content, naturalRect: naturalRect, context: ctx, space: space)
            }
            drawContent(item.content, naturalRect: naturalRect, context: ctx, space: space)

            // Mask inside the layer's transparency layer: keep only the pixels
            // where the mask's alpha is set.
            if let mask = item.mask {
                ctx.saveGState()
                ctx.setBlendMode(.destinationIn)
                drawUpright(mask.alpha, in: naturalRect, context: ctx)
                ctx.restoreGState()
            }
        }

        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private static func drawDeformed(_ item: RenderItem, deformation: LayerDeformation,
                                     naturalRect: CGRect, context ctx: CGContext,
                                     space: WorkingColorSpace) {
        for triangle in deformation.triangles(size: item.naturalSize) {
            guard let map = triangle.affine else { continue }
            ctx.saveGState()
            let destination = CGMutablePath()
            destination.move(to: triangle.destination.0)
            destination.addLine(to: triangle.destination.1)
            destination.addLine(to: triangle.destination.2)
            destination.closeSubpath()
            ctx.addPath(destination)
            ctx.clip()
            ctx.concatenate(map)
            for style in item.styles where style.isEnabled {
                drawStyle(style, content: item.content, naturalRect: naturalRect, context: ctx, space: space)
            }
            drawContent(item.content, naturalRect: naturalRect, context: ctx, space: space)
            if let mask = item.mask {
                ctx.setBlendMode(.destinationIn)
                drawUpright(mask.alpha, in: naturalRect, context: ctx)
            }
            ctx.restoreGState()
        }
    }

    private static func drawContent(_ content: RenderItem.Content, naturalRect: CGRect,
                                    context ctx: CGContext, space: WorkingColorSpace) {
        switch content {
        case .primitives(let primitives):
            for primitive in primitives {
                let cgPath = primitive.path.cgPath
                if let fill = primitive.fill {
                    ctx.addPath(cgPath)
                    ctx.setFillColor(fill.cgColor(in: space))
                    ctx.fillPath()
                }
                if let stroke = primitive.stroke {
                    ctx.addPath(cgPath)
                    ctx.setStrokeColor(stroke.cgColor(in: space))
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
            drawFill(config, in: naturalRect, context: ctx, space: space)
        case .group(let children):
            for child in children {
                drawItem(child, context: ctx, space: space)
            }
        }
    }

    private static func drawStyle(_ style: LayerStyle, content: RenderItem.Content,
                                  naturalRect: CGRect, context ctx: CGContext,
                                  space: WorkingColorSpace) {
        let color = style.color.withAlpha(style.color.a * style.opacity).cgColor(in: space)
        func drawShadow(offset: CGSize, blur: CGFloat) {
            ctx.saveGState()
            ctx.setShadow(offset: offset, blur: blur, color: color)
            drawContent(content, naturalRect: naturalRect, context: ctx, space: space)
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

    private static func drawFill(_ config: FillConfig, in rect: CGRect, context ctx: CGContext,
                                 space: WorkingColorSpace) {
        guard config.colors.count > 1, config.style != .solid else {
            ctx.setFillColor((config.colors.first ?? .black).cgColor(in: space))
            ctx.fill(rect)
            return
        }
        let cgColors = config.colors.map { $0.cgColor(in: space) } as CFArray
        let locations: [CGFloat] = config.colors.indices.map {
            CGFloat($0) / CGFloat(config.colors.count - 1)
        }
        guard let gradient = CGGradient(colorsSpace: space.cgColorSpace,
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
