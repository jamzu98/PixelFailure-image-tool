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
            ctx.saveGState()
            ctx.setAlpha(CGFloat(item.opacity))
            ctx.setBlendMode(item.blendMode.cgBlendMode)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.concatenate(item.transform)

            switch item.content {
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
                // Un-flip locally so the raster draws upright.
                let rect = CGRect(origin: .zero, size: item.naturalSize)
                ctx.saveGState()
                ctx.translateBy(x: rect.minX, y: rect.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
                ctx.restoreGState()
            }

            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }

        return ctx.makeImage()
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
