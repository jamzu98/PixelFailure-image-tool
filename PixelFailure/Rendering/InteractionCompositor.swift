import CoreGraphics
import Foundation

/// Bitmaps for one direct transform (move / scale / rotate).
///
/// The scene is split, in stacking order, into static runs and the layers
/// being transformed. Each piece is rasterized once, off the main actor, and
/// the viewport shows them as Core Animation layers. Dragging then only
/// changes the moving layers' affine transforms — nothing is re-resolved or
/// re-rasterized per pointer event, which is how Photoshop-class editors keep
/// transforms at display rate regardless of document complexity.
nonisolated final class InteractionSurfaces: @unchecked Sendable {
    struct Surface {
        let image: CGImage
        /// Canvas-space rect the image covers at the moment of capture.
        let canvasRect: CGRect
        /// The transformed layer this bitmap belongs to; nil for static runs.
        let movingID: UUID?
    }

    let key: InteractionSurfaceKey
    let surfaces: [Surface]
    /// Canvas rect covered by the static runs.
    let staticRect: CGRect
    /// Raster pixels per canvas unit of the static runs.
    let staticScale: CGFloat

    init(key: InteractionSurfaceKey, surfaces: [Surface],
         staticRect: CGRect, staticScale: CGFloat) {
        self.key = key
        self.surfaces = surfaces
        self.staticRect = staticRect
        self.staticScale = staticScale
    }

    /// Whether these bitmaps still look right for the current view: they
    /// must cover what is visible, at no less than ~2/3 of screen density.
    func covers(visible: CGRect, scale: CGFloat) -> Bool {
        let tolerance: CGFloat = 1
        let coversRect = staticRect.insetBy(dx: -tolerance, dy: -tolerance).contains(visible)
            || visible.isEmpty
        return coversRect && staticScale >= scale * 0.66
    }
}

nonisolated struct InteractionSurfaceKey: Hashable, Sendable {
    let modelHash: Int
    let movingIDs: Set<UUID>
}

/// A live transform in progress, handed from the canvas to the retained
/// viewport. `deltas` map each moving layer's capture-time canvas geometry
/// to where it is now.
nonisolated struct CanvasInteraction: Equatable {
    let id: UInt64
    let surfaces: InteractionSurfaces
    var deltas: [UUID: CGAffineTransform]
    /// Set on pointer-up once the model holds the final transforms: the
    /// viewport keeps showing the bitmaps until it has received this
    /// invalidation revision and every visible tile is current.
    var committedRevision: UInt64?

    static func == (lhs: CanvasInteraction, rhs: CanvasInteraction) -> Bool {
        lhs.id == rhs.id && lhs.surfaces === rhs.surfaces
            && lhs.deltas == rhs.deltas && lhs.committedRevision == rhs.committedRevision
    }
}

nonisolated enum InteractionCompositor {
    enum Run: @unchecked Sendable {
        case staticItems([RenderItem], background: RGBAColor?)
        case moving(RenderItem, bounds: CGRect)
    }

    /// Per-bitmap pixel budget; ~32 MB at 8-bit RGBA.
    static let pixelBudget: CGFloat = 8_000_000
    static let maxRuns = 6

    /// Splits a resolved top-level scene into independently composited runs,
    /// or returns nil when bitmaps composited source-over could not reproduce
    /// the real result (non-normal blending at or above the first moving
    /// layer, too many interleaved runs).
    static func plan(items: [RenderItem], background: RGBAColor,
                     movingIDs: Set<UUID>,
                     bounds: (UUID) -> CGRect?) -> [Run]? {
        guard !movingIDs.isEmpty else { return nil }
        guard let firstMoving = items.firstIndex(where: { movingIDs.contains($0.id) }) else {
            // Nothing visible is moving (e.g. hidden layers): one flat run.
            return [.staticItems(items, background: background)]
        }
        for item in items[firstMoving...] where item.blendMode != .normal { return nil }

        var runs: [Run] = []
        var pending: [RenderItem] = Array(items[..<firstMoving])
        var pendingHasBackground = true
        for item in items[firstMoving...] {
            if movingIDs.contains(item.id) {
                if pendingHasBackground || !pending.isEmpty {
                    runs.append(.staticItems(pending,
                                             background: pendingHasBackground ? background : nil))
                }
                pending = []
                pendingHasBackground = false
                guard let rect = bounds(item.id), !rect.isNull, !rect.isEmpty else { continue }
                runs.append(.moving(item, bounds: rect))
            } else {
                pending.append(item)
            }
        }
        if !pending.isEmpty { runs.append(.staticItems(pending, background: nil)) }
        return runs.count <= maxRuns ? runs : nil
    }

    /// Canvas rect and pixel density for the static runs: the whole canvas
    /// when it fits the budget at screen density, otherwise the visible area
    /// plus a margin (density reduced only if even that is too large).
    static func staticCoverage(canvasSize: CGSize, visible: CGRect,
                               screenScale: CGFloat) -> (rect: CGRect, scale: CGFloat) {
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let scale = max(screenScale, 0.01)
        if canvas.width * canvas.height * scale * scale <= pixelBudget {
            return (canvas, scale)
        }
        var rect = visible.isEmpty ? canvas : visible
        rect = rect.insetBy(dx: -rect.width * 0.25, dy: -rect.height * 0.25).intersection(canvas)
        if rect.isNull || rect.isEmpty { rect = canvas }
        let area = rect.width * rect.height * scale * scale
        let fitted = area > pixelBudget ? scale * sqrt(pixelBudget / area) : scale
        return (rect, fitted)
    }

    static func render(runs: [Run], key: InteractionSurfaceKey, canvasSize: CGSize,
                       staticRect: CGRect, staticScale: CGFloat,
                       space: WorkingColorSpace) async -> InteractionSurfaces? {
        let canvas = CGRect(origin: .zero, size: canvasSize)
        // Moving content may be dragged in from off-canvas; keep a generous
        // but bounded margin around the canvas.
        let movingLimit = canvas.insetBy(dx: -canvas.width, dy: -canvas.height)
        let rendered = await withTaskGroup(of: (Int, InteractionSurfaces.Surface?).self,
                                           returning: [InteractionSurfaces.Surface?].self) { group in
            for (index, run) in runs.enumerated() {
                group.addTask {
                    guard !Task.isCancelled else { return (index, nil) }
                    switch run {
                    case .staticItems(let items, let background):
                        let surface = rasterize(items: items, background: background,
                                                rect: staticRect, scale: staticScale,
                                                clipTo: canvas, space: space)
                        return (index, surface.map { .init(image: $0.image, canvasRect: $0.rect,
                                                           movingID: nil) })
                    case .moving(let item, let bounds):
                        let rect = bounds.intersection(movingLimit)
                        guard !rect.isNull, !rect.isEmpty else { return (index, nil) }
                        let area = rect.width * rect.height * staticScale * staticScale
                        let scale = area > pixelBudget ? staticScale * sqrt(pixelBudget / area) : staticScale
                        let surface = rasterize(items: [item], background: nil,
                                                rect: rect, scale: scale,
                                                clipTo: nil, space: space)
                        return (index, surface.map { .init(image: $0.image, canvasRect: $0.rect,
                                                           movingID: item.id) })
                    }
                }
            }
            var output = [InteractionSurfaces.Surface?](repeating: nil, count: runs.count)
            for await (index, surface) in group { output[index] = surface }
            return output
        }
        guard !Task.isCancelled else { return nil }
        return InteractionSurfaces(key: key, surfaces: rendered.compactMap { $0 },
                                   staticRect: staticRect, staticScale: staticScale)
    }

    /// Rasterizes items over `rect` in the same orientation as retained tiles.
    /// The returned rect is the exact canvas area the pixel grid covers.
    static func rasterize(items: [RenderItem], background: RGBAColor?,
                          rect: CGRect, scale: CGFloat, clipTo clip: CGRect?,
                          space: WorkingColorSpace) -> (image: CGImage, rect: CGRect)? {
        let width = max(1, Int((rect.width * scale).rounded(.up)))
        let height = max(1, Int((rect.height * scale).rounded(.up)))
        let settings = ColorSettings(workingSpace: space, bitDepth: .eight)
        guard let context = settings.makeRGBAContext(width: width, height: height) else { return nil }
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        if let clip { context.clip(to: clip) }
        if let background {
            context.setFillColor(background.cgColor(in: space))
            context.fill(clip ?? rect)
        }
        PNGExporter.drawItems(items, context: context, space: space)
        guard let image = context.makeImage() else { return nil }
        let covered = CGRect(x: rect.minX, y: rect.minY,
                             width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        return (image, covered)
    }
}
