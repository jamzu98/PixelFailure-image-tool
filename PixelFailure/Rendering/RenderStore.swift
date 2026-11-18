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
    var clipsToBounds = false
    var deformation: LayerDeformation? = nil
    var mask: RenderMask?
    var styles: [LayerStyle] = []
    var svgWarning: String? = nil

    /// Whether the item must be drawn into its own transparency layer.
    /// Opacity, blend modes, and masks apply to the item as a whole; groups
    /// isolate their children's blending. Anything else draws directly,
    /// which avoids a full offscreen buffer per item per tile.
    nonisolated var needsIsolatedCompositing: Bool {
        if opacity < 1 || blendMode != .normal || mask != nil { return true }
        if case .group = content { return true }
        return false
    }
}

nonisolated enum RenderQuality: Hashable, Sendable {
    /// Fast mip used only while a continuous editor gesture is in flight.
    case proxy
    /// Rasters capped to a working resolution for interactive speed.
    case preview
    /// Native resolution — used at export time.
    case full

    var maxRasterDimension: Int? {
        switch self {
        case .proxy: 512
        case .preview: 1600
        case .full: nil
        }
    }
}

nonisolated enum RenderInvalidationRegion: Equatable, Sendable {
    case none
    case rect(CGRect)
    case full

    func union(_ other: RenderInvalidationRegion) -> RenderInvalidationRegion {
        switch (self, other) {
        case (.full, _), (_, .full): .full
        case (.none, let other), (let other, .none): other
        case (.rect(let a), .rect(let b)): .rect(a.union(b))
        }
    }
}

nonisolated struct ViewportInvalidation: Equatable, Sendable {
    var revision: UInt64
    var region: RenderInvalidationRegion

    static let initial = ViewportInvalidation(revision: 0, region: .full)
}

/// Per-document render cache: decoded images, resolved effect chains,
/// generated primitives. Owned by the editor window; all main-actor.
final class RenderStore: ObservableObject {
    private struct RasterCacheKey: Hashable {
        let layerID: UUID
        let quality: RenderQuality
    }

    private struct SceneCacheKey: Hashable {
        let modelHash: Int
        let quality: RenderQuality
    }

    private unowned let document: PixelDocument

    @Published private(set) var viewportInvalidation: ViewportInvalidation = .initial
    /// Recent invalidations, oldest first. SwiftUI can coalesce several model
    /// publications into one view update; a consumer that only read the
    /// newest region would leave stale tiles behind, so it asks for the union
    /// of everything since the revision it last saw.
    private var invalidationLog: [ViewportInvalidation] = []
    private let invalidationLogLimit = 64
    /// The last planned change, so a caller that plans eagerly (the canvas,
    /// committing a drag) and the editor's model observer don't double-plan.
    private var lastPlannedChange: (old: ProjectModel, new: ProjectModel)?

    private var decodedImages: [String: CGImage] = [:]
    /// Resolved image content is retained independently at every viewport tier.
    /// A proxy request must never evict the warm preview/full surface that the
    /// next interaction or handoff needs.
    private var resolvedImages: [RasterCacheKey: (hash: Int, image: CGImage)] = [:]
    /// Small LRU of immutable resolved scenes. Transform interaction can borrow
    /// the exact scene already supplied to the tiled renderer and update only
    /// affine matrices instead of resolving/rasterizing content on pointer-down.
    private var sceneCache: [SceneCacheKey: [RenderItem]] = [:]
    private var sceneCacheOrder: [SceneCacheKey] = []
    private let sceneCacheLimit = 12
    private var primitives: [UUID: (hash: Int, primitives: [VectorPrimitive], naturalSize: CGSize)] = [:]
    private var samplers: [UUID: (hash: Int, sampler: ImageSampler)] = [:]
    private var masks: [UUID: (hash: Int, mask: RenderMask)] = [:]
    private var composites: [RenderQuality: (hash: Int, image: CGImage)] = [:]
    private var thumbnails: [UUID: (hash: Int, image: CGImage)] = [:]

    /// While a brush stroke is in flight, this session's buffer overrides the
    /// target layer's content (or mask) so painting previews live.
    var activePaintSession: PaintSession?

    init(document: PixelDocument) {
        self.document = document
    }

    // MARK: - Public

    func renderItems(model: ProjectModel, quality: RenderQuality) -> [RenderItem] {
        // Live paint is intentionally absent from ProjectModel, so it must not
        // read or populate a model-keyed scene entry.
        guard activePaintSession == nil else {
            return resolve(layers: model.layers, model: model, quality: quality)
        }
        let key = SceneCacheKey(modelHash: model.hashValue, quality: quality)
        if let cached = sceneCache[key] {
            touchScene(key)
            return cached
        }
        let items = resolve(layers: model.layers, model: model, quality: quality)
        storeScene(items, for: key)
        return items
    }

    /// Resolves an immediate paint preview without changing which paint surface
    /// the retained tiled renderer will use for its document snapshot.
    func renderItems(model: ProjectModel, quality: RenderQuality,
                     overridingWith paintSession: PaintSession) -> [RenderItem] {
        let previous = activePaintSession
        activePaintSession = paintSession
        defer { activePaintSession = previous }
        return resolve(layers: model.layers, model: model, quality: quality)
    }

    /// Returns only an already-resolved scene; it never decodes, downsamples,
    /// runs effects, or rasterizes. This is safe to call from pointer handlers.
    func cachedRenderItems(model: ProjectModel,
                           preferredQualities: [RenderQuality] = [.preview, .proxy, .full]) -> [RenderItem]? {
        guard activePaintSession == nil else { return nil }
        let modelHash = model.hashValue
        for quality in preferredQualities {
            let key = SceneCacheKey(modelHash: modelHash, quality: quality)
            if let cached = sceneCache[key] {
                touchScene(key)
                return cached
            }
        }
        return nil
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
        if let resident = document.residentImage(for: key) {
            decodedImages[key] = resident
            return resident
        }
        guard let data = document.imageData(for: key),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCache: true,
              ] as CFDictionary) else { return nil }
        decodedImages[key] = image
        return image
    }

    /// Installs an image that is already resident (notably a finished paint
    /// buffer) under its persisted key. Publishing that key can then render
    /// immediately without an encode/decode round trip on the main actor.
    func adoptOriginalImage(_ image: CGImage, for key: String) {
        decodedImages[key] = image
    }

    /// Drops content caches; decoded originals stay (they never change per key).
    func invalidateResolved() {
        resolvedImages.removeAll()
        sceneCache.removeAll()
        sceneCacheOrder.removeAll()
        primitives.removeAll()
        samplers.removeAll()
        masks.removeAll()
        composites.removeAll()
        thumbnails.removeAll()
    }

    /// Converts a model mutation into a canvas-space dirty region. Workspace,
    /// selection, and animation-settings-only changes intentionally produce no
    /// redraw; structural/global and evaluated-animation changes conservatively
    /// invalidate the canvas.
    func modelDidChange(from oldModel: ProjectModel, to newModel: ProjectModel) {
        // Array equality short-circuits on shared storage, so comparing
        // against the copies kept here is cheap.
        if let last = lastPlannedChange, last.old == oldModel, last.new == newModel { return }
        lastPlannedChange = (oldModel, newModel)
        // Slider drags publish many intermediate models; their path is not
        // worth tracking rect by rect. Discrete edits (including a committed
        // canvas move) invalidate exactly the old ∪ new bounds; consumers
        // union regions across coalesced updates via `invalidation(since:)`.
        let region: RenderInvalidationRegion = if document.isContinuousEditing {
            .full
        } else {
            RenderInvalidationPlanner.region(from: oldModel, to: newModel) {
                [weak self] layer, model in
                self?.renderBounds(for: layer, model: model) ?? .zero
            }
        }
        guard region != .none else { return }
        let next = ViewportInvalidation(revision: viewportInvalidation.revision &+ 1,
                                        region: region)
        invalidationLog.append(next)
        if invalidationLog.count > invalidationLogLimit {
            invalidationLog.removeFirst(invalidationLog.count - invalidationLogLimit)
        }
        viewportInvalidation = next
    }

    /// The newest revision with the union of every region published after
    /// `revision`. Unknown or evicted history conservatively yields `.full`.
    func invalidation(since revision: UInt64?) -> ViewportInvalidation {
        let current = viewportInvalidation
        guard let revision, revision != current.revision else { return current }
        guard revision < current.revision,
              let oldest = invalidationLog.first,
              oldest.revision <= revision &+ 1 else {
            return ViewportInvalidation(revision: current.revision, region: .full)
        }
        var region = RenderInvalidationRegion.none
        for entry in invalidationLog where entry.revision > revision {
            region = region.union(entry.region)
        }
        return ViewportInvalidation(revision: current.revision, region: region)
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
                                             targetPixelSize: target,
                                             colorSettings: model.colorSettings.previewVariant) else { return nil }
        thumbnails[layer.id] = (hash, image)
        return image
    }

    /// Flattened composite with the canvas-level effect stack applied, at
    /// preview resolution. Used by the viewport when canvasEffects is
    /// non-empty. `extraHash` lets callers force refresh (e.g. paint ticks).
    func compositePreview(model: ProjectModel, extraHash: Int = 0) -> CGImage? {
        composite(model: model, quality: .preview, extraHash: extraHash)
    }

    /// Flattened composite for the requested viewport tier. Proxy and preview
    /// tiers are mip-sized; idle `.full` uses the native canvas dimensions.
    func composite(model: ProjectModel, quality: RenderQuality,
                   extraHash: Int = 0) -> CGImage? {
        guard !model.canvasEffects.isEmpty else { return nil }
        var hasher = Hasher()
        hasher.combine(model)
        hasher.combine(quality)
        hasher.combine(extraHash)
        let hash = hasher.finalize()
        if let cached = composites[quality], cached.hash == hash { return cached.image }

        let maxDim = quality.maxRasterDimension.map(Double.init)
            ?? Double(max(model.canvasSize.width, model.canvasSize.height))
        let scale = min(1, maxDim / Double(max(model.canvasSize.width, model.canvasSize.height)))
        let target = CGSize(width: max(8, model.canvasSize.width * scale),
                            height: max(8, model.canvasSize.height * scale))
        let items = renderItems(model: model, quality: quality)
        guard let flat = PNGExporter.render(items: items,
                                            background: model.background,
                                            canvasSize: model.canvasSize,
                                            targetPixelSize: target,
                                            colorSettings: model.colorSettings.previewVariant) else { return nil }
        let result = EffectPipeline.shared.apply(effects: model.canvasEffects, to: flat, palette: model.palette)
        composites[quality] = (hash, result)
        return result
    }

    /// Canvas-effect preview for a resident paint surface without leaking that
    /// transient override into the final tiled snapshot.
    func composite(model: ProjectModel, quality: RenderQuality,
                   extraHash: Int, overridingWith paintSession: PaintSession) -> CGImage? {
        let previous = activePaintSession
        activePaintSession = paintSession
        defer { activePaintSession = previous }
        return composite(model: model, quality: quality, extraHash: extraHash)
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

    /// Full quality composites at the document's depth; previews stay 8-bit.
    private func renderSettings(model: ProjectModel, quality: RenderQuality) -> ColorSettings {
        quality == .full ? model.colorSettings : model.colorSettings.previewVariant
    }

    private func canvasRaster(items: [RenderItem], model: ProjectModel,
                              quality: RenderQuality) -> CGImage? {
        PNGExporter.render(items: items, background: .clear,
                           canvasSize: model.canvasSize,
                           targetPixelSize: targetSize(model: model, quality: quality),
                           colorSettings: renderSettings(model: model, quality: quality))
    }

    private func clippedCanvas(item: RenderItem, base: RenderItem,
                               model: ProjectModel, quality: RenderQuality) -> CGImage? {
        guard let foreground = canvasRaster(items: [item], model: model, quality: quality),
              let alphaBase = canvasRaster(items: [base], model: model, quality: quality) else { return nil }
        let width = foreground.width, height = foreground.height
        guard let context = renderSettings(model: model, quality: quality)
            .makeRGBAContext(width: width, height: height) else { return nil }
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
                              clipsToBounds: layer.kind.isPattern,
                              deformation: layer.transform.deformation,
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
                              deformation: layer.transform.deformation,
                              mask: mask)
        case .fill(let config):
            return RenderItem(id: layer.id,
                              opacity: layer.opacity,
                              blendMode: layer.blendMode,
                              transform: layer.transform.affine(naturalSize: model.canvasSize),
                              naturalSize: model.canvasSize,
                              content: .fill(config),
                              deformation: layer.transform.deformation,
                              mask: mask)
        case .group(let config):
            let children = resolve(layers: config.children, model: model, quality: quality)
            return RenderItem(id: layer.id,
                              opacity: layer.opacity,
                              blendMode: layer.blendMode,
                              transform: layer.transform.affine(naturalSize: model.canvasSize),
                              naturalSize: model.canvasSize,
                              content: .group(children),
                              deformation: layer.transform.deformation,
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
        hasher.combine(quality)
        let hash = hasher.finalize()

        let cacheKey = RasterCacheKey(layerID: layer.id, quality: quality)
        if let cached = resolvedImages[cacheKey], cached.hash == hash {
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
            image = downsample(image, maxDimension: maxDim,
                               space: model.colorSettings.workingSpace) ?? image
        }

        let result = EffectPipeline.shared.apply(effects: config.effects, to: image, palette: model.palette)

        resolvedImages[cacheKey] = (hash, result)
        return result
    }

    private func storeScene(_ items: [RenderItem], for key: SceneCacheKey) {
        sceneCache[key] = items
        touchScene(key)
        while sceneCacheOrder.count > sceneCacheLimit {
            let evicted = sceneCacheOrder.removeFirst()
            sceneCache.removeValue(forKey: evicted)
        }
    }

    private func touchScene(_ key: SceneCacheKey) {
        sceneCacheOrder.removeAll { $0 == key }
        sceneCacheOrder.append(key)
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
              let sampler = ImageSampler(cgImage: resolved, maxDimension: 220,
                                         space: model.colorSettings.workingSpace) else { return nil }
        samplers[layer.id] = (hash, sampler)
        return sampler
    }

    private func downsample(_ image: CGImage, maxDimension: Int,
                            space: WorkingColorSpace) -> CGImage? {
        let scale = Double(maxDimension) / Double(max(image.width, image.height))
        let w = max(1, Int(Double(image.width) * scale))
        let h = max(1, Int(Double(image.height) * scale))
        guard let ctx = ColorSettings(workingSpace: space, bitDepth: .eight)
            .makeRGBAContext(width: w, height: h) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Canvas-space bounds of everything a layer draws (styles and
    /// antialiasing included).
    func renderBounds(for layer: Layer, model: ProjectModel) -> CGRect {
        let size = naturalSize(for: layer, model: model)
        guard size.width > 0, size.height > 0 else { return .zero }
        let local = layer.transform.affine(naturalSize: size)
        let world = local.concatenating(model.parentAffine(of: layer.id))
        var bounds: CGRect
        if let deformation = layer.transform.deformation {
            let points = deformation.triangles(size: size).flatMap {
                [$0.destination.0, $0.destination.1, $0.destination.2]
            }.map { $0.applying(world) }
            if let first = points.first {
                bounds = points.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
                    $0.union(CGRect(origin: $1, size: .zero))
                }.standardized
            } else {
                bounds = CGRect(origin: .zero, size: size).applying(world).standardized
            }
        } else {
            bounds = CGRect(origin: .zero, size: size).applying(world).standardized
        }
        let worldScale = max(hypot(world.a, world.b), hypot(world.c, world.d))
        for style in layer.styles where style.isEnabled {
            let outset = (style.size + max(abs(style.offsetX), abs(style.offsetY))) * worldScale
            bounds = bounds.insetBy(dx: -outset, dy: -outset)
        }
        // Cover Core Graphics antialiasing that can extend just outside the
        // mathematical layer bounds and into an adjacent retained tile.
        return bounds.insetBy(dx: -2, dy: -2)
    }
}

enum RenderInvalidationPlanner {
    typealias Bounds = (_ layer: Layer, _ model: ProjectModel) -> CGRect

    static func region(from oldModel: ProjectModel, to newModel: ProjectModel,
                       bounds: Bounds) -> RenderInvalidationRegion {
        guard oldModel != newModel else { return .none }

        if oldModel.canvasSize != newModel.canvasSize
            || oldModel.background != newModel.background
            || oldModel.colorSettings != newModel.colorSettings
            || oldModel.palette != newModel.palette
            || oldModel.canvasEffects != newModel.canvasEffects
            || oldModel.animation != newModel.animation {
            return .full
        }

        let oldLayers = oldModel.allLayers
        let newLayers = newModel.allLayers
        guard oldLayers.map(\.id) == newLayers.map(\.id) else { return .full }
        for layer in oldLayers {
            guard oldModel.parentGroupID(of: layer.id) == newModel.parentGroupID(of: layer.id) else {
                return .full
            }
        }

        var dirty: CGRect?
        for oldLayer in oldLayers {
            guard let newLayer = newModel.layer(id: oldLayer.id), oldLayer != newLayer else { continue }
            if oldLayer.kind.isGroup || newLayer.kind.isGroup
                || oldLayer.kind.isAdjustment || newLayer.kind.isAdjustment
                || oldLayer.clipsToBelow || newLayer.clipsToBelow {
                return .full
            }
            let changed = bounds(oldLayer, oldModel).union(bounds(newLayer, newModel))
            guard !changed.isNull, !changed.isEmpty else { continue }
            dirty = dirty.map { $0.union(changed) } ?? changed
        }

        guard let dirty else { return .none }
        let canvas = CGRect(origin: .zero, size: newModel.canvasSize)
        let clipped = dirty.intersection(canvas)
        return clipped.isNull || clipped.isEmpty ? .none : .rect(clipped)
    }
}
