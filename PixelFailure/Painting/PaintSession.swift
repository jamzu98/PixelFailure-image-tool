import CoreGraphics
import Foundation

/// A live brush stroke session: an offscreen bitmap (the layer's pixels or its
/// mask) that stamps accumulate into. The viewport shows `currentImage` while
/// the stroke is in flight; on mouse-up the buffer is committed to the
/// document as one undo step.
@MainActor
final class PaintSession {
    enum Target {
        case content(layerID: UUID)
        case mask(layerID: UUID)
    }

    let target: Target
    let pixelSize: CGSize
    private let context: CGContext
    private(set) var currentImage: CGImage?
    private var lastPoint: CGPoint?

    var targetLayerID: UUID {
        switch target {
        case .content(let id), .mask(let id): id
        }
    }

    var isMask: Bool {
        if case .mask = target { true } else { false }
    }

    /// `base` seeds the buffer (existing pixels / existing mask).
    /// `clipPath` (buffer space, even-odd) confines strokes to a selection.
    init?(target: Target, base: CGImage?, pixelSize: CGSize, clipPath: CGPath? = nil) {
        self.target = target
        self.pixelSize = pixelSize
        let width = max(1, Int(pixelSize.width))
        let height = max(1, Int(pixelSize.height))

        let isMask = if case .mask = target { true } else { false }
        let ctx: CGContext?
        if isMask {
            ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)
        } else {
            ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let ctx else { return nil }
        self.context = ctx

        if let base {
            // Buffers are in CG (y-up) space; strokes flip their y instead, so
            // the base image draws directly.
            ctx.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        if let clipPath {
            ctx.addPath(clipPath)
            ctx.clip(using: .evenOdd)
        }
        currentImage = ctx.makeImage()
    }

    /// Extends the stroke to a new point (buffer pixel coordinates, y-down),
    /// stamping along the way.
    func stroke(to point: CGPoint,
                radius: Double,
                hardness: Double,
                opacity: Double,
                color: RGBAColor,
                erase: Bool) {
        // Flip into the buffer's y-up space.
        let target = CGPoint(x: point.x, y: pixelSize.height - point.y)
        let radius = max(0.5, radius)

        if let last = lastPoint {
            let distance = hypot(target.x - last.x, target.y - last.y)
            let spacing = max(1, radius * 0.3)
            let steps = max(1, Int(distance / spacing))
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let p = CGPoint(x: last.x + (target.x - last.x) * t,
                                y: last.y + (target.y - last.y) * t)
                stamp(at: p, radius: radius, hardness: hardness, opacity: opacity, color: color, erase: erase)
            }
        } else {
            stamp(at: target, radius: radius, hardness: hardness, opacity: opacity, color: color, erase: erase)
        }
        lastPoint = target
        currentImage = context.makeImage()
    }

    func endStroke() {
        lastPoint = nil
    }

    private func stamp(at center: CGPoint,
                       radius: Double,
                       hardness: Double,
                       opacity: Double,
                       color: RGBAColor,
                       erase: Bool) {
        // Radial falloff: full opacity to `hardness`, fading to zero at the rim.
        let alpha = min(max(opacity, 0.01), 1)
        let gradientColors: [CGColor]
        let space: CGColorSpace
        if isMask {
            space = CGColorSpaceCreateDeviceGray()
            let gray = color.luminance
            gradientColors = [CGColor(gray: gray, alpha: alpha),
                              CGColor(gray: gray, alpha: alpha),
                              CGColor(gray: gray, alpha: 0)]
        } else {
            space = CGColorSpace(name: CGColorSpace.sRGB)!
            let base = erase ? RGBAColor.white : color
            gradientColors = [base.withAlpha(alpha).cgColor,
                              base.withAlpha(alpha).cgColor,
                              base.withAlpha(0).cgColor]
        }
        let locations: [CGFloat] = [0, CGFloat(min(max(hardness, 0), 0.99)), 1]
        guard let gradient = CGGradient(colorsSpace: space,
                                        colors: gradientColors as CFArray,
                                        locations: locations) else { return }

        context.saveGState()
        context.setBlendMode(erase && !isMask ? .destinationOut : .normal)
        context.drawRadialGradient(gradient,
                                   startCenter: center, startRadius: 0,
                                   endCenter: center, endRadius: CGFloat(radius),
                                   options: [])
        context.restoreGState()
    }
}
