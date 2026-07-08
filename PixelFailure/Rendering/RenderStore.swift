import CoreGraphics
import Foundation
import ImageIO

/// A fully resolved, drawable layer. Both the live viewport (GraphicsContext)
/// and the exporters (CGContext / SVG) consume arrays of these.
struct RenderItem: Identifiable {
    enum Content {
        case primitives([VectorPrimitive])
        case raster(CGImage)
    }

    let id: UUID
    var opacity: Double
    var blendMode: LayerBlendMode
    /// Local (0..naturalSize) → canvas coordinates.
    var transform: CGAffineTransform
    var naturalSize: CGSize
    var content: Content
}

enum RenderQuality {
    /// Rasters capped to a working resolution for interactive speed.
    case preview
    /// Native resolution — used at export time.
    case full

    var maxRasterDimension: Int? {
        switch self {
        case .preview: 1600
        case .full: nil
        }
    }
}

/// Per-document render cache: decoded images, resolved effect chains,
/// generated primitives. Owned by the editor window; all main-actor.
final class RenderStore {
    private unowned let document: PixelDocument

    private var decodedImages: [String: CGImage] = [:]
    private var previewImages: [UUID: (hash: Int, image: CGImage)] = [:]
    private var primitives: [UUID: (hash: Int, primitives: [VectorPrimitive], naturalSize: CGSize)] = [:]
    private var samplers: [UUID: (hash: Int, sampler: ImageSampler)] = [:]

    init(document: PixelDocument) {
        self.document = document
    }

    // MARK: - Public

    func renderItems(model: ProjectModel, quality: RenderQuality) -> [RenderItem] {
        model.layers.compactMap { layer in
            guard layer.isVisible else { return nil }
            return renderItem(for: layer, model: model, quality: quality)
        }
    }

    func naturalSize(for layer: Layer, model: ProjectModel) -> CGSize {
        switch layer.kind {
        case .pattern: model.canvasSize
        case .image(let config): config.croppedPixelSize
        case .text: primitivesResult(for: layer, model: model).naturalSize
        }
    }

    func originalImage(key: String) -> CGImage? {
        if let cached = decodedImages[key] { return cached }
        guard let data = document.imageData(for: key),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCache: true,
              ] as CFDictionary) else { return nil }
        decodedImages[key] = image
        return image
    }

    /// Drops content caches; decoded originals stay (they never change per key).
    func invalidateResolved() {
        previewImages.removeAll()
        primitives.removeAll()
        samplers.removeAll()
    }

    // MARK: - Layer resolution

    private func renderItem(for layer: Layer, model: ProjectModel, quality: RenderQuality) -> RenderItem? {
        switch layer.kind {
        case .pattern, .text:
            let result = primitivesResult(for: layer, model: model)
            return RenderItem(id: layer.id,
                              opacity: layer.opacity,
                              blendMode: layer.blendMode,
                              transform: layer.transform.affine(naturalSize: result.naturalSize),
                              naturalSize: result.naturalSize,
                              content: .primitives(result.primitives))
        case .image(let config):
            guard let image = resolvedImage(for: layer, config: config, model: model, quality: quality) else { return nil }
            let naturalSize = config.croppedPixelSize
            return RenderItem(id: layer.id,
                              opacity: layer.opacity,
                              blendMode: layer.blendMode,
                              transform: layer.transform.affine(naturalSize: naturalSize),
                              naturalSize: naturalSize,
                              content: .raster(image))
        }
    }

    private func primitivesResult(for layer: Layer, model: ProjectModel) -> (primitives: [VectorPrimitive], naturalSize: CGSize) {
        var hasher = Hasher()
        hasher.combine(layer.kind)
        hasher.combine(model.palette)
        hasher.combine(model.canvasSize.width)
        hasher.combine(model.canvasSize.height)

        switch layer.kind {
        case .pattern(let config):
            var sampler: ImageSampler?
            if config.generator.generator.needsSourceImage {
                if let sourceLayer = sourceImageLayer(for: config, model: model) {
                    hasher.combine(sourceLayer.kind)
                    sampler = self.sampler(for: sourceLayer, model: model)
                }
            }
            let hash = hasher.finalize()
            if let cached = primitives[layer.id], cached.hash == hash {
                return (cached.primitives, cached.naturalSize)
            }
            let context = GeneratorContext(size: model.canvasSize, palette: model.palette, sampler: sampler)
            let prims = config.generator.generator.generate(params: config.params, seed: config.seed, context: context)
            primitives[layer.id] = (hash, prims, model.canvasSize)
            return (prims, model.canvasSize)

        case .text(let config):
            let hash = hasher.finalize()
            if let cached = primitives[layer.id], cached.hash == hash {
                return (cached.primitives, cached.naturalSize)
            }
            let result = TextOutliner.render(config)
            primitives[layer.id] = (hash, result.primitives, result.size)
            return (result.primitives, result.size)

        case .image:
            return ([], .zero)
        }
    }

    /// The image layer a sampled-grid pattern reads from: explicit choice, or
    /// the topmost image layer as a sensible default.
    func sourceImageLayer(for config: PatternConfig, model: ProjectModel) -> Layer? {
        if let id = config.sourceImageLayerID, let layer = model.layer(id: id), layer.kind.isImage {
            return layer
        }
        return model.layers.last(where: { $0.kind.isImage })
    }

    /// Crop + effect chain, at preview or native resolution.
    func resolvedImage(for layer: Layer, config: ImageConfig, model: ProjectModel, quality: RenderQuality) -> CGImage? {
        var hasher = Hasher()
        hasher.combine(config)
        hasher.combine(model.palette)
        let hash = hasher.finalize()

        if quality.maxRasterDimension != nil, let cached = previewImages[layer.id], cached.hash == hash {
            return cached.image
        }

        guard var image = originalImage(key: config.imageKey) else { return nil }

        if let crop = config.crop {
            let rect = CGRect(x: crop.minX * CGFloat(image.width),
                              y: crop.minY * CGFloat(image.height),
                              width: crop.width * CGFloat(image.width),
                              height: crop.height * CGFloat(image.height)).integral
            if let cropped = image.cropping(to: rect) { image = cropped }
        }

        if let maxDim = quality.maxRasterDimension, max(image.width, image.height) > maxDim {
            image = downsample(image, maxDimension: maxDim) ?? image
        }

        let result = EffectPipeline.shared.apply(effects: config.effects, to: image, palette: model.palette)

        if quality.maxRasterDimension != nil {
            previewImages[layer.id] = (hash, result)
        }
        return result
    }

    /// Post-effects sampler for image-driven generators, so glitched/duotoned
    /// pixels feed the pattern — not the untouched original.
    func sampler(for layer: Layer, model: ProjectModel) -> ImageSampler? {
        guard let config = layer.imageConfig else { return nil }
        var hasher = Hasher()
        hasher.combine(config)
        hasher.combine(model.palette)
        let hash = hasher.finalize()
        if let cached = samplers[layer.id], cached.hash == hash {
            return cached.sampler
        }
        guard let resolved = resolvedImage(for: layer, config: config, model: model, quality: .preview),
              let sampler = ImageSampler(cgImage: resolved, maxDimension: 220) else { return nil }
        samplers[layer.id] = (hash, sampler)
        return sampler
    }

    private func downsample(_ image: CGImage, maxDimension: Int) -> CGImage? {
        let scale = Double(maxDimension) / Double(max(image.width, image.height))
        let w = max(1, Int(Double(image.width) * scale))
        let h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
