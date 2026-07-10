import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

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
        /// Composited children (already resolved), drawn inside the group's
        /// transparency layer so group opacity/blend/mask apply once.
        case group([RenderItem])
    }

    let id: UUID
    var opacity: Double
    var blendMode: LayerBlendMode
    /// Local (0..naturalSize) → canvas coordinates.
    var transform: CGAffineTransform
    var naturalSize: CGSize
    var content: Content
    var mask: RenderMask?
    var styles: [LayerStyle] = []
    var svgWarning: String? = nil
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
    private var thumbnails: [UUID: (hash: Int, image: CGImage)] = [:]

    /// While a brush stroke is in flight, this session's buffer overrides the
    /// target layer's content (or mask) so painting previews live.
    var activePaintSession: PaintSession?

    init(document: PixelDocument) {
        self.document = document
    }

    // MARK: - Public

    func renderItems(model: ProjectModel, quality: RenderQuality) -> [RenderItem] {
        resolve(layers: model.layers, model: model, quality: quality)
    }

    func naturalSize(for layer: Layer, model: ProjectModel) -> CGSize {
        switch layer.kind {
        case .pattern, .fill, .group, .adjustment: model.canvasSize
        case .image(let config): config.croppedPixelSize
        case .text: primitivesResult(for: layer, model: model).naturalSize
        case .shape(let config): config.size
        case .path(let config): config.size
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
        thumbnails.removeAll()
    }

    /// Small sidebar thumbnail of one layer's content (mask applied,
    /// transform ignored), cached by content hash. Cheap after the first
    /// render: primitives/effect caches are shared with the main viewport.
    func thumbnail(for layer: Layer, model: ProjectModel) -> CGImage? {
        var hasher = Hasher()
        hasher.combine(layer.kind)
        hasher.combine(layer.mask)
        hasher.combine(model.palette)
        hasher.combine(model.canvasSize.width)
        hasher.combine(model.canvasSize.height)
        let hash = hasher.finalize()
        if let cached = thumbnails[layer.id], cached.hash == hash { return cached.image }

        let naturalSize = naturalSize(for: layer, model: model)
        guard naturalSize.width > 0, naturalSize.height > 0 else { return nil }

        var flat = layer
        flat.isVisible = true
        flat.opacity = 1
        flat.blendMode = .normal
        flat.transform = LayerTransform(position: CGPoint(x: naturalSize.width / 2,
                                                          y: naturalSize.height / 2))
        var solo = model
        solo.layers = [flat]
        solo.background = .clear
        solo.canvasSize = naturalSize

        let scale = 56 / Double(max(naturalSize.width, naturalSize.height))
        let target = CGSize(width: max(8, (naturalSize.width * scale).rounded()),
                            height: max(8, (naturalSize.height * scale).rounded()))
        let items = renderItems(model: solo, quality: .preview)
        guard let image = PNGExporter.render(items: items,
                                             background: .clear,
                                             canvasSize: naturalSize,
                                             targetPixelSize: target) else { return nil }
        thumbnails[layer.id] = (hash, image)
        return image
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

    private func resolve(layers: [Layer], model: ProjectModel,
                         quality: RenderQuality) -> [RenderItem] {
        var resolved: [RenderItem] = []
        for layer in layers where layer.isVisible {
            if case .adjustment(let config) = layer.kind {
                guard !resolved.isEmpty,
                      let base = canvasRaster(items: resolved, model: model, quality: quality) else { continue }
                let adjusted = EffectPipeline.shared.apply(effects: config.effects, to: base,
                                                           palette: model.palette)
                resolved.append(RenderItem(
                    id: layer.id, opacity: layer.opacity, blendMode: layer.blendMode,
                    transform: .identity, naturalSize: model.canvasSize,
                    content: .raster(adjusted), mask: renderMask(for: layer, model: model),
                    styles: layer.styles,
                    svgWarning: "Adjustment layer rendered as a raster overlay."))
                continue
            }
            guard var item = renderItem(for: layer, model: model, quality: quality) else { continue }
            item.styles = layer.styles
            if layer.clipsToBelow, let base = resolved.last,
               let clipped = clippedCanvas(item: item, base: base, model: model, quality: quality) {
                item = RenderItem(id: layer.id, opacity: 1, blendMode: .normal,
                                  transform: .identity, naturalSize: model.canvasSize,
                                  content: .raster(clipped), mask: nil,
                                  svgWarning: "Clipping mask rendered as a raster overlay.")
            }
            resolved.append(item)
        }
        return resolved
    }

    private func targetSize(model: ProjectModel, quality: RenderQuality) -> CGSize {
        guard let cap = quality.maxRasterDimension else { return model.canvasSize }
        let scale = min(1, Double(cap) / Double(max(model.canvasSize.width, model.canvasSize.height)))
        return CGSize(width: max(8, (model.canvasSize.width * scale).rounded()),
                      height: max(8, (model.canvasSize.height * scale).rounded()))
    }

    private func canvasRaster(items: [RenderItem], model: ProjectModel,
                              quality: RenderQuality) -> CGImage? {
        PNGExporter.render(items: items, background: .clear,
                           canvasSize: model.canvasSize,
                           targetPixelSize: targetSize(model: model, quality: quality))
    }

    private func clippedCanvas(item: RenderItem, base: RenderItem,
                               model: ProjectModel, quality: RenderQuality) -> CGImage? {
        guard let foreground = canvasRaster(items: [item], model: model, quality: quality),
              let alphaBase = canvasRaster(items: [base], model: model, quality: quality) else { return nil }
        let width = foreground.width, height = foreground.height
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(foreground, in: rect)
        context.setBlendMode(.destinationIn)
        context.draw(alphaBase, in: rect)
        return context.makeImage()
    }

    private func renderItem(for layer: Layer, model: ProjectModel, quality: RenderQuality) -> RenderItem? {
        let mask = renderMask(for: layer, model: model)
        switch layer.kind {
        case .pattern, .text, .shape, .path:
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
        case .group(let config):
            let children = resolve(layers: config.children, model: model, quality: quality)
            return RenderItem(id: layer.id,
                              opacity: layer.opacity,
                              blendMode: layer.blendMode,
                              transform: layer.transform.affine(naturalSize: model.canvasSize),
                              naturalSize: model.canvasSize,
                              content: .group(children),
                              mask: mask)
        case .adjustment:
            return nil
        }
    }

    /// Alpha + luminance mask images for a layer, cached by mask hash.
    private func renderMask(for layer: Layer, model: ProjectModel) -> RenderMask? {
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
        let grayscale: CGImage?
        if let pattern = mask.pattern {
            var sampler: ImageSampler?
            if pattern.generator.generator.needsSourceImage,
               let source = sourceImageLayer(for: pattern, model: model) {
                sampler = self.sampler(for: source, model: model)
            }
            let palette = Palette(name: "Mask", hex: ["#000000", "#FFFFFF", "#777777", "#CCCCCC", "#333333"])
            let context = GeneratorContext(size: mask.pixelSize, palette: palette, sampler: sampler)
            let primitives = pattern.generator.generator.generate(params: pattern.params,
                                                                  seed: pattern.seed,
                                                                  context: context)
            let item = RenderItem(id: layer.id, opacity: 1, blendMode: .normal,
                                  transform: .identity, naturalSize: mask.pixelSize,
                                  content: .primitives(primitives), mask: nil)
            grayscale = PNGExporter.render(items: [item], background: .black,
                                           canvasSize: mask.pixelSize,
                                           targetPixelSize: mask.pixelSize)
        } else {
            grayscale = originalImage(key: mask.imageKey)
        }
        guard let grayscale,
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
            var textPath: Path?
            if let pathID = config.pathLayerID,
               let pathLayer = model.layer(id: pathID),
               let pathConfig = pathLayer.pathConfig {
                hasher.combine(pathLayer.kind)
                textPath = PathGeometry.path(for: pathConfig)
            }
            let hash = hasher.finalize()
            if let cached = primitives[layer.id], cached.hash == hash {
                return (cached.primitives, cached.naturalSize)
            }
            let result = TextOutliner.render(config, path: textPath)
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

        case .path(let config):
            let hash = hasher.finalize()
            if let cached = primitives[layer.id], cached.hash == hash {
                return (cached.primitives, cached.naturalSize)
            }
            let prims = PathGeometry.primitives(for: config)
            primitives[layer.id] = (hash, prims, config.size)
            return (prims, config.size)

        case .image, .fill, .group, .adjustment:
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
