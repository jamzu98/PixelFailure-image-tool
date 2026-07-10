import AppKit
import QuartzCore
import SwiftUI

/// A transient content change that is not represented by the document model,
/// such as an in-flight brush stroke or evaluated animation frame.
nonisolated struct TransientViewportInvalidation: Equatable {
    var revision: UInt64
    var region: RenderInvalidationRegion

    static let none = TransientViewportInvalidation(revision: 0, region: .none)
}

/// SwiftUI bridge for the retained tile renderer. Model resolution stays on
/// the main actor; immutable snapshots are rasterized off-main.
struct TiledCanvasView: NSViewRepresentable {
    let model: ProjectModel
    let renderStore: RenderStore
    let quality: RenderQuality
    let canvasTransform: CGAffineTransform
    let invalidation: ViewportInvalidation
    let transientInvalidation: TransientViewportInvalidation
    let suspendsContentUpdates: Bool
    let onPresented: (RenderQuality) -> Void

    func makeNSView(context: Context) -> RetainedTileCanvasNSView {
        RetainedTileCanvasNSView()
    }

    func updateNSView(_ view: RetainedTileCanvasNSView, context: Context) {
        view.onPresented = onPresented
        if !suspendsContentUpdates,
           view.requiresResolvedContent(invalidationRevision: invalidation.revision,
                                        quality: quality,
                                        transientRevision: transientInvalidation.revision) {
            let items: [RenderItem]
            let background: RGBAColor
            if let composite = renderStore.composite(
                model: model,
                quality: quality,
                extraHash: Int(truncatingIfNeeded: transientInvalidation.revision)) {
                items = [RenderItem(id: UUID(), opacity: 1, blendMode: .normal,
                                    transform: .identity, naturalSize: model.canvasSize,
                                    content: .raster(composite), mask: nil)]
                background = .clear
            } else {
                items = renderStore.renderItems(model: model, quality: quality)
                background = model.background
            }
            let snapshot = ViewportRenderSnapshot(items: items,
                                                  background: background,
                                                  canvasSize: model.canvasSize,
                                                  workingSpace: model.colorSettings.workingSpace)
            view.updateContent(snapshot: snapshot,
                               quality: quality,
                               invalidation: invalidation,
                               transientInvalidation: transientInvalidation)
        }
        view.updateCanvasTransform(canvasTransform)
    }
}

nonisolated struct ViewportRenderSnapshot: @unchecked Sendable {
    let items: [RenderItem]
    let background: RGBAColor
    let canvasSize: CGSize
    let workingSpace: WorkingColorSpace
}

nonisolated struct TileKey: Hashable, Sendable {
    let level: Int
    let x: Int
    let y: Int
}

nonisolated struct TileSpec: Hashable, Sendable {
    let key: TileKey
    let canvasRect: CGRect
    let renderRect: CGRect
    let rasterScale: CGFloat

    init(key: TileKey, canvasRect: CGRect, rasterScale: CGFloat,
         renderRect: CGRect? = nil) {
        self.key = key
        self.canvasRect = canvasRect
        self.renderRect = renderRect ?? canvasRect
        self.rasterScale = rasterScale
    }

    var contentsRect: CGRect {
        guard renderRect.width > 0, renderRect.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return CGRect(x: (canvasRect.minX - renderRect.minX) / renderRect.width,
                      y: (canvasRect.minY - renderRect.minY) / renderRect.height,
                      width: canvasRect.width / renderRect.width,
                      height: canvasRect.height / renderRect.height)
    }
}

nonisolated struct ViewportRenderRequest: @unchecked Sendable {
    let generation: UInt64
    let contentToken: UInt64
    let snapshot: ViewportRenderSnapshot
    let quality: RenderQuality
    let specs: [TileSpec]
    let submittedAt: ContinuousClock.Instant

    func mergingPending(_ earlier: ViewportRenderRequest) -> ViewportRenderRequest {
        guard contentToken == earlier.contentToken,
              quality == earlier.quality,
              specs.first?.key.level == earlier.specs.first?.key.level else { return self }
        var merged = Dictionary(uniqueKeysWithValues: earlier.specs.map { ($0.key, $0) })
        for spec in specs { merged[spec.key] = spec }
        return ViewportRenderRequest(generation: generation, contentToken: contentToken,
                                     snapshot: snapshot, quality: quality,
                                     specs: Array(merged.values), submittedAt: submittedAt)
    }
}

nonisolated struct RenderedTile: @unchecked Sendable {
    let spec: TileSpec
    let image: CGImage
}

nonisolated struct TileBatch: @unchecked Sendable {
    let generation: UInt64
    let contentToken: UInt64
    let quality: RenderQuality
    let tiles: [RenderedTile]
    let submittedAt: ContinuousClock.Instant
    let requestedSpecs: [TileSpec]

    init(generation: UInt64, contentToken: UInt64, quality: RenderQuality,
         tiles: [RenderedTile], submittedAt: ContinuousClock.Instant,
         requestedSpecs: [TileSpec]? = nil) {
        self.generation = generation
        self.contentToken = contentToken
        self.quality = quality
        self.tiles = tiles
        self.submittedAt = submittedAt
        self.requestedSpecs = requestedSpecs ?? tiles.map(\.spec)
    }
}

nonisolated struct ViewportRenderMetrics: Equatable {
    var requested = 0
    var coalesced = 0
    var completed = 0
    var discarded = 0
    var presented = 0
    var lastPresentationLatency: Duration = .zero
}

/// One active render and one newest pending render. Finishing work is allowed
/// to present even when something newer is pending, which prevents starvation
/// during continuous pointer input.
@MainActor
final class ViewportRenderScheduler {
    typealias Renderer = @Sendable (ViewportRenderRequest) async -> TileBatch

    var onBatch: ((TileBatch) -> Void)?
    private let renderer: Renderer
    private var activeTask: Task<Void, Never>?
    private var pending: ViewportRenderRequest?
    var metrics = ViewportRenderMetrics()

    init(renderer: @escaping Renderer = TileRasterizer.renderBatch) {
        self.renderer = renderer
    }

    func submit(_ request: ViewportRenderRequest) {
        guard !request.specs.isEmpty else { return }
        metrics.requested += 1
        guard activeTask == nil else {
            pending = pending.map { request.mergingPending($0) } ?? request
            metrics.coalesced += 1
            return
        }
        start(request)
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        pending = nil
    }

    private func start(_ request: ViewportRenderRequest) {
        let renderer = renderer
        activeTask = Task { [weak self] in
            let batch = await renderer(request)
            guard let self, !Task.isCancelled else { return }
            metrics.completed += 1
            onBatch?(batch)
            activeTask = nil
            if let next = pending {
                pending = nil
                start(next)
            }
        }
    }
}

nonisolated enum TileRasterizer {
    static func renderBatch(_ request: ViewportRenderRequest) async -> TileBatch {
        let tiles = await withTaskGroup(of: RenderedTile?.self, returning: [RenderedTile].self) { group in
            var iterator = request.specs.makeIterator()
            var output: [RenderedTile] = []
            let parallelism = min(3, request.specs.count)
            for _ in 0..<parallelism {
                if let spec = iterator.next() {
                    group.addTask { render(spec: spec, snapshot: request.snapshot) }
                }
            }
            while let result = await group.next() {
                if let result { output.append(result) }
                if !Task.isCancelled, let spec = iterator.next() {
                    group.addTask { render(spec: spec, snapshot: request.snapshot) }
                }
            }
            return output
        }
        return TileBatch(generation: request.generation,
                         contentToken: request.contentToken,
                         quality: request.quality,
                         tiles: tiles,
                         submittedAt: request.submittedAt,
                         requestedSpecs: request.specs)
    }

    static func render(spec: TileSpec, snapshot: ViewportRenderSnapshot) -> RenderedTile? {
        guard !Task.isCancelled else { return nil }
        let width = max(1, Int((spec.renderRect.width * spec.rasterScale).rounded(.up)))
        let height = max(1, Int((spec.renderRect.height * spec.rasterScale).rounded(.up)))
        let settings = ColorSettings(workingSpace: snapshot.workingSpace, bitDepth: .eight)
        guard let context = settings.makeRGBAContext(width: width, height: height) else { return nil }
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: spec.rasterScale, y: spec.rasterScale)
        context.translateBy(x: -spec.renderRect.minX, y: -spec.renderRect.minY)
        PNGExporter.drawCanvas(items: snapshot.items,
                               background: snapshot.background,
                               canvasSize: snapshot.canvasSize,
                               context: context,
                               space: snapshot.workingSpace)
        guard let image = context.makeImage() else { return nil }
        return RenderedTile(spec: spec, image: image)
    }
}

private final class TileImageBox: NSObject {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

@MainActor
final class RetainedTileCache {
    private let cache = NSCache<NSString, TileImageBox>()

    init(limit: Int = 128 * 1024 * 1024) {
        cache.totalCostLimit = limit
    }

    func image(contentToken: UInt64, key: TileKey) -> CGImage? {
        cache.object(forKey: cacheKey(contentToken: contentToken, key: key))?.image
    }

    func insert(_ image: CGImage, contentToken: UInt64, key: TileKey) {
        cache.setObject(TileImageBox(image),
                        forKey: cacheKey(contentToken: contentToken, key: key),
                        cost: image.bytesPerRow * image.height)
    }

    func removeAll() { cache.removeAllObjects() }

    private func cacheKey(contentToken: UInt64, key: TileKey) -> NSString {
        "\(contentToken):\(key.level):\(key.x):\(key.y)" as NSString
    }
}

/// A clipped retained grid. Displayed tile contents are never cleared during
/// rendering; completed batches replace them atomically.
final class RetainedTileCanvasNSView: NSView {
    private struct PendingContent {
        let snapshot: ViewportRenderSnapshot
        let quality: RenderQuality
        let contentToken: UInt64
        var region: RenderInvalidationRegion
    }

    private let canvasLayer = CALayer()
    private var gridLayers: [Int: CALayer] = [:]
    private var tileLayers: [TileKey: CALayer] = [:]
    private var displayedImages: [TileKey: CGImage] = [:]
    private var tileGenerations: [TileKey: UInt64] = [:]
    private var tileContentTokens: [TileKey: UInt64] = [:]
    private var installedSpecs: [TileKey: TileSpec] = [:]
    private var invalidTileKeys: Set<TileKey> = []
    private let tileCache = RetainedTileCache()
    private lazy var scheduler: ViewportRenderScheduler = {
        let scheduler = ViewportRenderScheduler()
        scheduler.onBatch = { [weak self] batch in self?.present(batch) }
        return scheduler
    }()
    private var displayLink: CADisplayLink?
    private var pendingContent: PendingContent?
    private var latestSnapshot: ViewportRenderSnapshot?
    private var latestQuality: RenderQuality = .preview
    private var latestContentToken: UInt64 = 0
    private var nextGeneration: UInt64 = 0
    private var receivedInvalidationRevision: UInt64?
    private var receivedTransientRevision: UInt64?
    private var receivedQuality: RenderQuality?
    private var pendingTransform = CGAffineTransform.identity
    private var appliedTransform = CGAffineTransform.identity
    private var desiredLevel = 0
    private var activeLevel: Int?
    private var lastVisibleKeys: Set<TileKey> = []
    var onPresented: ((RenderQuality) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayers()
    }

    private func configureLayers() {
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = true
        layer?.isGeometryFlipped = true
        canvasLayer.anchorPoint = .zero
        canvasLayer.position = .zero
        canvasLayer.isGeometryFlipped = true
        canvasLayer.actions = ["transform": NSNull(), "position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(canvasLayer)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            displayLink?.invalidate()
            displayLink = nil
            return
        }
        guard displayLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.frame = bounds
        CATransaction.commit()
    }

    func requiresResolvedContent(invalidationRevision: UInt64,
                                 quality: RenderQuality,
                                 transientRevision: UInt64) -> Bool {
        latestSnapshot == nil || receivedInvalidationRevision != invalidationRevision
            || receivedQuality != quality || receivedTransientRevision != transientRevision
    }

    func updateContent(snapshot: ViewportRenderSnapshot,
                       quality: RenderQuality,
                       invalidation: ViewportInvalidation,
                       transientInvalidation: TransientViewportInvalidation) {
        var region = invalidation.region
        if receivedInvalidationRevision == invalidation.revision { region = .none }
        if receivedTransientRevision != transientInvalidation.revision {
            region = union(region, transientInvalidation.region)
        }
        if receivedQuality != nil, receivedQuality != quality { region = .full }
        if latestSnapshot == nil { region = .full }

        let canvasSizeChanged = latestSnapshot?.canvasSize != nil
            && latestSnapshot?.canvasSize != snapshot.canvasSize
        if canvasSizeChanged {
            resetRetainedTiles()
        } else {
            invalidateRetainedTiles(in: region)
        }

        latestContentToken &+= 1
        latestSnapshot = snapshot
        latestQuality = quality
        receivedInvalidationRevision = invalidation.revision
        receivedTransientRevision = transientInvalidation.revision
        receivedQuality = quality
        canvasLayer.bounds = CGRect(origin: .zero, size: snapshot.canvasSize)
        for grid in gridLayers.values { grid.bounds = canvasLayer.bounds }

        let incoming = PendingContent(snapshot: snapshot, quality: quality,
                                      contentToken: latestContentToken, region: region)
        if var pending = pendingContent {
            pending.region = union(pending.region, region)
            pendingContent = PendingContent(snapshot: snapshot, quality: quality,
                                            contentToken: latestContentToken,
                                            region: pending.region)
        } else {
            pendingContent = incoming
        }
    }

    func updateCanvasTransform(_ transform: CGAffineTransform) {
        pendingTransform = transform
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        displayFrame()
    }

    private func displayFrame() {
        applyPendingTransform()
        if let content = pendingContent {
            pendingContent = nil
            submit(content)
        } else {
            submitMissingVisibleTiles()
        }
    }

    private func applyPendingTransform() {
        guard pendingTransform != appliedTransform else { return }
        appliedTransform = pendingTransform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvasLayer.setAffineTransform(appliedTransform)
        CATransaction.commit()

        let nextLevel = level(for: appliedTransform)
        if nextLevel != desiredLevel {
            desiredLevel = nextLevel
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Keep only the current complete grid visible as the fallback.
            // The desired grid remains hidden until all visible tiles exist.
            for (level, grid) in gridLayers { grid.isHidden = level != activeLevel }
            CATransaction.commit()
            if let snapshot = latestSnapshot {
                pendingContent = PendingContent(snapshot: snapshot, quality: latestQuality,
                                                contentToken: latestContentToken, region: .full)
            }
        }
    }

    private func submit(_ content: PendingContent) {
        let specs = visibleSpecs(level: desiredLevel).filter { spec in
            switch content.region {
            case .none: false
            case .full: true
            case .rect(let rect): spec.canvasRect.intersects(rect)
            }
        }
        guard !specs.isEmpty else { return }
        nextGeneration &+= 1
        scheduler.submit(ViewportRenderRequest(generation: nextGeneration,
                                               contentToken: content.contentToken,
                                               snapshot: content.snapshot,
                                               quality: content.quality,
                                               specs: specs,
                                               submittedAt: ContinuousClock().now))
    }

    private func submitMissingVisibleTiles() {
        guard let snapshot = latestSnapshot else { return }
        let specs = visibleSpecs(level: desiredLevel)
        let keys = Set(specs.map(\.key))
        lastVisibleKeys = keys
        // Until the desired LOD has become active, request a complete visible
        // batch even if a stale retained grid for that level already exists.
        // Atomic activation requires every image to share one content token.
        let missing = activeLevel == desiredLevel
            ? specs.filter { tileLayers[$0.key] == nil || invalidTileKeys.contains($0.key) }
            : specs
        guard !missing.isEmpty else { return }
        nextGeneration &+= 1
        scheduler.submit(ViewportRenderRequest(generation: nextGeneration,
                                               contentToken: latestContentToken,
                                               snapshot: snapshot,
                                               quality: latestQuality,
                                               specs: missing,
                                               submittedAt: ContinuousClock().now))
    }

    private func present(_ batch: TileBatch) {
        guard batch.contentToken == latestContentToken,
              batch.quality == latestQuality,
              batch.requestedSpecs.allSatisfy({ $0.key.level == desiredLevel }) else {
            scheduler.metrics.discarded += max(1, batch.tiles.count)
            submitMissingVisibleTiles()
            return
        }
        for tile in batch.tiles {
            tileCache.insert(tile.image, contentToken: batch.contentToken, key: tile.spec.key)
        }

        let missingRequested = batch.requestedSpecs.filter {
            tileCache.image(contentToken: batch.contentToken, key: $0.key) == nil
        }
        guard missingRequested.isEmpty else {
            submit(specs: missingRequested, snapshot: latestSnapshot,
                   quality: latestQuality, contentToken: latestContentToken)
            return
        }

        // A new LOD is exposed only when every currently visible tile exists.
        if desiredLevel != activeLevel {
            let desired = visibleSpecs(level: desiredLevel)
            guard desired.allSatisfy({ tileCache.image(contentToken: batch.contentToken, key: $0.key) != nil }) else {
                submitMissingVisibleTiles()
                return
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for spec in desired {
                guard let image = tileCache.image(contentToken: batch.contentToken, key: spec.key) else { continue }
                install(image: image, spec: spec, generation: batch.generation,
                        contentToken: batch.contentToken)
            }
            activeLevel = desiredLevel
            for (level, grid) in gridLayers { grid.isHidden = level != activeLevel }
            CATransaction.commit()
        } else {
            guard batch.requestedSpecs.allSatisfy({
                batch.generation >= (tileGenerations[$0.key] ?? 0)
            }) else {
                scheduler.metrics.discarded += batch.requestedSpecs.count
                return
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for spec in batch.requestedSpecs {
                guard let image = tileCache.image(contentToken: batch.contentToken, key: spec.key) else { continue }
                install(image: image, spec: spec, generation: batch.generation,
                        contentToken: batch.contentToken)
            }
            CATransaction.commit()
        }
        scheduler.metrics.presented += 1
        scheduler.metrics.lastPresentationLatency = batch.submittedAt.duration(to: ContinuousClock().now)
        if activeLevel == desiredLevel { onPresented?(batch.quality) }
        submitMissingVisibleTiles()
    }

    private func install(image: CGImage, spec: TileSpec, generation: UInt64,
                         contentToken: UInt64) {
        let tileLayer = tileLayers[spec.key] ?? CALayer()
        tileLayer.anchorPoint = .zero
        tileLayer.position = spec.canvasRect.origin
        tileLayer.bounds = CGRect(origin: .zero, size: spec.canvasRect.size)
        tileLayer.contentsRect = spec.contentsRect
        tileLayer.contentsGravity = .resize
        tileLayer.minificationFilter = .linear
        tileLayer.magnificationFilter = .linear
        tileLayer.actions = ["contents": NSNull(), "contentsRect": NSNull(),
                             "position": NSNull(), "bounds": NSNull()]
        tileLayer.contents = image
        if tileLayer.superlayer == nil { gridLayer(for: spec.key.level).addSublayer(tileLayer) }
        tileLayers[spec.key] = tileLayer
        displayedImages[spec.key] = image
        tileGenerations[spec.key] = generation
        tileContentTokens[spec.key] = contentToken
        installedSpecs[spec.key] = spec
        invalidTileKeys.remove(spec.key)
    }

    private func gridLayer(for level: Int) -> CALayer {
        if let grid = gridLayers[level] { return grid }
        let grid = CALayer()
        grid.anchorPoint = .zero
        grid.position = .zero
        grid.bounds = canvasLayer.bounds
        grid.isGeometryFlipped = true
        grid.isHidden = level != activeLevel
        grid.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        // Coarser grids are kept below finer ones while a replacement LOD is
        // assembling, so they fill gaps without obscuring ready detail.
        let insertionIndex = UInt32(gridLayers.keys.filter { $0 < level }.count)
        canvasLayer.insertSublayer(grid, at: insertionIndex)
        gridLayers[level] = grid
        return grid
    }

    private func visibleSpecs(level: Int) -> [TileSpec] {
        guard let snapshot = latestSnapshot,
              appliedTransform.isInvertible, bounds.width > 0, bounds.height > 0 else { return [] }
        let canvas = CGRect(origin: .zero, size: snapshot.canvasSize)
        let visible = bounds.applying(appliedTransform.inverted()).intersection(canvas)
        guard !visible.isNull, !visible.isEmpty else { return [] }
        let rasterScale = pow(2, CGFloat(level))
        let tileSpan = 512 / rasterScale
        let minX = max(0, Int(floor(visible.minX / tileSpan)))
        let maxX = max(minX, Int(floor((visible.maxX - 0.0001) / tileSpan)))
        let minY = max(0, Int(floor(visible.minY / tileSpan)))
        let maxY = max(minY, Int(floor((visible.maxY - 0.0001) / tileSpan)))
        var specs: [TileSpec] = []
        for y in minY...maxY {
            for x in minX...maxX {
                let rect = CGRect(x: CGFloat(x) * tileSpan, y: CGFloat(y) * tileSpan,
                                  width: tileSpan, height: tileSpan).intersection(canvas)
                let gutter = 2 / rasterScale
                let renderRect = rect.insetBy(dx: -gutter, dy: -gutter).intersection(canvas)
                specs.append(TileSpec(key: TileKey(level: level, x: x, y: y),
                                      canvasRect: rect, rasterScale: rasterScale,
                                      renderRect: renderRect))
            }
        }
        return specs
    }

    private func level(for transform: CGAffineTransform) -> Int {
        let viewScale = max(hypot(transform.a, transform.b), 0.0001)
        let backing = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return min(max(Int(round(log2(viewScale * backing))), -4), 4)
    }

    private func union(_ lhs: RenderInvalidationRegion,
                       _ rhs: RenderInvalidationRegion) -> RenderInvalidationRegion {
        switch (lhs, rhs) {
        case (.full, _), (_, .full): .full
        case (.none, let other), (let other, .none): other
        case (.rect(let a), .rect(let b)): .rect(a.union(b))
        }
    }

    private func submit(specs: [TileSpec], snapshot: ViewportRenderSnapshot?,
                        quality: RenderQuality, contentToken: UInt64) {
        guard let snapshot, !specs.isEmpty else { return }
        nextGeneration &+= 1
        scheduler.submit(ViewportRenderRequest(generation: nextGeneration,
                                               contentToken: contentToken,
                                               snapshot: snapshot,
                                               quality: quality,
                                               specs: specs,
                                               submittedAt: ContinuousClock().now))
    }

    private func invalidateRetainedTiles(in region: RenderInvalidationRegion) {
        switch region {
        case .none:
            break
        case .full:
            invalidTileKeys.formUnion(tileLayers.keys)
        case .rect(let dirty):
            invalidTileKeys.formUnion(installedSpecs.compactMap {
                $0.value.canvasRect.intersects(dirty) ? $0.key : nil
            })
        }
    }

    private func resetRetainedTiles() {
        scheduler.cancel()
        for layer in tileLayers.values { layer.removeFromSuperlayer() }
        for grid in gridLayers.values { grid.removeFromSuperlayer() }
        gridLayers.removeAll()
        tileLayers.removeAll()
        displayedImages.removeAll()
        tileGenerations.removeAll()
        tileContentTokens.removeAll()
        installedSpecs.removeAll()
        invalidTileKeys.removeAll()
        tileCache.removeAll()
        activeLevel = nil
        lastVisibleKeys.removeAll()
    }

    // Internal test hooks.
    var displayedTileCount: Int { tileLayers.values.filter { $0.contents != nil }.count }
    var currentMetrics: ViewportRenderMetrics { scheduler.metrics }
    var currentAppliedTransform: CGAffineTransform { appliedTransform }
    var currentDesiredLevel: Int { desiredLevel }
    var visibleGridLevels: Set<Int> {
        Set(gridLayers.compactMap { $0.value.isHidden ? nil : $0.key })
    }
    func displayFrameForTesting() { displayFrame() }
    func presentForTesting(_ batch: TileBatch) { present(batch) }
    func displayedImage(for key: TileKey) -> CGImage? { displayedImages[key] }
    func displayedContentToken(for key: TileKey) -> UInt64? { tileContentTokens[key] }
}
