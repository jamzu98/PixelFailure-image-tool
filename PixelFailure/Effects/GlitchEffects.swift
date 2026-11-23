import CoreImage
import Foundation
import Metal

/// Runs one of the glitch compute kernels inside the Core Image graph, so
/// glitches tile, cache and compose like any built-in filter. Kernels see
/// the whole image (they displace pixels from anywhere) and write one tile.
nonisolated final class GlitchKernel: CIImageProcessorKernel {
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
    override class var outputFormat: CIFormat { .RGBAh }

    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        (arguments?["extent"] as? CGRect) ?? outputRect
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let source = input.metalTexture,
              let target = output.metalTexture, let buffer = output.metalCommandBuffer,
              let metal = MetalCompute.shared,
              let name = arguments?["kernel"] as? String,
              let extent = arguments?["extent"] as? CGRect,
              let settings = arguments?["params"] as? [Float],
              let encoder = buffer.makeComputeCommandEncoder() else {
            throw CocoaError(.featureUnsupported)
        }
        let header: [Float] = [Float(input.region.minX), Float(input.region.minY),
                               Float(source.width), Float(source.height),
                               Float(output.region.minX), Float(output.region.minY),
                               Float(extent.width), Float(extent.height)]
        _ = metal.dispatch(name, on: encoder, textures: [source, target], params: header + settings,
                           palette: arguments?["palette"] as? [SIMD4<Float>],
                           seed: arguments?["seed"] as? UInt32,
                           width: target.width, height: target.height)
        encoder.endEncoding()
    }

    static func apply(_ name: String, to image: CIImage, extent: CGRect, params: [Float],
                      palette: [SIMD4<Float>]? = nil, seed: UInt32 = 0) -> CIImage {
        guard MetalCompute.shared != nil else { return image }
        var arguments: [String: Any] = ["kernel": name, "extent": extent, "params": params, "seed": seed]
        if let palette { arguments["palette"] = palette }
        return (try? apply(withExtent: extent, inputs: [image], arguments: arguments)) ?? image
    }
}

/// The glitch effects. GPU ones go through `GlitchKernel`; pixel sorting and
/// error-diffusion dithering are inherently sequential and run on a float
/// bitmap on the CPU.
nonisolated enum GlitchEffects {
    static func datamosh(_ image: CIImage, extent: CGRect, minDim: Double, params p: ParamValues) -> CIImage {
        GlitchKernel.apply("pf_datamosh", to: image, extent: extent, params: [
            Float(max(2, p.double("blockSize", 0.03) * minDim)),
            Float(p.double("amount", 0.35)),
            Float(p.double("shift", 0.08) * Double(extent.width)),
            Float(p.double("smear", 0.4)),
            Float(p.double("bleed", 0.3) * p.double("blockSize", 0.03) * minDim * 0.5),
        ], seed: seed(p))
    }

    static func noiseShift(_ image: CIImage, extent: CGRect, params p: ParamValues) -> CIImage {
        GlitchKernel.apply("pf_noise_shift", to: image, extent: extent, params: [
            Float(p.double("amount", 0.03) * Double(extent.width)),
            Float(p.double("frequency", 6)),
            Float(p.double("jitter", 0.2)),
            Float(p.int("channels", 0)),
        ], seed: seed(p))
    }

    static func dither(_ image: CIImage, extent: CGRect, minDim: Double, palette: Palette,
                       params p: ParamValues) -> CIImage {
        let colors = linearColors(for: p.int("colors", 0), palette: palette)
        let cell = max(1, p.double("cellSize", 0.002) * minDim)
        let method = p.int("method", 0)
        if method == 3 {
            return floydSteinberg(image, extent: extent, cell: cell, colors: colors,
                                  spread: p.double("spread", 0.8))
        }
        return GlitchKernel.apply("pf_dither", to: image, extent: extent, params: [
            Float(method), Float(cell), Float(p.double("spread", 0.8)), Float(colors.count),
        ], palette: colors)
    }

    private static func seed(_ p: ParamValues) -> UInt32 {
        UInt32(truncatingIfNeeded: 0x9E37_79B9 &+ UInt64(p.int("variant", 0)) &* 7919)
    }

    /// The palette to quantize to, converted to linear light to match the
    /// Core Image working space.
    static func linearColors(for mode: Int, palette: Palette) -> [SIMD4<Float>] {
        let source: [RGBAColor] = switch mode {
        case 1: [.black, .white]
        case 2: [0.0, 0.33, 0.66, 1.0].map { RGBAColor(r: $0, g: $0, b: $0) }
        default: palette.colors.isEmpty ? [.black, .white] : Array(palette.colors.prefix(16))
        }
        func linear(_ v: Double) -> Float {
            Float(v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4))
        }
        return source.map { SIMD4<Float>(linear($0.r), linear($0.g), linear($0.b), 1) }
    }

    // MARK: CPU effects

    /// Linear RGBA pixels in half floats, read and written as Float.
    struct HalfPixels {
        let base: UnsafeMutablePointer<Float16>
        subscript(index: Int) -> Float {
            get { Float(base[index]) }
            nonmutating set { base[index] = Float16(newValue) }
        }
    }

    /// Renders the image to linear half-float RGBA, lets `body` edit it in
    /// place, and wraps the same buffer back into the graph. Half floats and
    /// a single uncopied buffer keep a 6000×4000 photo near 190 MB.
    private static func withPixels(_ image: CIImage, extent: CGRect,
                                   _ body: (HalfPixels, Int, Int) -> Void) -> CIImage {
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return image }
        let rowBytes = width * 4 * MemoryLayout<Float16>.size
        let byteCount = rowBytes * height
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        CoreImageContext.shared.render(image, toBitmap: raw, rowBytes: rowBytes,
                                       bounds: extent, format: .RGBAh, colorSpace: space)
        body(HalfPixels(base: raw.bindMemory(to: Float16.self, capacity: width * height * 4)), width, height)
        let data = Data(bytesNoCopy: raw, count: byteCount, deallocator: .custom { pointer, _ in pointer.deallocate() })
        return CIImage(bitmapData: data, bytesPerRow: rowBytes, size: extent.size, format: .RGBAh,
                       colorSpace: space)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    /// Sorts runs of pixels whose key lies between the thresholds, row by
    /// row (or column by column).
    static func pixelSort(_ image: CIImage, extent: CGRect, params p: ParamValues) -> CIImage {
        let vertical = p.int("direction", 0) == 1
        let low = Float(p.double("low", 0.25)), high = Float(p.double("high", 0.8))
        let mode = p.int("sortBy", 0)
        let maxSpanFraction = p.double("maxSpan", 0.3)
        let reverse = p.bool("reverse", false)
        return withPixels(image, extent: extent) { pixels, width, height in
            func key(_ i: Int) -> Float {
                let r = pixels[i], g = pixels[i + 1], b = pixels[i + 2]
                switch mode {
                case 1: // hue
                    let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
                    guard d > 1e-6 else { return 0 }
                    var h: Float = mx == r ? (g - b) / d : (mx == g ? 2 + (b - r) / d : 4 + (r - g) / d)
                    h /= 6; if h < 0 { h += 1 }
                    return h
                case 2: // saturation
                    let mx = max(r, g, b), mn = min(r, g, b)
                    return mx > 1e-6 ? (mx - mn) / mx : 0
                default: // perceived brightness in linear light
                    return min(max(0.2126 * r + 0.7152 * g + 0.0722 * b, 0), 1).squareRoot()
                }
            }
            let lines = vertical ? width : height
            let length = vertical ? height : width
            let maxSpan = max(2, Int(Double(length) * maxSpanFraction))
            var span: [(Float, SIMD4<Float>)] = []
            for line in 0..<lines {
                func index(_ k: Int) -> Int { (vertical ? k * width + line : line * width + k) * 4 }
                var k = 0
                while k < length {
                    let start = k
                    while k < length, k - start < maxSpan, (low...high).contains(key(index(k))) { k += 1 }
                    if k - start > 1 {
                        span.removeAll(keepingCapacity: true)
                        for m in start..<k {
                            let i = index(m)
                            span.append((key(i), SIMD4(pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])))
                        }
                        span.sort { reverse ? $0.0 > $1.0 : $0.0 < $1.0 }
                        for (offset, entry) in span.enumerated() {
                            let i = index(start + offset)
                            pixels[i] = entry.1.x; pixels[i + 1] = entry.1.y
                            pixels[i + 2] = entry.1.z; pixels[i + 3] = entry.1.w
                        }
                    }
                    if k == start { k += 1 }
                }
            }
        }
    }

    /// Error-diffusion dithering on a grid of `cell`-sized blocks.
    static func floydSteinberg(_ image: CIImage, extent: CGRect, cell: Double, colors: [SIMD4<Float>],
                               spread: Double) -> CIImage {
        withPixels(image, extent: extent) { pixels, width, height in
            let c = max(1, Int(cell.rounded()))
            let gw = (width + c - 1) / c, gh = (height + c - 1) / c
            var grid = [SIMD3<Float>](repeating: .zero, count: gw * gh)
            for gy in 0..<gh {
                for gx in 0..<gw {
                    let i = (min(height - 1, gy * c + c / 2) * width + min(width - 1, gx * c + c / 2)) * 4
                    grid[gy * gw + gx] = SIMD3(pixels[i], pixels[i + 1], pixels[i + 2])
                }
            }
            let strength = Float(spread)
            for gy in 0..<gh {
                for gx in 0..<gw {
                    let old = grid[gy * gw + gx]
                    var best = colors[0], bestD = Float.greatestFiniteMagnitude
                    for color in colors {
                        let d = old - SIMD3(color.x, color.y, color.z)
                        let dist = (d * d).sum()
                        if dist < bestD { bestD = dist; best = color }
                    }
                    let chosen = SIMD3(best.x, best.y, best.z)
                    grid[gy * gw + gx] = chosen
                    let error = (old - chosen) * strength
                    if gx + 1 < gw { grid[gy * gw + gx + 1] += error * (7 / 16) }
                    if gy + 1 < gh {
                        if gx > 0 { grid[(gy + 1) * gw + gx - 1] += error * (3 / 16) }
                        grid[(gy + 1) * gw + gx] += error * (5 / 16)
                        if gx + 1 < gw { grid[(gy + 1) * gw + gx + 1] += error * (1 / 16) }
                    }
                }
            }
            for y in 0..<height {
                for x in 0..<width {
                    let v = grid[(y / c) * gw + x / c]
                    let i = (y * width + x) * 4
                    pixels[i] = v.x; pixels[i + 1] = v.y; pixels[i + 2] = v.z
                }
            }
        }
    }
}
