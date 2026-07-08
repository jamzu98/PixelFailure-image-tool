import CoreGraphics
import Foundation

/// A small CPU-side pixel buffer for sampling an image's colors —
/// feeds image-driven generators and palette extraction.
nonisolated struct ImageSampler: Sendable {
    let width: Int
    let height: Int
    /// RGBA, 8 bits per channel, premultiplied alpha.
    let pixels: [UInt8]

    init?(cgImage: CGImage, maxDimension: Int = 256) {
        let scale = Double(maxDimension) / Double(max(cgImage.width, cgImage.height))
        let w = max(1, Int((Double(cgImage.width) * min(scale, 1)).rounded()))
        let h = max(1, Int((Double(cgImage.height) * min(scale, 1)).rounded()))

        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: w, height: h,
                                      bitsPerComponent: 8,
                                      bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        width = w
        height = h
        pixels = buffer
    }

    /// Sample with unit coordinates, (0,0) = top-left.
    func color(atUnitX x: Double, y: Double) -> RGBAColor {
        let px = min(max(Int(x * Double(width)), 0), width - 1)
        // Bitmap memory row 0 is the visual top of the drawn image, matching
        // this API's top-left unit-coordinate convention directly.
        let py = min(max(Int(y * Double(height)), 0), height - 1)
        let i = (py * width + px) * 4
        let a = Double(pixels[i + 3]) / 255
        guard a > 0.001 else { return .clear }
        return RGBAColor(r: Double(pixels[i]) / 255 / a,
                         g: Double(pixels[i + 1]) / 255 / a,
                         b: Double(pixels[i + 2]) / 255 / a,
                         a: a)
    }

    func luminance(atUnitX x: Double, y: Double) -> Double {
        color(atUnitX: x, y: y).luminance
    }

    /// All pixels as RGBAColor (for k-means palette extraction).
    var allColors: [RGBAColor] {
        var out: [RGBAColor] = []
        out.reserveCapacity(width * height)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            guard a > 0.5 else { continue }
            out.append(RGBAColor(r: Double(pixels[i]) / 255 / a,
                                 g: Double(pixels[i + 1]) / 255 / a,
                                 b: Double(pixels[i + 2]) / 255 / a,
                                 a: 1))
        }
        return out
    }
}
