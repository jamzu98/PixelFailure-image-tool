import CoreGraphics
import Foundation

/// A live brush stroke session: an offscreen bitmap (the layer's pixels or its
/// mask) that stamps accumulate into. The viewport shows `currentImage` while
/// the stroke is in flight; on mouse-up the buffer is committed to the
/// document as one undo step.
@MainActor
final class PaintSession {
    enum RetouchMode: Equatable { case clone, heal, smudge, dodge, burn }
    enum Target {
        case content(layerID: UUID)
        case mask(layerID: UUID)
    }

    let target: Target
    let pixelSize: CGSize
    private let colorSettings: ColorSettings
    private let context: CGContext
    private(set) var currentImage: CGImage?
    private var lastPoint: CGPoint?
    private let sourceImage: CGImage?
    private var retouchSourceOffset: CGVector?
    private var rng = SeededRNG(seed: SeededRNG.randomSeed())

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
    /// `clipMask` (buffer-space grayscale, white = paintable) softly confines
    /// strokes to a matte-backed selection; it wins over `clipPath`.
    init?(target: Target, base: CGImage?, pixelSize: CGSize, clipPath: CGPath? = nil,
          clipMask: CGImage? = nil, colorSettings: ColorSettings = .default) {
        self.target = target
        self.pixelSize = pixelSize
        self.colorSettings = colorSettings
        let width = max(1, Int(pixelSize.width))
        let height = max(1, Int(pixelSize.height))

        let isMask = if case .mask = target { true } else { false }
        let ctx: CGContext?
        if isMask {
            // Masks stay 8-bit grayscale — they carry coverage, not color.
            ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)
        } else {
            ctx = colorSettings.makeRGBAContext(width: width, height: height)
        }
        guard let ctx else { return nil }
        self.context = ctx
        self.sourceImage = base

        if let base {
            // Buffers are in CG (y-up) space; strokes flip their y instead, so
            // the base image draws directly.
            ctx.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        if let clipMask {
            ctx.clip(to: CGRect(x: 0, y: 0, width: width, height: height), mask: clipMask)
        } else if let clipPath {
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
                erase: Bool,
                spacing: Double = 0.15,
                smoothing: Double = 0,
                scatter: Double = 0,
                sizeJitter: Double = 0,
                opacityJitter: Double = 0,
                angleJitter: Double = 0,
                tipAspect: Double = 1,
                grain: Double = 0) {
        // Flip into the buffer's y-up space.
        var target = CGPoint(x: point.x, y: pixelSize.height - point.y)
        let radius = max(0.5, radius)

        if let last = lastPoint {
            let response = 1 - min(max(smoothing, 0), 0.95) * 0.88
            target = CGPoint(x: last.x + (target.x - last.x) * response,
                             y: last.y + (target.y - last.y) * response)
            let distance = hypot(target.x - last.x, target.y - last.y)
            let stampSpacing = max(1, radius * 2 * min(max(spacing, 0.02), 3))
            let steps = max(1, Int(distance / stampSpacing))
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let p = CGPoint(x: last.x + (target.x - last.x) * t,
                                y: last.y + (target.y - last.y) * t)
                dynamicStamp(at: p, radius: radius, hardness: hardness, opacity: opacity,
                             color: color, erase: erase, scatter: scatter,
                             sizeJitter: sizeJitter, opacityJitter: opacityJitter,
                             angleJitter: angleJitter, tipAspect: tipAspect, grain: grain)
            }
        } else {
            dynamicStamp(at: target, radius: radius, hardness: hardness, opacity: opacity,
                         color: color, erase: erase, scatter: scatter,
                         sizeJitter: sizeJitter, opacityJitter: opacityJitter,
                         angleJitter: angleJitter, tipAspect: tipAspect, grain: grain)
        }
        lastPoint = target
        currentImage = context.makeImage()
    }

    func endStroke() {
        lastPoint = nil
        retouchSourceOffset = nil
    }

    func retouch(to point: CGPoint, source: CGPoint?, mode: RetouchMode,
                 radius: Double, hardness: Double, opacity: Double,
                 spacing: Double, smoothing: Double) {
        var target = CGPoint(x: point.x, y: pixelSize.height - point.y)
        if let last = lastPoint {
            let response = 1 - min(max(smoothing, 0), 0.95) * 0.88
            target = CGPoint(x: last.x + (target.x - last.x) * response,
                             y: last.y + (target.y - last.y) * response)
        }
        if retouchSourceOffset == nil, let source {
            let flipped = CGPoint(x: source.x, y: pixelSize.height - source.y)
            retouchSourceOffset = CGVector(dx: flipped.x - target.x, dy: flipped.y - target.y)
        }
        let points: [CGPoint]
        if let last = lastPoint {
            let distance = hypot(target.x - last.x, target.y - last.y)
            let step = max(1, radius * 2 * max(spacing, 0.04))
            let count = max(1, Int(distance / step))
            points = (1...count).map { index in
                let t = CGFloat(index) / CGFloat(count)
                return CGPoint(x: last.x + (target.x - last.x) * t,
                               y: last.y + (target.y - last.y) * t)
            }
        } else { points = [target] }
        for point in points {
            switch mode {
            case .clone, .heal:
                cloneStamp(at: point, offset: retouchSourceOffset ?? .zero,
                           radius: radius, opacity: opacity, healing: mode == .heal)
            case .smudge:
                smudgeStamp(at: point, from: lastPoint ?? point,
                            radius: radius, opacity: opacity)
            case .dodge, .burn:
                toneStamp(at: point, radius: radius, hardness: hardness,
                          opacity: opacity, dodge: mode == .dodge)
            }
        }
        lastPoint = target
        currentImage = context.makeImage()
    }

    private func dynamicStamp(at center: CGPoint, radius: Double, hardness: Double,
                              opacity: Double, color: RGBAColor, erase: Bool,
                              scatter: Double, sizeJitter: Double, opacityJitter: Double) {
        dynamicStamp(at: center, radius: radius, hardness: hardness, opacity: opacity,
                     color: color, erase: erase, scatter: scatter, sizeJitter: sizeJitter,
                     opacityJitter: opacityJitter, angleJitter: 0, tipAspect: 1, grain: 0)
    }

    private func dynamicStamp(at center: CGPoint, radius: Double, hardness: Double,
                              opacity: Double, color: RGBAColor, erase: Bool,
                              scatter: Double, sizeJitter: Double, opacityJitter: Double,
                              angleJitter: Double, tipAspect: Double, grain: Double) {
        let angle = rng.range(0, .pi * 2)
        let spread = rng.unit() * max(scatter, 0) * radius
        let point = CGPoint(x: center.x + cos(angle) * spread,
                            y: center.y + sin(angle) * spread)
        let variedRadius = radius * (1 + rng.jitter(min(max(sizeJitter, 0), 1)))
        let variedOpacity = opacity * (1 + rng.jitter(min(max(opacityJitter, 0), 1)))
        let grainOpacity = variedOpacity * (1 - min(max(grain, 0), 1) * rng.unit() * 0.65)
        stamp(at: point, radius: max(0.5, variedRadius), hardness: hardness,
              opacity: min(max(grainOpacity, 0.01), 1), color: color, erase: erase,
              angle: rng.jitter(min(max(angleJitter, 0), 1)) * .pi,
              aspect: min(max(tipAspect, 0.1), 1))
    }

    private func cloneStamp(at target: CGPoint, offset: CGVector, radius: Double,
                            opacity: Double, healing: Bool) {
        guard let sourceImage else { return }
        let rect = CGRect(x: 0, y: 0, width: pixelSize.width, height: pixelSize.height)
        context.saveGState()
        context.addEllipse(in: CGRect(x: target.x - radius, y: target.y - radius,
                                      width: radius * 2, height: radius * 2))
        context.clip()
        context.setAlpha(CGFloat(min(max(opacity * (healing ? 0.45 : 1), 0), 1)))
        context.setBlendMode(.normal)
        context.translateBy(x: -offset.dx, y: -offset.dy)
        context.draw(sourceImage, in: rect)
        context.restoreGState()
    }

    private func smudgeStamp(at target: CGPoint, from previous: CGPoint,
                             radius: Double, opacity: Double) {
        guard let snapshot = context.makeImage() else { return }
        let rect = CGRect(x: 0, y: 0, width: pixelSize.width, height: pixelSize.height)
        context.saveGState()
        context.addEllipse(in: CGRect(x: target.x - radius, y: target.y - radius,
                                      width: radius * 2, height: radius * 2))
        context.clip()
        context.setAlpha(CGFloat(min(max(opacity * 0.55, 0), 1)))
        let dx = target.x - previous.x
        let dy = target.y - previous.y
        context.translateBy(x: abs(dx) + abs(dy) < 0.01 ? 1.5 : dx * 0.45,
                            y: abs(dx) + abs(dy) < 0.01 ? 1.5 : dy * 0.45)
        context.draw(snapshot, in: rect)
        context.restoreGState()
    }

    private func toneStamp(at center: CGPoint, radius: Double, hardness: Double,
                           opacity: Double, dodge: Bool) {
        context.saveGState()
        context.setBlendMode(.softLight)
        stamp(at: center, radius: radius, hardness: hardness,
              opacity: opacity * 0.3, color: dodge ? .white : .black, erase: false)
        context.restoreGState()
    }

    private func stamp(at center: CGPoint,
                       radius: Double,
                       hardness: Double,
                       opacity: Double,
                       color: RGBAColor,
                       erase: Bool,
                       angle: Double = 0,
                       aspect: Double = 1) {
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
            let workingSpace = colorSettings.workingSpace
            space = workingSpace.cgColorSpace
            let base = erase ? RGBAColor.white : color
            gradientColors = [base.withAlpha(alpha).cgColor(in: workingSpace),
                              base.withAlpha(alpha).cgColor(in: workingSpace),
                              base.withAlpha(0).cgColor(in: workingSpace)]
        }
        let locations: [CGFloat] = [0, CGFloat(min(max(hardness, 0), 0.99)), 1]
        guard let gradient = CGGradient(colorsSpace: space,
                                        colors: gradientColors as CFArray,
                                        locations: locations) else { return }

        context.saveGState()
        context.setBlendMode(erase && !isMask ? .destinationOut : .normal)
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: angle)
        context.scaleBy(x: 1, y: aspect)
        context.drawRadialGradient(gradient,
                                   startCenter: .zero, startRadius: 0,
                                   endCenter: .zero, endRadius: CGFloat(radius),
                                   options: [])
        context.restoreGState()
    }
}
