import SwiftUI

/// Draws resolved render items into a SwiftUI GraphicsContext (the live viewport).
enum CanvasRenderer {
    static func draw(items: [RenderItem],
                     background: RGBAColor,
                     canvasSize: CGSize,
                     in context: GraphicsContext) {
        var clipped = context
        clipped.clip(to: Path(CGRect(origin: .zero, size: canvasSize)))
        clipped.fill(Path(CGRect(origin: .zero, size: canvasSize)), with: .color(background.color))

        for item in items {
            var layerContext = clipped
            layerContext.opacity = item.opacity
            layerContext.blendMode = item.blendMode.graphicsContextMode
            layerContext.drawLayer { inner in
                inner.concatenate(item.transform)
                switch item.content {
                case .primitives(let primitives):
                    for primitive in primitives {
                        if let fill = primitive.fill {
                            inner.fill(primitive.path, with: .color(fill.color))
                        }
                        if let stroke = primitive.stroke {
                            inner.stroke(primitive.path, with: .color(stroke.color), style: primitive.strokeStyle)
                        }
                    }
                case .raster(let image):
                    inner.draw(Image(decorative: image, scale: 1),
                               in: CGRect(origin: .zero, size: item.naturalSize))
                }
            }
        }
    }
}
