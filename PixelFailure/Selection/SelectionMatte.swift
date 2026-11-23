import CoreGraphics
import CoreImage
import SwiftUI

/// Soft selection coverage on a grid spanning the whole canvas. Row 0 is the
/// canvas top (y-down, like canvas coordinates); 255 = fully selected.
/// Vision mattes (subject, people, iterative segmentation) keep their soft
/// hair/fur edges through this instead of being thresholded into a path.
nonisolated struct SelectionMatte: @unchecked Sendable {
    let width: Int
    let height: Int
    let canvasSize: CGSize
    let pixels: [UInt8]
    /// DeviceGray 8-bit image of `pixels` (top row = canvas top).
    let image: CGImage

    static let maxLongSide = 4096

    init?(width: Int, height: Int, canvasSize: CGSize, pixels: [UInt8]) {
        guard width > 0, height > 0, pixels.count == width * height,
              canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else { return nil }
        self.width = width
        self.height = height
        self.canvasSize = canvasSize
        self.pixels = pixels
        self.image = image
    }

    /// Any grayscale-ish image covering the full canvas (e.g. a Vision mask),
    /// read as luminance. Downsampled when its long side exceeds the cap.
    init?(grayImage: CGImage, canvasSize: CGSize) {
        let (w, h) = Self.cappedSize(width: grayImage.width, height: grayImage.height)
        guard let pixels = Self.grayPixels(of: grayImage, width: w, height: h) else { return nil }
        self.init(width: w, height: h, canvasSize: canvasSize, pixels: pixels)
    }

    /// Hard (anti-aliased) coverage of an even-odd path on a `width`×`height` grid.
    static func rasterize(_ path: Path, canvasSize: CGSize, width: Int, height: Int) -> SelectionMatte? {
        guard width > 0, height > 0, canvasSize.width > 0, canvasSize.height > 0,
              let ctx = grayContext(width: width, height: height) else { return nil }
        // Canvas y-down → context y-up so memory row 0 = canvas top.
        let sx = CGFloat(width) / canvasSize.width, sy = CGFloat(height) / canvasSize.height
        ctx.concatenate(CGAffineTransform(a: sx, b: 0, c: 0, d: -sy, tx: 0, ty: CGFloat(height)))
        ctx.addPath(path.cgPath)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fillPath(using: .evenOdd)
        return fromContext(ctx, width: width, height: height, canvasSize: canvasSize)
    }

    /// Default grid for a canvas: the canvas pixel size, capped.
    static func gridSize(for canvasSize: CGSize) -> (Int, Int) {
        cappedSize(width: Int(canvasSize.width.rounded(.up)), height: Int(canvasSize.height.rounded(.up)))
    }

    func resampled(width: Int, height: Int) -> SelectionMatte? {
        if width == self.width, height == self.height { return self }
        guard let pixels = Self.grayPixels(of: image, width: width, height: height) else { return nil }
        return SelectionMatte(width: width, height: height, canvasSize: canvasSize, pixels: pixels)
    }

    enum Op { case add, subtract, intersect }

    /// Per-pixel boolean on soft coverage: add = max, subtract = a·(1−b),
    /// intersect = min. Runs on the larger of the two grids.
    func combined(with other: SelectionMatte, _ op: Op) -> SelectionMatte? {
        let w = max(width, other.width), h = max(height, other.height)
        guard let a = resampled(width: w, height: h),
              let b = other.resampled(width: w, height: h) else { return nil }
        var out = [UInt8](repeating: 0, count: w * h)
        a.pixels.withUnsafeBufferPointer { pa in
            b.pixels.withUnsafeBufferPointer { pb in
                for i in 0..<(w * h) {
                    let x = pa[i], y = pb[i]
                    switch op {
                    case .add: out[i] = max(x, y)
                    case .intersect: out[i] = min(x, y)
                    case .subtract: out[i] = UInt8((Int(x) * (255 - Int(y)) + 127) / 255)
                    }
                }
            }
        }
        return SelectionMatte(width: w, height: h, canvasSize: canvasSize, pixels: out)
    }

    func inverted() -> SelectionMatte? {
        SelectionMatte(width: width, height: height, canvasSize: canvasSize,
                       pixels: pixels.map { 255 - $0 })
    }

    /// Grows (positive) or shrinks (negative) by `canvasPixels`.
    func morphed(by canvasPixels: Double) -> SelectionMatte? {
        let radius = abs(canvasPixels) * Double(width) / Double(canvasSize.width)
        guard radius >= 0.5 else { return self }
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let filter = canvasPixels > 0 ? "CIMorphologyMaximum" : "CIMorphologyMinimum"
        let processed = CIImage(cgImage: image)
            .clampedToExtent()
            .applyingFilter(filter, parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)
        guard let output = Self.ciContext.createCGImage(processed, from: extent,
                                                        format: .L8,
                                                        colorSpace: CGColorSpaceCreateDeviceGray())
        else { return nil }
        return SelectionMatte(grayImage: output, canvasSize: canvasSize)?
            .resampled(width: width, height: height)
    }

    var isEmpty: Bool { !pixels.contains { $0 >= 128 } }

    /// Coverage (0–255) at a canvas point; 0 outside the canvas.
    func coverage(at canvasPoint: CGPoint) -> UInt8 {
        let x = Int(canvasPoint.x / canvasSize.width * CGFloat(width))
        let y = Int(canvasPoint.y / canvasSize.height * CGFloat(height))
        guard (0..<width).contains(x), (0..<height).contains(y) else { return 0 }
        return pixels[y * width + x]
    }

    /// The 50% contour in canvas space, traced on a grid of at most
    /// `maxTraceSide` so marching ants stay light.
    func contourPath(maxTraceSide: Int = 1024) -> Path? {
        let scale = min(1, Double(maxTraceSide) / Double(max(width, height)))
        let tw = max(1, Int((Double(width) * scale).rounded()))
        let th = max(1, Int((Double(height) * scale).rounded()))
        guard let source = scale < 1 ? resampled(width: tw, height: th) : self else { return nil }
        let grid = source.pixels.map { $0 >= 128 }
        return ContourTracer.trace(grid: grid, width: tw, height: th,
                                   scale: CGPoint(x: canvasSize.width / CGFloat(tw),
                                                  y: canvasSize.height / CGFloat(th)))
    }

    /// RGBA image of the matte tinted with `color` (alpha = coverage × alpha),
    /// top row = canvas top. For on-canvas previews.
    func tinted(_ color: CGColor, alpha: Double) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.clip(to: rect, mask: image)
        ctx.setFillColor(color)
        ctx.setAlpha(alpha)
        ctx.fill(rect)
        return ctx.makeImage()
    }

    // MARK: - Drawing through a canvas→buffer transform

    /// Draws the coverage (white on transparent) into `ctx`, placed exactly
    /// where a canvas path drawn through `transform` would land.
    func draw(into ctx: CGContext, transform: CGAffineTransform) {
        ctx.saveGState()
        applyCanvasPlacement(ctx, transform: transform)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: canvasSize))
        ctx.restoreGState()
    }

    /// Clips `ctx` to the coverage. Call inside save/restore.
    func clip(_ ctx: CGContext, transform: CGAffineTransform) {
        ctx.interpolationQuality = .high
        applyCanvasPlacement(ctx, transform: transform)
        ctx.clip(to: CGRect(origin: .zero, size: canvasSize), mask: image)
        // Undo the placement CTM so subsequent fills use buffer space; the
        // clip itself stays.
        let placement = Self.placement(canvasSize: canvasSize).concatenating(transform)
        if placement.isInvertible {
            ctx.concatenate(placement.inverted())
        }
    }

    private func applyCanvasPlacement(_ ctx: CGContext, transform: CGAffineTransform) {
        ctx.concatenate(Self.placement(canvasSize: canvasSize).concatenating(transform))
    }

    /// CGContext.draw puts an image's top row at the rect's max y; flipping
    /// canvas y first puts it at canvas y = 0.
    private static func placement(canvasSize: CGSize) -> CGAffineTransform {
        CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: canvasSize.height)
    }

    // MARK: - Helpers

    private static var ciContext: CIContext { CoreImageContext.shared }

    private static func cappedSize(width: Int, height: Int) -> (Int, Int) {
        let longSide = max(width, height, 1)
        guard longSide > maxLongSide else { return (max(1, width), max(1, height)) }
        let scale = Double(maxLongSide) / Double(longSide)
        return (max(1, Int((Double(width) * scale).rounded())),
                max(1, Int((Double(height) * scale).rounded())))
    }

    private static func grayContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
    }

    private static func grayPixels(of image: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard let ctx = grayContext(width: width, height: height) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: width * height))
    }

    private static func fromContext(_ ctx: CGContext, width: Int, height: Int,
                                    canvasSize: CGSize) -> SelectionMatte? {
        guard let data = ctx.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let pixels = Array(UnsafeBufferPointer(start: bytes, count: width * height))
        return SelectionMatte(width: width, height: height, canvasSize: canvasSize, pixels: pixels)
    }
}

/// How a new region combines with the existing selection.
nonisolated enum SelectionCombineMode: String, CaseIterable, Identifiable, Sendable {
    case replace, add, subtract, intersect

    var id: String { rawValue }

    init(modifiers: NSEvent.ModifierFlags) {
        let shift = modifiers.contains(.shift), option = modifiers.contains(.option)
        self = shift && option ? .intersect : shift ? .add : option ? .subtract : .replace
    }

    var systemImage: String {
        switch self {
        case .replace: "square"
        case .add: "plus.square"
        case .subtract: "minus.square"
        case .intersect: "square.on.square.intersection.dashed"
        }
    }

    var displayName: String {
        switch self {
        case .replace: "New Selection"
        case .add: "Add to Selection"
        case .subtract: "Subtract from Selection"
        case .intersect: "Intersect with Selection"
        }
    }
}
