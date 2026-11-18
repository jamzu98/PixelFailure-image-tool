import CoreImage
import SwiftUI

/// Deterministic nearest-boundary inpainting used by Content-Aware Fill.
/// It runs entirely on the layer buffer, so it is undoable and works offline.
nonisolated enum ContentAwareInpainting {
    static func fill(_ image: CGImage, mask: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard width == mask.width, height == mask.height,
              let source = rgbaContext(width: width, height: height),
              let maskContext = rgbaContext(width: width, height: height),
              let output = rgbaContext(width: width, height: height) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        source.context.draw(image, in: rect)
        maskContext.context.draw(mask, in: rect)
        memcpy(output.bytes, source.bytes, source.byteCount)

        let src = source.bytes.assumingMemoryBound(to: UInt8.self)
        let maskBytes = maskContext.bytes.assumingMemoryBound(to: UInt8.self)
        let dst = output.bytes.assumingMemoryBound(to: UInt8.self)
        var selected = [Bool](repeating: false, count: width * height)
        var distance = [Int](repeating: -1, count: width * height)
        var queue: [Int] = []
        queue.reserveCapacity(width * height)
        for index in selected.indices {
            let pixel = index * 4
            selected[index] = maskBytes[pixel] >= 128
            if !selected[index] {
                distance[index] = 0
                queue.append(index)
            }
        }
        guard !queue.isEmpty, selected.contains(true) else { return image }

        var head = 0
        while head < queue.count {
            let index = queue[head]
            head += 1
            let x = index % width, y = index / width
            for neighbor in [index - 1, index + 1, index - width, index + width] {
                guard neighbor >= 0, neighbor < width * height else { continue }
                let nx = neighbor % width, ny = neighbor / width
                guard abs(nx - x) + abs(ny - y) == 1, distance[neighbor] < 0 else { continue }
                distance[neighbor] = distance[index] + 1
                let from = index * 4, to = neighbor * 4
                dst[to] = dst[from]
                dst[to + 1] = dst[from + 1]
                dst[to + 2] = dst[from + 2]
                dst[to + 3] = src[to + 3]
                queue.append(neighbor)
            }
        }
        return output.context.makeImage()
    }

    private static func rgbaContext(width: Int, height: Int)
        -> (context: CGContext, bytes: UnsafeMutableRawPointer, byteCount: Int)? {
        let bytesPerRow = width * 4
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        return (context, data, bytesPerRow * height)
    }
}

/// High-quality, deterministic 2× fallback for machines without a bundled
/// super-resolution Core ML model. Kept behind one operation so a model can
/// replace it without changing the document or UI contract.
nonisolated enum ImageUpscaler {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func upscale2x(_ image: CGImage) -> CGImage? {
        let source = CIImage(cgImage: image)
        let scaled = source.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: 2.0,
            kCIInputAspectRatioKey: 1.0,
        ]).applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.25])
        return context.createCGImage(scaled, from: scaled.extent)
    }
}
