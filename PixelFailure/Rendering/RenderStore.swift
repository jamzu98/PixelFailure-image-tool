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

    // MARK: Progressive resolution state

    private struct BackgroundJobKey: Hashable {
        let layerID: UUID
        /// nil for vector primitives, which don't depend on the tier.
        let quality: RenderQuality?
    }

    /// True while resolving for the viewport, which may show a lower tier or
    /// the previous content while the exact result renders off the main actor.
    private var isResolvingProgressively = false
    /// Set when the scene being resolved borrowed any placeholder content.
    private var resolveUsedPlaceholder = false
    /// Hash each background job is computing, per layer and tier.
    private var runningJobs: [BackgroundJobKey: Int] = [:]
    /// The newest request that arrived while a job for the same key was
    /// running. Only the latest survives, so slider drags never queue up.
    private var queuedJobs: [BackgroundJobKey: (hash: Int, start: () -> Void)] = [:]
    /// GPU-rendered raster patterns per layer and tier, keyed by content hash.
    private var rasterPatterns: [RasterCacheKey: (hash: Int, image: CGImage)] = [:]
    /// Most recent resolved raster per layer, any tier or hash.
    private var latestImages: [UUID: CGImage] = [:]
    /// Bumped by `invalidateResolved`, so results computed against dropped
    /// caches are discarded.
    private var cacheGeneration = 0

    init(document: PixelDocument) {
        self.document = document
    }

    // MARK: - Public

    func renderItems(model: ProjectModel, quality: RenderQuality) -> [RenderItem] {
        renderItems(model: model, quality: quality, progressive: false)
    }

    /// With `progressive`, expensive layer content that isn't cached yet
    /// (effect stacks on large images, regenerated patterns) renders on a
    /// background task. Until it lands the scene uses the closest cached
    /// content, and the finished result publishes a viewport invalidation.
    /// Exporters use the default, which always resolves exactly.
    func renderItems(model: ProjectModel, quality: RenderQuality, progressive: Bool) -> [RenderItem] {
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
        isResolvingProgressively = progressive
        resolveUsedPlaceholder = false
        defer { isResolvingProgressively = false }
        let items = resolve(layers: model.layers, model: model, quality: quality)
        // Scenes holding placeholders must never be served to an exporter.
        if !resolveUsedPlaceholder { storeScene(items, for: key) }
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
        cacheGeneration &+= 1
        runningJobs.removeAll()
        queuedJobs.removeAll()
        latestImages.removeAll()
        rasterPatterns.removeAll()
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
        publish(region)
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
        // The layer a run of clipped layers clips to. Every clipped layer in
        // the run clips to this base, not to the clipped layer below it.
        var clipBase: RenderItem?
        for layer in layers where layer.isVisible {
            if case .adjustment(let config) = layer.kind {
                guard !resolved.isEmpty,
                      let base = canvasRaster(items: resolved, model: model, quality: quality) else { continue }
                let adjusted = EffectPipeline.shared.apply(effects: config.effects, to: base,
                                                           palette: model.palette)
                let adjustmentItem = RenderItem(
                    id: layer.id, opacity: layer.opacity, blendMode: layer.blendMode,
                    transform: .identity, naturalSize: model.canvasSize,
                    content: .raster(adjusted), mask: renderMask(for: layer, model: model),
                    styles: layer.styles,
                    svgWarning: "Adjustment layer rendered as a raster overlay.")
                resolved.append(adjustmentItem)
                clipBase = adjustmentItem
                continue
            }
            guard var item = renderItem(for: layer, model: model, quality: quality) else { continue }
            item.styles = layer.styles
            if layer.clipsToBelow, let base = clipBase {
                if let clipped = clippedCanvas(item: item, base: base, model: model, quality: quality) {
                    // The layer's own opacity and blend mode apply to the
                    // clipped result as a whole, against everything below.
                    item = RenderItem(id: layer.id, opacity: layer.opacity, blendMode: layer.blendMode,
                                      transform: .identity, naturalSize: model.canvasSize,
                                      content: .raster(clipped), mask: nil,
                                      svgWarning: "Clipping mask rendered as a raster overlay.")
                }
                resolved.append(item)
            } else {
                resolved.append(item)
                clipBase = item
            }
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

    /// The clipped layer's pixels (mask and styles included) limited to the
    /// base's alpha. Opacity and blend mode are left out: the caller applies
    /// them to the result so they composite against the whole stack below.
    private func clippedCanvas(item: RenderItem, base: RenderItem,
                               model: ProjectModel, quality: RenderQuality) -> CGImage? {
        var flat = item
        flat.opacity = 1
        flat.blendMode = .normal
        guard let foreground = canvasRaster(items: [flat], model: model, quality: quality),
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
        case .pattern(let config) where config.generator.isRaster:
            guard let image = rasterPattern(for: layer, config: config, model: model, quality: quality) else { return nil }
            return RenderItem(id: layer.id,
                              opacity: layer.opacity,
                              blendMode: layer.blendMode,
                              transform: layer.transform.affine(naturalSize: model.canvasSize),
                              naturalSize: model.canvasSize,
                              content: .raster(image),
                              clipsToBounds: true,
                              deformation: layer.transform.deformation,
                              mask: mask,
                              svgWarning: "Raster pattern embedded as an image.")
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
        if let pattern = mask.pattern, pattern.generator.isRaster {
            let palette = Palette(name: "Mask", hex: ["#000000", "#FFFFFF"])
            grayscale = RasterPatternJob(config: pattern, size: mask.pixelSize, palette: palette,
                                         colorSettings: .default).render()
        } else if let pattern = mask.pattern {
            var sampler: ImageSampler?
            if pattern.usesSourceImage,
               let source = sourceImageLayer(for: pattern, model: model) {
                sampler = self.sampler(for: source, model: model)
            }
            let palette = Palette(name: "Mask", hex: ["#000000", "#FFFFFF", "#777777", "#CCCCCC", "#333333"])
            let context = GeneratorContext(size: mask.pixelSize, palette: palette, sampler: sampler)
            let primitives = pattern.generate(context: context)
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
            if config.usesSourceImage {
                if let sourceLayer = sourceImageLayer(for: config, model: model) {
                    hasher.combine(sourceLayer.kind)
                    sampler = self.sampler(for: sourceLayer, model: model)
                }
            }
            let region = regionPath(for: config, patternLayer: layer, model: model, hasher: &hasher)
            let hash = hasher.finalize()
            if let cached = primitives[layer.id], cached.hash == hash {
                return (cached.primitives, cached.naturalSize)
            }
            var context = GeneratorContext(size: model.canvasSize, palette: model.palette, sampler: sampler)
            context.region = region
            // A regenerated pattern keeps showing its previous output while
            // the new one generates off-main; the first generation is inline.
            if isResolvingProgressively, let stale = primitives[layer.id],
               stale.naturalSize == model.canvasSize {
                resolveUsedPlaceholder = true
                schedulePrimitives(layerID: layer.id, hash: hash, config: config, context: context)
                return (stale.primitives, stale.naturalSize)
            }
            let prims = config.generate(context: context)
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

    /// The context a pattern layer generates in (canvas size, palette, image
    /// sampler and region outline), for rendering variations off the main actor.
    func generatorContext(for layer: Layer, config: PatternConfig, model: ProjectModel) -> GeneratorContext {
        var sampler: ImageSampler?
        if config.usesSourceImage, let source = sourceImageLayer(for: config, model: model) {
            sampler = self.sampler(for: source, model: model)
        }
        var hasher = Hasher()
        var context = GeneratorContext(size: model.canvasSize, palette: model.palette, sampler: sampler)
        context.region = regionPath(for: config, patternLayer: layer, model: model, hasher: &hasher)
        return context
    }

    /// The outline of a pattern's region layer (shape, text or path), mapped
    /// into the pattern layer's own coordinates. Feeds the region's geometry
    /// and placement into `hasher` so the pattern regenerates when it moves.
    private func regionPath(for config: PatternConfig, patternLayer: Layer,
                            model: ProjectModel, hasher: inout Hasher) -> Path? {
        guard GenStages.regionMode(config.params) != .off,
              let id = config.regionLayerID, id != patternLayer.id,
              let regionLayer = model.layer(id: id) else { return nil }
        switch regionLayer.kind {
        case .shape, .text, .path: break
        default: return nil
        }
        let result = primitivesResult(for: regionLayer, model: model)
        var outline = Path()
        for primitive in result.primitives { outline.addPath(primitive.path) }
        let regionWorld = regionLayer.transform.affine(naturalSize: result.naturalSize)
            .concatenating(model.parentAffine(of: id))
        let patternWorld = patternLayer.transform.affine(naturalSize: model.canvasSize)
            .concatenating(model.parentAffine(of: patternLayer.id))
        guard patternWorld.isInvertible else { return nil }
        let toPattern = regionWorld.concatenating(patternWorld.inverted())
        hasher.combine(regionLayer.kind)
        for value in [toPattern.a, toPattern.b, toPattern.c, toPattern.d, toPattern.tx, toPattern.ty] {
            hasher.combine(Double(value))
        }
        return outline.applying(toPattern)
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
        // The tier is part of the cache key, so the hash covers content only
        // and lets one tier stand in for another with identical content.
        var hasher = Hasher()
        hasher.combine(config)
        hasher.combine(model.palette)
        hasher.combine(model.colorSettings.workingSpace)
        let hash = hasher.finalize()

        let cacheKey = RasterCacheKey(layerID: layer.id, quality: quality)
        if let cached = resolvedImages[cacheKey], cached.hash == hash {
            return cached.image
        }

        let resident = originalImageIfResident(key: config.imageKey)
        let request = ImageResolveRequest(
            decoded: resident,
            data: resident == nil ? document.imageData(for: config.imageKey) : nil,
            crop: config.crop, maxDimension: quality.maxRasterDimension,
            space: model.colorSettings.workingSpace,
            effects: config.effects, palette: model.palette)

        if isResolvingProgressively, quality != .proxy, request.isExpensive,
           let placeholder = placeholderImage(layerID: layer.id, hash: hash, quality: quality) {
            resolveUsedPlaceholder = true
            scheduleImage(layerID: layer.id, imageKey: config.imageKey, quality: quality,
                          hash: hash, request: request)
            return placeholder
        }

        guard let resolved = request.resolve() else { return nil }
        if let decoded = resolved.decoded { decodedImages[config.imageKey] = decoded }
        resolvedImages[cacheKey] = (hash, resolved.image)
        latestImages[layer.id] = resolved.image
        return resolved.image
    }

    private func originalImageIfResident(key: String) -> CGImage? {
        decodedImages[key] ?? document.residentImage(for: key)
    }

    /// The closest content to stand in for an uncached tier: the same content
    /// at another tier first, then whatever this layer showed last.
    private func placeholderImage(layerID: UUID, hash: Int, quality: RenderQuality) -> CGImage? {
        let order: [RenderQuality] = quality == .full ? [.preview, .proxy] : [.full, .proxy]
        for tier in order {
            if let cached = resolvedImages[RasterCacheKey(layerID: layerID, quality: tier)],
               cached.hash == hash { return cached.image }
        }
        return latestImages[layerID]
    }

    /// A raster pattern at the tier's resolution. On the progressive path a
    /// cache miss shows the closest earlier render while the GPU works.
    private func rasterPattern(for layer: Layer, config: PatternConfig, model: ProjectModel,
                               quality: RenderQuality) -> CGImage? {
        var hasher = Hasher()
        hasher.combine(config)
        hasher.combine(model.palette)
        hasher.combine(model.colorSettings)
        hasher.combine(model.canvasSize.width)
        hasher.combine(model.canvasSize.height)
        let hash = hasher.finalize()
        let key = RasterCacheKey(layerID: layer.id, quality: quality)
        if let cached = rasterPatterns[key], cached.hash == hash { return cached.image }

        let job = RasterPatternJob(config: config, size: targetSize(model: model, quality: quality),
                                   palette: model.palette,
                                   colorSettings: renderSettings(model: model, quality: quality))
        if isResolvingProgressively, quality != .proxy {
            let order: [RenderQuality] = quality == .full ? [.preview, .proxy] : [.full, .proxy]
            let placeholder = order.lazy.compactMap { tier -> CGImage? in
                guard let cached = self.rasterPatterns[RasterCacheKey(layerID: layer.id, quality: tier)],
                      cached.hash == hash else { return nil }
                return cached.image
            }.first ?? latestImages[layer.id]
            if let placeholder {
                resolveUsedPlaceholder = true
                scheduleRasterPattern(layerID: layer.id, quality: quality, hash: hash, job: job)
                return placeholder
            }
        }
        guard let image = job.render() else { return nil }
        rasterPatterns[key] = (hash, image)
        latestImages[layer.id] = image
        return image
    }

    // MARK: - Background jobs

    private func scheduleRasterPattern(layerID: UUID, quality: RenderQuality, hash: Int, job: RasterPatternJob) {
        let key = BackgroundJobKey(layerID: layerID, quality: quality)
        let generation = cacheGeneration
        enqueue(key, hash: hash) { [weak self] in
            Task.detached(priority: .userInitiated) {
                let image = job.render()
                await MainActor.run {
                    guard let self else { return }
                    defer { self.finishJob(key) }
                    guard generation == self.cacheGeneration, let image else { return }
                    self.rasterPatterns[RasterCacheKey(layerID: layerID, quality: quality)] = (hash, image)
                    self.latestImages[layerID] = image
                    self.backgroundContentDidChange(layerID: layerID)
                }
            }
        }
    }

    private func scheduleImage(layerID: UUID, imageKey: String, quality: RenderQuality,
                               hash: Int, request: ImageResolveRequest) {
        let key = BackgroundJobKey(layerID: layerID, quality: quality)
        let generation = cacheGeneration
        enqueue(key, hash: hash) { [weak self] in
            Task.detached(priority: .userInitiated) {
                let resolved = request.resolve()
                await MainActor.run {
                    guard let self else { return }
                    defer { self.finishJob(key) }
                    guard generation == self.cacheGeneration, let resolved else { return }
                    if let decoded = resolved.decoded { self.decodedImages[imageKey] = decoded }
                    self.resolvedImages[RasterCacheKey(layerID: layerID, quality: quality)] = (hash, resolved.image)
                    self.latestImages[layerID] = resolved.image
                    self.backgroundContentDidChange(layerID: layerID)
                }
            }
        }
    }

    private func schedulePrimitives(layerID: UUID, hash: Int, config: PatternConfig,
                                    context: GeneratorContext) {
        let key = BackgroundJobKey(layerID: layerID, quality: nil)
        let generation = cacheGeneration
        let job = PatternJob(config: config, context: context)
        enqueue(key, hash: hash) { [weak self] in
            Task.detached(priority: .userInitiated) {
                let prims = job.generate()
                await MainActor.run {
                    guard let self else { return }
                    defer { self.finishJob(key) }
                    guard generation == self.cacheGeneration else { return }
                    self.primitives[layerID] = (hash, prims, job.context.size)
                    self.backgroundContentDidChange(layerID: layerID)
                }
            }
        }
    }

    /// Starts a job unless the same result is already being computed. A
    /// different request for a busy key waits, replacing any older waiter.
    private func enqueue(_ key: BackgroundJobKey, hash: Int, start: @escaping () -> Void) {
        if let running = runningJobs[key] {
            if running != hash { queuedJobs[key] = (hash, start) }
            return
        }
        runningJobs[key] = hash
        start()
    }

    private func finishJob(_ key: BackgroundJobKey) {
        runningJobs[key] = nil
        if let next = queuedJobs.removeValue(forKey: key) {
            runningJobs[key] = next.hash
            next.start()
        }
    }

    /// A background result landed: drop scenes that may hold its placeholder
    /// and repaint what the layer covers.
    private func backgroundContentDidChange(layerID: UUID) {
        sceneCache.removeAll()
        sceneCacheOrder.removeAll()
        composites.removeAll()
        let model = document.model
        let region: RenderInvalidationRegion
        if let layer = model.layer(id: layerID),
           !model.allLayers.contains(where: { $0.kind.isAdjustment || $0.clipsToBelow }) {
            let canvas = CGRect(origin: .zero, size: model.canvasSize)
            let bounds = renderBounds(for: layer, model: model).intersection(canvas)
            region = bounds.isNull || bounds.isEmpty ? .none : .rect(bounds)
        } else {
            region = .full
        }
        publish(region)
    }

    private func publish(_ region: RenderInvalidationRegion) {
        guard region != .none else { return }
        let next = ViewportInvalidation(revision: viewportInvalidation.revision &+ 1, region: region)
        invalidationLog.append(next)
        if invalidationLog.count > invalidationLogLimit {
            invalidationLog.removeFirst(invalidationLog.count - invalidationLogLimit)
        }
        viewportInvalidation = next
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
        // The sampler is cached by content, so it must never be built from a
        // progressive placeholder.
        let wasProgressive = isResolvingProgressively
        isResolvingProgressively = false
        defer { isResolvingProgressively = wasProgressive }
        guard let resolved = resolvedImage(for: layer, config: config, model: model, quality: .preview),
              let sampler = ImageSampler(cgImage: resolved, maxDimension: 220,
                                         space: model.colorSettings.workingSpace) else { return nil }
        samplers[layer.id] = (hash, sampler)
        return sampler
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

        // Layers a pattern reads from (source image, region outline): a change
        // to one re-renders that whole pattern, not just the layer's own box.
        var referenced = Set<UUID>()
        for layer in newLayers {
            guard let config = layer.patternConfig else { continue }
            if config.usesSourceImage, let id = config.sourceImageLayerID { referenced.insert(id) }
            if config.usesSourceImage, config.sourceImageLayerID == nil,
               let fallback = newModel.layers.last(where: { $0.kind.isImage })?.id {
                referenced.insert(fallback)
            }
            if GenStages.regionMode(config.params) != .off, let id = config.regionLayerID {
                referenced.insert(id)
            }
        }

        var dirty: CGRect?
        for oldLayer in oldLayers {
            guard let newLayer = newModel.layer(id: oldLayer.id), oldLayer != newLayer else { continue }
            if referenced.contains(oldLayer.id) { return .full }
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

/// Everything needed to resolve one image layer's pixels, captured on the
/// main actor so the decode, crop, downsample and effect stack can run on
/// any thread.
nonisolated struct ImageResolveRequest: @unchecked Sendable {
    var decoded: CGImage?
    var data: Data?
    var crop: CGRect?
    var maxDimension: Int?
    var space: WorkingColorSpace
    var effects: [Effect]
    var palette: Palette

    /// Work worth moving off the main actor: an effect stack, a decode, or
    /// a large downsample. Small cached images resolve inline.
    var isExpensive: Bool {
        if effects.contains(where: \.isEnabled) { return true }
        guard let decoded else { return true }
        if let maxDimension, max(decoded.width, decoded.height) > maxDimension * 2 { return true }
        return false
    }

    /// The final pixels, plus the decoded original when this call decoded it.
    func resolve() -> (image: CGImage, decoded: CGImage?)? {
        var freshlyDecoded: CGImage?
        var image: CGImage
        if let decoded {
            image = decoded
        } else {
            guard let data,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, [
                      kCGImageSourceShouldCache: true,
                  ] as CFDictionary) else { return nil }
            image = decoded
            freshlyDecoded = decoded
        }
        if let crop {
            let rect = CGRect(x: crop.minX * CGFloat(image.width),
                              y: crop.minY * CGFloat(image.height),
                              width: crop.width * CGFloat(image.width),
                              height: crop.height * CGFloat(image.height)).integral
            if let cropped = image.cropping(to: rect) { image = cropped }
        }
        if let maxDimension, max(image.width, image.height) > maxDimension {
            image = Self.downsample(image, maxDimension: maxDimension, space: space) ?? image
        }
        let result = EffectPipeline.shared.apply(effects: effects, to: image, palette: palette)
        return (result, freshlyDecoded)
    }

    static func downsample(_ image: CGImage, maxDimension: Int, space: WorkingColorSpace) -> CGImage? {
        let scale = Double(maxDimension) / Double(max(image.width, image.height))
        let w = max(1, Int(Double(image.width) * scale))
        let h = max(1, Int(Double(image.height) * scale))
        guard let ctx = ColorSettings(workingSpace: space, bitDepth: .eight)
            .makeRGBAContext(width: w, height: h) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

/// A pattern regeneration that can run on any thread. Generators are pure
/// and seeded, so the result matches an inline generation exactly.
nonisolated struct PatternJob: @unchecked Sendable {
    let config: PatternConfig
    let context: GeneratorContext

    func generate() -> [VectorPrimitive] {
        config.generate(context: context)
    }
}

/// A raster pattern render that can run on any thread.
nonisolated struct RasterPatternJob: @unchecked Sendable {
    let config: PatternConfig
    let size: CGSize
    let palette: Palette
    let colorSettings: ColorSettings

    func render() -> CGImage? {
        guard let generator = config.generator.generator as? any RasterGenerator else { return nil }
        return generator.render(params: config.params, seed: config.seed, pixelSize: size,
                                palette: palette, colorSettings: colorSettings)
    }
}
