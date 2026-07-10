import SwiftUI

/// Draws resolved render items into a SwiftUI GraphicsContext (the live viewport).
enum CanvasRenderer {
    static func draw(items: [RenderItem],
                     background: RGBAColor,
                     canvasSize: CGSize,
                     in context: GraphicsContext,
                     space: WorkingColorSpace = .sRGB) {
        var clipped = context
        clipped.clip(to: Path(CGRect(origin: .zero, size: canvasSize)))
        clipped.fill(Path(CGRect(origin: .zero, size: canvasSize)),
                     with: .color(background.color(in: space)))

        for item in items {
            drawItem(item, in: clipped, space: space)
        }
    }

    /// Draws one item (recursively for groups) with its opacity, blend mode,
    /// transform, and mask.
    static func drawItem(_ item: RenderItem, in context: GraphicsContext,
                         space: WorkingColorSpace = .sRGB) {
        var layerContext = context
        layerContext.opacity = item.opacity
        layerContext.blendMode = item.blendMode.graphicsContextMode
        layerContext.drawLayer { inner in
            inner.concatenate(item.transform)
            let naturalRect = CGRect(origin: .zero, size: item.naturalSize)
            if let mask = item.mask {
                inner.clipToLayer { maskContext in
                    maskContext.draw(Image(decorative: mask.alpha, scale: 1), in: naturalRect)
                }
            }
            for style in item.styles where style.isEnabled {
                drawStyle(style, content: item.content, naturalRect: naturalRect, in: inner, space: space)
            }
            draw(item.content, naturalRect: naturalRect, in: inner, space: space)
        }
    }

    private static func drawStyle(_ style: LayerStyle, content: RenderItem.Content,
                                  naturalRect: CGRect, in context: GraphicsContext,
                                  space: WorkingColorSpace) {
        let color = style.color.withAlpha(style.color.a * style.opacity).color(in: space)
        switch style.type {
        case .dropShadow:
            var styled = context
            styled.addFilter(.shadow(color: color, radius: style.size,
                                     x: style.offsetX, y: style.offsetY))
            draw(content, naturalRect: naturalRect, in: styled, space: space)
        case .outerGlow:
            var styled = context
            styled.addFilter(.shadow(color: color, radius: style.size, x: 0, y: 0))
            draw(content, naturalRect: naturalRect, in: styled, space: space)
        case .stroke:
            for index in 0..<8 {
                let angle = Double(index) * .pi / 4
                var styled = context
                styled.addFilter(.shadow(color: color, radius: 0,
                                         x: cos(angle) * style.size,
                                         y: sin(angle) * style.size))
                draw(content, naturalRect: naturalRect, in: styled, space: space)
            }
        }
    }

    private static func draw(_ content: RenderItem.Content, naturalRect: CGRect,
                             in context: GraphicsContext, space: WorkingColorSpace) {
        switch content {
        case .primitives(let primitives):
            for primitive in primitives {
                if let fill = primitive.fill {
                    context.fill(primitive.path, with: .color(fill.color(in: space)))
                }
                if let stroke = primitive.stroke {
                    context.stroke(primitive.path, with: .color(stroke.color(in: space)),
                                   style: primitive.strokeStyle)
                }
            }
        case .raster(let image):
            context.draw(Image(decorative: image, scale: 1), in: naturalRect)
        case .fill(let config):
            context.fill(Path(naturalRect), with: shading(for: config, in: naturalRect.size, space: space))
        case .group(let children):
            for child in children {
                drawItem(child, in: context, space: space)
            }
        }
    }

    private static func shading(for config: FillConfig, in size: CGSize,
                                space: WorkingColorSpace) -> GraphicsContext.Shading {
        let colors = config.colors.map { $0.color(in: space) }
        guard colors.count > 1, config.style != .solid else {
            return .color(colors.first ?? .black)
        }
        switch config.style {
        case .solid:
            return .color(colors[0])
        case .linearGradient:
            let points = ShapeGeometry.linearGradientPoints(angleDegrees: config.angle, in: size)
            return .linearGradient(Gradient(colors: colors), startPoint: points.start, endPoint: points.end)
        case .radialGradient:
            return .radialGradient(Gradient(colors: colors),
                                   center: CGPoint(x: size.width / 2, y: size.height / 2),
                                   startRadius: 0,
                                   endRadius: Double(hypot(size.width, size.height)) / 2)
        }
    }
}
