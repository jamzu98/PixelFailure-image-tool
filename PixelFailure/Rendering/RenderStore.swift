import CoreGraphics
import Foundation
import ImageIO

/// A layer mask ready for each renderer: alpha for Core Graphics/Canvas
/// clipping, luminance (grayscale) for SVG's luminance-based masks.
struct RenderMask {
    var alpha: CGImage
    var luminance: CGImage
}

/// A fully resolved, drawable layer. Both the live viewport (GraphicsContext)
/// and the exporters (CGContext / SVG) consume arrays of these.
struct RenderItem: Identifiable {
    enum Content {
        case primitives([VectorPrimitive])
        case raster(CGImage)
        case fill(FillConfig)
    }

    let id: UUID
    var opacity: Double
    var blendMode: LayerBlendMode
    /// Local (0..naturalSize) → canvas coordinates.
    var transform: CGAffineTransform
    var naturalSize: CGSize
    var content: Content
    var mask: RenderMask?
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
    private var masks: [UUID: (hash: Int, mask: RenderMask)] = [:]
    private var composite: (hash: Int, image: CGImage)?

    /// While a brush stroke is in flight, this session's buffer overrides the
    /// target layer's content (or mask) so painting previews live.
    var activePaintSession: PaintSession?

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
        case .pattern, .fill: model.canvasSize
        case .image(let config): config.croppedPixelSize
        case .text: primitivesResult(for: layer, model: model).naturalSize
        case .shape(let config): config.size
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
        masks.removeAll()
        composite = nil
    }

    /// Flattened composite with the canvas-level effect stack applied, at
    /// preview resolution. Used by the viewport when canvasEffects is
    /// non-empty. `extraHash` lets callers force refresh (e.g. paint ticks).
    func compositePreview(model: ProjectModel, extraHash: Int = 0) -> CGImage? {
        guard !model.canvasEffects.isEmpty else { return nil }
        var hasher = Hasher()
        hasher.combine(model)
        hasher.combine(extraHash)
        let hash = hasher.finalize()
        if let composite, composite.hash == hash { return composite.image }

        let maxDim = 1400.0
        let scale = min(1, maxDim / Double(max(model.canvasSize.width, model.canvasSize.height)))
        let target = CGSize(width: max(8, model.canvasSize.width * scale),
                            height: max(8, model.canvasSize.height * scale))
        let items = renderItems(model: model, quality: .preview)
        guard let flat = PNGExporter.render(items: items,
                                            background: model.background,
                                            canvasSize: model.canvasSize,
                                            targetPixelSize: target) else { return nil }
        let result = EffectPipeline.shared.apply(effects: model.canvasEffects, to: flat, palette: model.palette)
        composite = (hash, result)
        return result
    }

    // MARK: - Layer resolution

    private func renderItem(for layer: Layer, model: ProjectModel, quality: RenderQuality) -> RenderItem? {
        let mask = renderMask(for: layer)
        switch layer.kind {
        case .pattern, .text, .shape:
            let result = primitivesResult(for: layer, model: model)
            return RenderItem(id: layer.id,
                              opacity: layer.opacity,
                              blendMode: layer.blendMode,
                              transform: layer.transform.affine(naturalSize: result.naturalSize),
                              naturalSize: result.naturalSize,
                              content: .primitives(result.primitives),
                              mask: mask)
        case .image(let config):
            guard let image = resolvedImage(for: layer, config: config, model: model, quality: quality) else { return nil }
            let naturalSize = config.croppedPixelSize
            return RenderItem(id: layer.id,
                              opacity: layer.opacity,
                              blendMode: layer.blendMode,
                              transform: layer.transform.affine(naturalSize: naturalSize),
                              naturalSize: naturalSize,
                              content: .raster(image),
                              mask: mask)
        case .fill(let config):
            return RenderItem(id: layer.id,
                              opacity: layer.opacity,
                              blendMode: layer.blendMode,
                              transform: layer.transform.affine(naturalSize: model.canvasSize),
                              naturalSize: model.canvasSize,
                              content: .fill(config),
                              mask: mask)
        }
    }

    /// Alpha + luminance mask images for a layer, cached by mask hash.
    private func renderMask(for layer: Layer) -> RenderMask? {
        guard let mask = layer.mask, mask.isEnabled else { return nil }
        // Live mask painting preview.
        if let session = activePaintSession,
           session.isMask,
           session.targetLayerID == layer.id,
           let live = session.currentImage,
           let images = EffectPipeline.shared.maskImages(from: live, inverted: mask.inverted) {
            return RenderMask(alpha: images.alpha, luminance: images.luminance)
        }
        var hasher = Hasher()
        hasher.combine(mask)
        let hash = hasher.finalize()
        if let cached = masks[layer.id], cached.hash == hash {
            return cached.mask
        }
        guard let grayscale = originalImage(key: mask.imageKey),
              let images = EffectPipeline.shared.maskImages(from: grayscale, inverted: mask.inverted) else {
            return nil
        }
        let renderMask = RenderMask(alpha: images.alpha, luminance: images.luminance)
        masks[layer.id] = (hash, renderMask)
        return renderMask
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

        case .shape(let config):
            let hash = hasher.finalize()
            if let cached = primitives[layer.id], cached.hash == hash {
                return (cached.primitives, cached.naturalSize)
            }
            let prims = ShapeGeometry.primitives(for: config)
            primitives[layer.id] = (hash, prims, config.size)
            return (prims, config.size)

        case .image, .fill:
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
        // Live paint preview: show the in-flight buffer raw (effects re-apply
        // when the stroke commits).
        if let session = activePaintSession,
           !session.isMask,
           session.targetLayerID == layer.id,
           let live = session.currentImage {
            if let crop = config.crop {
                let rect = CGRect(x: crop.minX * CGFloat(live.width),
                                  y: crop.minY * CGFloat(live.height),
                                  width: crop.width * CGFloat(live.width),
                                  height: crop.height * CGFloat(live.height)).integral
                return live.cropping(to: rect) ?? live
            }
            return live
        }
        return resolvedImageIgnoringSession(for: layer, config: config, model: model, quality: quality)
    }

    private func resolvedImageIgnoringSession(for layer: Layer, config: ImageConfig, model: ProjectModel, quality: RenderQuality) -> CGImage? {
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
