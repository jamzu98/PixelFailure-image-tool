import CoreGraphics
import CoreImage
import Foundation
import Metal
import Synchronization

/// A generator that paints pixels on the GPU instead of emitting vector
/// primitives. Rendered at the viewport tier's resolution (or full canvas
/// size on export), so it scales without losing detail; SVG export embeds
/// the result as an image.
nonisolated protocol RasterGenerator: PatternGenerator {
    func render(params: ParamValues, seed: UInt64, pixelSize: CGSize, palette: Palette,
                colorSettings: ColorSettings) -> CGImage?
}

nonisolated extension RasterGenerator {
    func generate(params: ParamValues, seed: UInt64, context: GeneratorContext) -> [VectorPrimitive] { [] }
}

extension GeneratorType {
    nonisolated var isRaster: Bool { generator is any RasterGenerator }
}

// MARK: - Noise Field

nonisolated struct NoiseFieldRasterGenerator: RasterGenerator {
    var displayName: String { "Noise Field" }

    var specs: [ParamSpec] {
        [
            .choice("kind", "Noise", options: ["Gradient", "Worley", "Ridged"], initial: 0),
            .slider("scale", "Scale", min: 0.5, max: 14, initial: 3),
            .intSlider("octaves", "Detail", min: 1, max: 8, initial: 5),
            .slider("warp", "Warp", min: 0, max: 4, initial: 1.4),
            .slider("contrast", "Contrast", min: 0.5, max: 3, initial: 1.25),
            .intSlider("bands", "Bands", min: 0, max: 24, initial: 0),
            .slider("driftX", "Drift X", min: 0, max: 10, initial: 0),
            .slider("driftY", "Drift Y", min: 0, max: 10, initial: 0),
        ]
    }

    func render(params: ParamValues, seed: UInt64, pixelSize: CGSize, palette: Palette,
                colorSettings: ColorSettings) -> CGImage? {
        // Kernel slots after width/height: scale, octaves, warp, contrast,
        // kind, then palette count (appended), bands, drift.
        let scale = Float(params.double("scale", 3))
        return renderKernelWithTail("pf_noise_field",
                                    head: [scale, Float(params.int("octaves", 5)),
                                           Float(params.double("warp", 1.4)),
                                           Float(params.double("contrast", 1.25)),
                                           Float(params.int("kind", 0))],
                                    tail: [Float(params.int("bands", 0)),
                                           Float(params.double("driftX", 0)), Float(params.double("driftY", 0))],
                                    palette: palette, seed: seed, pixelSize: pixelSize,
                                    colorSettings: colorSettings)
    }
}

// MARK: - Voronoi

nonisolated struct VoronoiRasterGenerator: RasterGenerator {
    var displayName: String { "Voronoi" }

    var specs: [ParamSpec] {
        [
            .slider("cells", "Cells", min: 2, max: 120, initial: 14),
            .slider("edge", "Edge Width", min: 0, max: 0.3, initial: 0.05),
            .slider("jitter", "Jitter", min: 0, max: 1, initial: 0.9),
            .choice("style", "Style", options: ["Cells", "Edges", "Cells + Edges", "Distance"], initial: 2),
            .intSlider("bands", "Bands", min: 0, max: 24, initial: 0),
        ]
    }

    func render(params: ParamValues, seed: UInt64, pixelSize: CGSize, palette: Palette,
                colorSettings: ColorSettings) -> CGImage? {
        renderKernelWithTail("pf_voronoi",
                             head: [Float(params.double("cells", 14)), Float(params.double("edge", 0.05)),
                                    Float(params.double("jitter", 0.9)), Float(params.int("style", 2))],
                             tail: [Float(params.int("bands", 0))],
                             palette: palette, seed: seed, pixelSize: pixelSize, colorSettings: colorSettings)
    }
}

// MARK: - Plasma

nonisolated struct PlasmaRasterGenerator: RasterGenerator {
    var displayName: String { "Plasma" }

    var specs: [ParamSpec] {
        [
            .slider("scale", "Scale", min: 0.5, max: 10, initial: 2.5),
            .intSlider("waves", "Waves", min: 2, max: 9, initial: 5),
            .slider("phase", "Phase", min: 0, max: 6.283, initial: 0),
            .slider("contrast", "Contrast", min: 0.5, max: 3, initial: 1.2),
            .intSlider("bands", "Bands", min: 0, max: 24, initial: 0),
        ]
    }

    func render(params: ParamValues, seed: UInt64, pixelSize: CGSize, palette: Palette,
                colorSettings: ColorSettings) -> CGImage? {
        renderKernelWithTail("pf_plasma",
                             head: [Float(params.double("scale", 2.5)), Float(params.int("waves", 5)),
                                    Float(params.double("phase", 0)), Float(params.double("contrast", 1.2))],
                             tail: [Float(params.int("bands", 0))],
                             palette: palette, seed: seed, pixelSize: pixelSize, colorSettings: colorSettings)
    }
}

// MARK: - Reaction–diffusion

nonisolated struct ReactionDiffusionRasterGenerator: RasterGenerator {
    var displayName: String { "Reaction–Diffusion" }

    /// Gray–Scott feed/kill pairs with recognizably different textures.
    static let presets: [(name: String, feed: Float, kill: Float)] = [
        ("Coral", 0.0545, 0.062), ("Mitosis", 0.0367, 0.0649), ("Spots", 0.035, 0.065),
        ("Maze", 0.029, 0.057), ("Worms", 0.078, 0.061), ("Holes", 0.039, 0.058),
    ]

    var specs: [ParamSpec] {
        [
            .choice("preset", "Pattern", options: Self.presets.map(\.name), initial: 0),
            .intSlider("iterations", "Iterations", min: 200, max: 12000, initial: 5000, randomizable: false),
            .choice("resolution", "Simulation Size", options: ["512", "768", "1024"], initial: 0,
                    randomizable: false),
            .intSlider("spots", "Seeds", min: 1, max: 2000, initial: 500),
            .slider("spotSize", "Seed Size", min: 2, max: 40, initial: 5),
            .slider("feedOffset", "Feed", min: -0.01, max: 0.01, initial: 0),
            .slider("killOffset", "Kill", min: -0.005, max: 0.005, initial: 0),
            .slider("contrast", "Contrast", min: 0.5, max: 3, initial: 1.3),
            .intSlider("bands", "Bands", min: 0, max: 24, initial: 0),
        ]
    }

    /// The simulation doesn't depend on output size, so finished fields are
    /// cached by settings and reused for every viewport tier.
    private static let fields = Mutex<[Int: CGImage]>([:])

    func render(params: ParamValues, seed: UInt64, pixelSize: CGSize, palette: Palette,
                colorSettings: ColorSettings) -> CGImage? {
        var hasher = Hasher()
        hasher.combine(params); hasher.combine(seed); hasher.combine(palette); hasher.combine(colorSettings)
        let key = hasher.finalize()
        let field: CGImage
        if let cached = Self.fields.withLock({ $0[key] }) {
            field = cached
        } else {
            guard let simulated = simulate(params: params, seed: seed, palette: palette,
                                           colorSettings: colorSettings) else { return nil }
            Self.fields.withLock { cache in
                if cache.count > 6 { cache.removeAll() }
                cache[key] = simulated
            }
            field = simulated
        }
        // Lanczos up/down to the requested size.
        let ci = CIImage(cgImage: field)
        let sx = pixelSize.width / CGFloat(field.width), sy = pixelSize.height / CGFloat(field.height)
        let scaled = ci.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy,
        ]).cropped(to: CGRect(origin: .zero, size: pixelSize))
        let format: CIFormat = colorSettings.bitDepth == .sixteen ? .RGBA16 : .RGBA8
        return CoreImageContext.shared.createCGImage(scaled, from: CGRect(origin: .zero, size: pixelSize),
                                                     format: format,
                                                     colorSpace: colorSettings.workingSpace.cgColorSpace)
    }

    private func simulate(params: ParamValues, seed: UInt64, palette: Palette,
                          colorSettings: ColorSettings) -> CGImage? {
        guard let metal = MetalCompute.shared else { return nil }
        let side = [512, 768, 1024][min(max(params.int("resolution", 0), 0), 2)]
        guard let a = metal.makeTexture(width: side, height: side, format: .rgba32Float),
              let b = metal.makeTexture(width: side, height: side, format: .rgba32Float),
              let output = metal.makeTexture(width: side, height: side),
              let buffer = metal.queue.makeCommandBuffer(),
              let encoder = buffer.makeComputeCommandEncoder() else { return nil }
        let preset = Self.presets[min(max(params.int("preset", 0), 0), Self.presets.count - 1)]
        let feed = preset.feed + Float(params.double("feedOffset", 0))
        let kill = preset.kill + Float(params.double("killOffset", 0))
        let s = Float(side)
        let seed32 = UInt32(truncatingIfNeeded: seed ^ (seed >> 32))
        var ok = metal.dispatch("pf_rd_init", on: encoder, textures: [a],
                                params: [s, s, Float(params.int("spots", 500)), Float(params.double("spotSize", 5))],
                                seed: seed32, width: side, height: side)
        let stepParams: [Float] = [s, s, feed, kill, 0.2097, 0.105]
        var source = a, target = b
        for _ in 0..<max(1, params.int("iterations", 5000)) where ok {
            ok = metal.dispatch("pf_rd_step", on: encoder, textures: [source, target], params: stepParams,
                                width: side, height: side)
            swap(&source, &target)
        }
        let colors = MetalCompute.palette(palette)
        if ok {
            ok = metal.dispatch("pf_rd_color", on: encoder, textures: [source, output],
                                params: [s, s, Float(params.double("contrast", 1.3)), Float(colors.count),
                                         Float(params.int("bands", 0))],
                                palette: colors, width: side, height: side)
        }
        encoder.endEncoding()
        guard ok else { return nil }
        buffer.commit()
        buffer.waitUntilCompleted()
        return metal.image(from: output, colorSettings: colorSettings)
    }
}

nonisolated extension RasterGenerator {
    /// Kernel settings are laid out as width, height, `head`, palette count,
    /// `tail` (see the comment above each kernel in Generators.metal).
    func renderKernelWithTail(_ name: String, head: [Float], tail: [Float], palette: Palette, seed: UInt64,
                              pixelSize: CGSize, colorSettings: ColorSettings) -> CGImage? {
        guard let metal = MetalCompute.shared else { return nil }
        let width = max(1, Int(pixelSize.width.rounded())), height = max(1, Int(pixelSize.height.rounded()))
        guard let texture = metal.makeTexture(width: width, height: height),
              let buffer = metal.queue.makeCommandBuffer(),
              let encoder = buffer.makeComputeCommandEncoder() else { return nil }
        let colors = MetalCompute.palette(palette)
        let ok = metal.dispatch(name, on: encoder, textures: [texture],
                                params: [Float(width), Float(height)] + head + [Float(colors.count)] + tail,
                                palette: colors, seed: UInt32(truncatingIfNeeded: seed ^ (seed >> 32)),
                                width: width, height: height)
        encoder.endEncoding()
        guard ok else { return nil }
        buffer.commit()
        buffer.waitUntilCompleted()
        return metal.image(from: texture, colorSettings: colorSettings)
    }
}
