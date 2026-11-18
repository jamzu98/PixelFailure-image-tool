import CoreGraphics
import CoreImage
import SwiftUI

/// Rasterizes a selection path into bitmaps for pixel operations.
/// All outputs are in the *target buffer's* space: callers pass the transform
/// from canvas coordinates into buffer pixels (including any y-flip), so the
/// result composites directly onto layer buffers.
@MainActor
enum SelectionRasterizer {
    /// RGBA image: `color` inside the selection (alpha = coverage), clear
    /// outside. Feather (canvas px, scaled by the transform) blurs the edge.
    /// Draw with .destinationOut to delete, .sourceOver to fill, or
    /// .destinationIn to keep-only.
    static func colorMask(selection: CanvasSelection,
                          transform: CGAffineTransform,
                          pixelSize: CGSize,
                          color: RGBAColor = .white,
                          colorSettings: ColorSettings = .default) -> CGImage? {
        let width = max(1, Int(pixelSize.width))
        let height = max(1, Int(pixelSize.height))
        guard let ctx = colorSettings.makeRGBAContext(width: width, height: height) else { return nil }

        ctx.setFillColor(color.cgColor(in: colorSettings.workingSpace))
        if let matte = selection.matte {
            ctx.saveGState()
            matte.clip(ctx, transform: transform)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.restoreGState()
        } else {
            // Apply the canvas→buffer transform to the path, not the context, so
            // the feather blur below operates in buffer pixels.
            ctx.beginPath()
            if let transformed = withTransform(selection.path.cgPath, transform) {
                ctx.addPath(transformed)
            }
            ctx.fillPath(using: .evenOdd)
        }
        guard var image = ctx.makeImage() else { return nil }

        // Feather: gaussian blur scaled to buffer pixels.
        let scale = (hypot(transform.a, transform.b) + hypot(transform.c, transform.d)) / 2
        let radius = selection.feather * Double(scale)
        if radius > 0.25 {
            let extent = CGRect(x: 0, y: 0, width: width, height: height)
            let blurred = CIImage(cgImage: image)
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: extent)
            if let soft = sharedCIContext.createCGImage(blurred, from: extent) {
                image = soft
            }
        }
        return image
    }

    /// Grayscale (white = selected) — the layer-mask storage format.
    static func grayMask(selection: CanvasSelection,
                         transform: CGAffineTransform,
                         pixelSize: CGSize) -> CGImage? {
        let width = max(1, Int(pixelSize.width))
        let height = max(1, Int(pixelSize.height))
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let matte = selection.matte {
            matte.draw(into: ctx, transform: transform)
        } else {
            ctx.beginPath()
            if let transformed = withTransform(selection.path.cgPath, transform) {
                ctx.addPath(transformed)
            }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillPath(using: .evenOdd)
        }
        guard var image = ctx.makeImage() else { return nil }

        let scale = (hypot(transform.a, transform.b) + hypot(transform.c, transform.d)) / 2
        let radius = selection.feather * Double(scale)
        if radius > 0.25 {
            let extent = CGRect(x: 0, y: 0, width: width, height: height)
            let blurred = CIImage(cgImage: image)
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: extent)
            if let soft = sharedCIContext.createCGImage(blurred, from: extent) {
                image = soft
            }
        }
        return image
    }

    /// The canvas→buffer transform for a layer's content pixels (matches the
    /// coordinate mapping painting uses), including the buffer's y-flip.
    /// `parentAffine` accounts for enclosing groups.
    static func canvasToContentBuffer(layer: Layer, naturalSize: CGSize, config: ImageConfig,
                                      parentAffine: CGAffineTransform = .identity) -> CGAffineTransform? {
        let affine = layer.transform.affine(naturalSize: naturalSize).concatenating(parentAffine)
        guard affine.isInvertible else { return nil }
        var t = affine.inverted()
        if let crop = config.crop {
            t = t.concatenating(CGAffineTransform(translationX: crop.minX * config.pixelSize.width,
                                                  y: crop.minY * config.pixelSize.height))
        }
        // Flip into the buffer's bottom-up orientation.
        return t.concatenating(CGAffineTransform(scaleX: 1, y: -1)
            .translatedBy(x: 0, y: -config.pixelSize.height))
    }

    /// Canvas→buffer transform for an arbitrary local-space bitmap (masks,
    /// resolved layer images) of `bufferPixelSize` covering `naturalSize`.
    static func canvasToLocalBuffer(layer: Layer, naturalSize: CGSize, bufferPixelSize: CGSize,
                                    parentAffine: CGAffineTransform = .identity) -> CGAffineTransform? {
        let affine = layer.transform.affine(naturalSize: naturalSize).concatenating(parentAffine)
        guard affine.isInvertible, naturalSize.width > 0 else { return nil }
        let scale = bufferPixelSize.width / naturalSize.width
        return affine.inverted()
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(scaleX: 1, y: -1)
                .translatedBy(x: 0, y: -bufferPixelSize.height))
    }

    private static let sharedCIContext = CIContext(options: [.cacheIntermediates: false])

    private static func withTransform(_ path: CGPath, _ transform: CGAffineTransform) -> CGPath? {
        var t = transform
        return path.copy(using: &t)
    }
}
