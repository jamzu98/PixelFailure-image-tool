import AppKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Higher-level, undoable document operations used by the UI.
extension PixelDocument {
    nonisolated struct AssetImportOutcome: Sendable {
        var layerID: UUID
        var warning: String?
    }

    @MainActor
    @discardableResult
    func addPatternLayer(_ type: GeneratorType, undoManager: UndoManager?) -> UUID {
        let generator = type.generator
        var config = PatternConfig(generator: type, params: ParamValues(defaults: generator.specs))
        if generator.needsSourceImage {
            config.sourceImageLayerID = model.layers.last(where: { $0.kind.isImage })?.id
        }
        let layer = Layer(name: type.displayName,
                          transform: LayerTransform(position: model.canvasCenter),
                          kind: .pattern(config))
        update(undoManager, actionName: "Add \(type.displayName)") { model in
            model.layers.append(layer)
        }
        return layer.id
    }

    @MainActor
    @discardableResult
    func addTextLayer(undoManager: UndoManager?) -> UUID {
        let layer = Layer(name: "Text",
                          transform: LayerTransform(position: model.canvasCenter),
                          kind: .text(TextConfig()))
        update(undoManager, actionName: "Add Text") { model in
            model.layers.append(layer)
        }
        return layer.id
    }

    @MainActor
    @discardableResult
    func addAdjustmentLayer(undoManager: UndoManager?) -> UUID {
        let layer = Layer(name: "Adjustment",
                          transform: LayerTransform(position: model.canvasCenter),
                          kind: .adjustment(AdjustmentConfig()))
        update(undoManager, actionName: "Add Adjustment Layer") { $0.layers.append(layer) }
        return layer.id
    }

    @MainActor
    @discardableResult
    func addPathLayer(firstPoint: CGPoint? = nil, undoManager: UndoManager?) -> UUID {
        let nodes = firstPoint.map { [BezierNode(anchor: $0)] } ?? []
        let config = PathConfig(size: model.canvasSize, nodes: nodes)
        let layer = Layer(name: "Path", transform: LayerTransform(position: model.canvasCenter),
                          kind: .path(config))
        update(undoManager, actionName: "Add Path") { $0.layers.append(layer) }
        return layer.id
    }

    @MainActor
    func addPathNode(to layerID: UUID, canvasPoint: CGPoint, undoManager: UndoManager?) {
        guard let layer = model.layer(id: layerID), layer.kind.isPath,
              !model.isEffectivelyLocked(layerID) else { return }
        let affine = layer.transform.affine(naturalSize: layer.pathConfig?.size ?? model.canvasSize)
            .concatenating(model.parentAffine(of: layerID))
        guard affine.isInvertible else { return }
        let local = canvasPoint.applying(affine.inverted())
        update(undoManager, actionName: "Add Path Node") { model in
            model.modifyLayer(id: layerID) { layer in
                layer.modifyPath {
                    $0.commands = nil
                    $0.nodes.append(BezierNode(anchor: local))
                }
            }
        }
    }

    enum BooleanPathOperation: String, CaseIterable {
        case union, subtract, intersect
        var displayName: String { rawValue.capitalized }
    }

    @MainActor
    @discardableResult
    func booleanPath(ids: Set<UUID>, operation: BooleanPathOperation,
                     undoManager: UndoManager?) -> UUID? {
        let sources = model.allLayers.filter { ids.contains($0.id) && ($0.kind.isPath || $0.kind.isShape) }
        guard sources.count >= 2 else { return nil }
        let paths: [CGPath] = sources.compactMap { layer in
            let local: Path
            let size: CGSize
            if let config = layer.pathConfig { local = PathGeometry.path(for: config); size = config.size }
            else if let config = layer.shapeConfig { local = ShapeGeometry.path(for: config); size = config.size }
            else { return nil }
            var transform = layer.transform.affine(naturalSize: size)
                .concatenating(model.parentAffine(of: layer.id))
            return local.cgPath.copy(using: &transform)
        }
        guard var result = paths.first else { return nil }
        for path in paths.dropFirst() {
            switch operation {
            case .union: result = result.union(path, using: .evenOdd)
            case .subtract: result = result.subtracting(path, using: .evenOdd)
            case .intersect: result = result.intersection(path, using: .evenOdd)
            }
        }
        let layer = Layer(name: operation.displayName,
                          transform: LayerTransform(position: model.canvasCenter),
                          kind: .path(PathConfig(size: model.canvasSize,
                                                commands: PathGeometry.commands(from: result),
                                                isClosed: true,
                                                fill: model.palette.color(1), stroke: nil)))
        update(undoManager, actionName: "Boolean \(operation.displayName)") { model in
            _ = model.removeLayers(ids: ids)
            model.layers.append(layer)
        }
        return layer.id
    }

    /// Stores the image data in the bundle and adds a layer scaled to fit the canvas.
    @MainActor
    func importAsset(data: Data, fileExtension: String, suggestedName: String,
                     undoManager: UndoManager?) -> AssetImportOutcome? {
        let ext = fileExtension.lowercased()
        if ext == "pdf" {
            guard let image = Self.rasterizeFirstPDFPage(data, colorSettings: model.colorSettings),
                  let png = PNGExporter.pngData(image),
                  let id = addImageLayer(data: png, suggestedName: suggestedName + " — Page 1",
                                         undoManager: undoManager) else { return nil }
            return AssetImportOutcome(layerID: id,
                                      warning: "PDF import rasterized page 1. Additional pages and editable PDF objects are not imported.")
        }
        if ext == "psd", let decoded = try? PSDImporter.decode(data) {
            let offset = CGPoint(x: (model.canvasSize.width - decoded.size.width) / 2,
                                 y: (model.canvasSize.height - decoded.size.height) / 2)
            let children: [Layer] = decoded.layers.reversed().compactMap { imported in
                guard let png = PNGExporter.pngData(imported.image) else { return nil }
                let key = storeImage(data: png, fileExtension: "png")
                return Layer(name: imported.name, opacity: imported.opacity,
                             blendMode: imported.blendMode,
                             transform: LayerTransform(position: CGPoint(
                                x: imported.rect.midX + offset.x,
                                y: imported.rect.midY + offset.y)),
                             kind: .image(ImageConfig(imageKey: key,
                                                      pixelSize: imported.rect.size)))
            }
            guard !children.isEmpty else { return nil }
            let group = Layer(name: suggestedName,
                              transform: LayerTransform(position: model.canvasCenter),
                              kind: .group(GroupConfig(children: children)))
            update(undoManager, actionName: "Import Layered PSD") { $0.layers.append(group) }
            return AssetImportOutcome(
                layerID: group.id,
                warning: "Imported \(children.count) PSD layers with names, positions, opacity, and supported blend modes. Text, smart objects, layer effects, and unsupported PSD metadata are rasterized per layer.")
        }
        let importedName = ext == "psd" ? suggestedName + " — Flattened PSD" : suggestedName
        guard let id = addImageLayer(data: data, suggestedName: importedName,
                                     undoManager: undoManager) else { return nil }
        if ext == "psd" {
            return AssetImportOutcome(layerID: id,
                                      warning: "This PSD uses an unsupported layered construct and was imported through ImageIO as a flattened composite. The layer name records the degradation.")
        }
        if ["dng", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf"].contains(ext) {
            return AssetImportOutcome(layerID: id,
                                      warning: "RAW data was decoded using the system ImageIO pipeline and stored as an editable image layer.")
        }
        return AssetImportOutcome(layerID: id, warning: nil)
    }

    nonisolated private static func rasterizeFirstPDFPage(_ data: Data,
                                                          colorSettings: ColorSettings) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData),
              let pdf = CGPDFDocument(provider), let page = pdf.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        let scale = min(2, 8192 / max(box.width, box.height))
        let width = max(1, Int((box.width * scale).rounded()))
        let height = max(1, Int((box.height * scale).rounded()))
        guard let context = colorSettings.makeRGBAContext(width: width, height: height) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: box.height)
        context.scaleBy(x: 1, y: -1)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    @MainActor
    @discardableResult
    func addImageLayer(data: Data, suggestedName: String, undoManager: UndoManager?) -> UUID? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0 else { return nil }

        let utType = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
        let fileExtension = utType?.preferredFilenameExtension ?? "png"
        let key = storeImage(data: data, fileExtension: fileExtension)

        let pixelSize = CGSize(width: width, height: height)
        let fitScale = min(model.canvasSize.width / pixelSize.width,
                           model.canvasSize.height / pixelSize.height)
        let layer = Layer(name: suggestedName.isEmpty ? "Image" : suggestedName,
                          transform: LayerTransform(position: model.canvasCenter,
                                                    scale: fitScale.isFinite && fitScale > 0 ? fitScale : 1),
                          kind: .image(ImageConfig(imageKey: key, pixelSize: pixelSize)))
        update(undoManager, actionName: "Add Image") { model in
            model.layers.append(layer)
        }
        return layer.id
    }

    @MainActor
    @discardableResult
    func duplicateLayer(id: UUID, undoManager: UndoManager?) -> UUID? {
        guard let original = model.layer(id: id) else { return nil }
        var copy = original.withFreshIDs()
        copy.name += " Copy"
        copy.transform.position.x += model.canvasSize.width * 0.02
        copy.transform.position.y += model.canvasSize.height * 0.02
        if case .pattern(var config) = copy.kind {
            config.seed = SeededRNG.randomSeed()
            copy.kind = .pattern(config)
        }
        let newID = copy.id
        let inserted = copy
        update(undoManager, actionName: "Duplicate Layer") { model in
            model.modifyContainer(of: id) { container in
                guard let index = container.firstIndex(where: { $0.id == id }) else { return }
                container.insert(inserted, at: index + 1)
            }
        }
        return newID
    }

    @MainActor
    func deleteLayer(id: UUID, undoManager: UndoManager?) {
        update(undoManager, actionName: "Delete Layer") { model in
            _ = model.removeLayers(ids: [id])
        }
    }

    @MainActor
    @discardableResult
    func addFillLayer(undoManager: UndoManager?) -> UUID {
        let palette = model.palette.sortedByLuminance
        let colors = [palette.color(0), palette.color(palette.colors.count - 1)]
        let layer = Layer(name: "Gradient",
                          transform: LayerTransform(position: model.canvasCenter),
                          kind: .fill(FillConfig(style: .linearGradient, colors: colors)))
        update(undoManager, actionName: "Add Fill") { model in
            model.layers.append(layer)
        }
        return layer.id
    }

    @MainActor
    @discardableResult
    func addShapeLayer(_ kind: ShapeKind, undoManager: UndoManager?) -> UUID {
        let side = min(model.canvasSize.width, model.canvasSize.height) / 2.5
        var config = ShapeConfig(kind: kind, size: CGSize(width: side, height: side))
        config.fill = model.palette.color(1)
        if kind == .line {
            config.size.height = max(8, side * 0.02)
            config.fill = nil
            config.stroke = model.palette.color(1)
            config.strokeWidth = max(4, Double(side) * 0.03)
        }
        let layer = Layer(name: kind.displayName,
                          transform: LayerTransform(position: model.canvasCenter),
                          kind: .shape(config))
        update(undoManager, actionName: "Add Shape") { model in
            model.layers.append(layer)
        }
        return layer.id
    }

    /// A transparent, canvas-sized image layer ready for brush painting.
    @MainActor
    @discardableResult
    func addPaintLayer(undoManager: UndoManager?) -> UUID? {
        let maxDim = 4096.0
        let scale = min(1, maxDim / max(model.canvasSize.width, model.canvasSize.height))
        let width = max(8, Int(model.canvasSize.width * scale))
        let height = max(8, Int(model.canvasSize.height * scale))
        guard let ctx = model.colorSettings.makeRGBAContext(width: width, height: height),
              let image = ctx.makeImage(),
              let data = PNGExporter.pngData(image) else { return nil }

        let key = storeImage(data: data, fileExtension: "png")
        let pixelSize = CGSize(width: width, height: height)
        let fitScale = model.canvasSize.width / pixelSize.width
        let layer = Layer(name: "Paint",
                          transform: LayerTransform(position: model.canvasCenter, scale: fitScale),
                          kind: .image(ImageConfig(imageKey: key, pixelSize: pixelSize)))
        update(undoManager, actionName: "Add Paint Layer") { model in
            model.layers.append(layer)
        }
        return layer.id
    }

    // MARK: - Masks

    /// Adds a grayscale mask at the layer's content resolution (capped).
    /// Reveal-all = white, hide-all = black.
    @MainActor
    func addMask(to layerID: UUID, hideAll: Bool, renderStore: RenderStore, undoManager: UndoManager?) {
        guard let layer = model.layer(id: layerID), layer.mask == nil,
              !model.isEffectivelyLocked(layerID) else { return }
        let naturalSize = renderStore.naturalSize(for: layer, model: model)
        guard naturalSize.width > 0, naturalSize.height > 0 else { return }

        let maxDim = 2048.0
        let scale = min(1, maxDim / Double(max(naturalSize.width, naturalSize.height)))
        let width = max(8, Int(Double(naturalSize.width) * scale))
        let height = max(8, Int(Double(naturalSize.height) * scale))

        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: hideAll ? 0 : 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage(), let data = PNGExporter.pngData(image) else { return }

        let key = storeImage(data: data, fileExtension: "png")
        let mask = LayerMask(imageKey: key, pixelSize: CGSize(width: width, height: height))
        update(undoManager, actionName: "Add Mask") { model in
            model.modifyLayer(id: layerID) { $0.mask = mask }
        }
    }

    @MainActor
    func deleteMask(from layerID: UUID, undoManager: UndoManager?) {
        guard !model.isEffectivelyLocked(layerID) else { return }
        update(undoManager, actionName: "Delete Mask") { model in
            model.modifyLayer(id: layerID) { $0.mask = nil }
        }
    }

    // MARK: - Rasterize

    /// Renders one layer's content, untransformed, into a bitmap at the
    /// effective on-canvas resolution (capped). Used by rasterize, the
    /// pasteboard's flattened-PNG representation, and layer thumbnails.
    @MainActor
    func layerBitmap(id: UUID, renderStore: RenderStore, maxDimension: Double = 8192,
                     quality: RenderQuality = .full,
                     minimumScale: Double = 0.01) -> CGImage? {
        guard let layer = model.layer(id: id) else { return nil }
        let naturalSize = renderStore.naturalSize(for: layer, model: model)
        guard naturalSize.width > 0, naturalSize.height > 0 else { return nil }

        let bakeScale = min(max(layer.transform.scale, minimumScale),
                            maxDimension / Double(max(naturalSize.width, naturalSize.height)))
        let pixelSize = CGSize(width: max(1, (naturalSize.width * bakeScale).rounded()),
                               height: max(1, (naturalSize.height * bakeScale).rounded()))

        var flat = layer
        flat.isVisible = true
        flat.opacity = 1
        flat.blendMode = .normal
        flat.mask = nil
        flat.transform = LayerTransform(position: CGPoint(x: naturalSize.width / 2,
                                                          y: naturalSize.height / 2))
        var soloModel = model
        soloModel.layers = [flat]
        soloModel.background = .clear
        soloModel.canvasSize = naturalSize

        let items = renderStore.renderItems(model: soloModel, quality: quality)
        return PNGExporter.render(items: items,
                                  background: .clear,
                                  canvasSize: naturalSize,
                                  targetPixelSize: pixelSize,
                                  colorSettings: quality == .full
                                      ? model.colorSettings : model.colorSettings.previewVariant)
    }

    /// Bakes a layer into pixels: vector layers (pattern/text/fill/shape)
    /// render at natural size × scale; image layers bake crop + effects.
    /// Position, rotation, opacity, blend mode, and mask stay live.
    @MainActor
    func rasterizeLayer(id: UUID, renderStore: RenderStore, undoManager: UndoManager?) {
        // Never bake below native resolution: a layer scaled down keeps its
        // full pixel fidelity, so scaling it back up later re-samples the
        // real content, not a shrunken bake.
        guard let layer = model.layer(id: id),
              let baked = layerBitmap(id: id, renderStore: renderStore, minimumScale: 1),
              let data = PNGExporter.pngData(baked) else { return }

        let pixelSize = CGSize(width: baked.width, height: baked.height)
        let naturalSize = renderStore.naturalSize(for: layer, model: model)
        let key = storeImage(data: data, fileExtension: "png")
        let newScale = layer.transform.scale * Double(naturalSize.width) / Double(pixelSize.width)
        update(undoManager, actionName: "Rasterize Layer") { model in
            model.modifyLayer(id: id) { layer in
                layer.recordSourceIfNeeded()
                layer.kind = .image(ImageConfig(imageKey: key, pixelSize: pixelSize))
                layer.transform.scale = newScale
            }
        }
    }

    /// Restores the layer as it was before its pixels were first baked —
    /// the reverse of rasterize/retouch/super-resolution/painting. The
    /// append-only image store still holds the original bytes, so this works
    /// across save/reopen, not just within the undo stack.
    @MainActor
    func revertLayerToSource(id: UUID, undoManager: UndoManager?) {
        guard let layer = model.layer(id: id), let source = layer.source,
              !model.isEffectivelyLocked(id) else { return }
        update(undoManager, actionName: "Revert to Original") { model in
            model.modifyLayer(id: id) { layer in
                layer.kind = source.kind
                layer.transform.scale = source.scale
                layer.source = nil
            }
        }
    }

    // MARK: - Groups

    /// Wraps the given layers in a new group, inserted where the topmost
    /// selected top-level layer was. Children keep their canvas-space
    /// transforms; the group starts with an identity transform, so nothing
    /// moves visually.
    @MainActor
    @discardableResult
    func groupLayers(ids: Set<UUID>, undoManager: UndoManager?) -> UUID? {
        let topmostIDs = ids.filter { id in
            !model.ancestorGroupIDs(of: id).contains(where: ids.contains)
        }
        guard !topmostIDs.isEmpty,
              topmostIDs.allSatisfy({ !model.isEffectivelyLocked($0) }) else { return nil }

        let directParents = Set(topmostIDs.map { model.parentGroupID(of: $0) })
        let sameContainer = directParents.count == 1
        let sharedParent: UUID? = sameContainer ? directParents.first! : nil
        let originalContainer = sameContainer
            ? (model.containerLayers(parentGroupID: sharedParent) ?? []) : []
        let selectedIndices = originalContainer.indices.filter { topmostIDs.contains(originalContainer[$0].id) }
        let insertionIndex: Int
        if let top = selectedIndices.max() {
            insertionIndex = top + 1 - selectedIndices.filter { $0 <= top }.count
        } else {
            insertionIndex = model.layers.count
        }

        let worldTransforms = Dictionary(uniqueKeysWithValues: topmostIDs.compactMap { id in
            model.worldTransform(of: id).map { (id, $0) }
        })
        var newModel = model
        var removed = newModel.removeLayers(ids: Set(topmostIDs))
        guard !removed.isEmpty else { return nil }

        // Cross-container grouping moves the selected roots to a new root
        // group, so rebase each child into canvas space first.
        let destinationParent = sameContainer ? sharedParent : nil
        if !sameContainer {
            for i in removed.indices {
                if let world = worldTransforms[removed[i].id] { removed[i].transform = world }
            }
        }

        let group = Layer(name: "Group",
                          transform: LayerTransform(position: newModel.canvasCenter),
                          kind: .group(GroupConfig(children: removed)))
        let targetIndex = destinationParent == nil && !sameContainer
            ? newModel.layers.count : insertionIndex
        guard newModel.insertLayer(group, into: destinationParent, at: targetIndex) else { return nil }

        update(undoManager, actionName: "Group Layers") { model in
            model = newModel
        }
        return group.id
    }

    /// Splices a group's children back into its container, composing the
    /// group's transform/opacity into each child so nothing moves visually.
    @MainActor
    func ungroup(id: UUID, undoManager: UndoManager?) {
        guard let group = model.layer(id: id), let config = group.groupConfig else { return }
        let canvasSize = model.canvasSize
        let children = config.children.map { child -> Layer in
            var freed = child
            freed.transform = child.transform.composed(withParent: group.transform,
                                                       parentNaturalSize: canvasSize)
            freed.opacity = child.opacity * group.opacity
            return freed
        }
        update(undoManager, actionName: "Ungroup") { model in
            model.modifyContainer(of: id) { container in
                guard let index = container.firstIndex(where: { $0.id == id }) else { return }
                container.replaceSubrange(index...index, with: children)
            }
        }
    }

    // MARK: - Multi-layer operations

    @MainActor
    func deleteLayers(ids: Set<UUID>, undoManager: UndoManager?) {
        guard !ids.isEmpty else { return }
        update(undoManager, actionName: "Delete Layers") { model in
            _ = model.removeLayers(ids: ids)
        }
    }

    /// Moves a layer to a root/group container while preserving its canvas
    /// appearance. `index` is the final bottom-to-top destination index.
    @MainActor
    @discardableResult
    func moveLayer(id: UUID, to parentGroupID: UUID?, at index: Int,
                   undoManager: UndoManager?) -> Bool {
        guard let original = model.layer(id: id),
              !model.isEffectivelyLocked(id),
              parentGroupID != id else { return false }
        if let parentGroupID {
            guard model.layer(id: parentGroupID)?.kind.isGroup == true,
                  !model.isEffectivelyLocked(parentGroupID),
                  !model.ancestorGroupIDs(of: parentGroupID).contains(id) else { return false }
        }
        guard let world = model.worldTransform(of: id) else { return false }

        var next = model
        guard var moved = next.removeLayers(ids: [id]).first else { return false }
        let destinationAffine: CGAffineTransform
        if let parentGroupID,
           let parentWorld = next.worldTransform(of: parentGroupID) {
            destinationAffine = parentWorld.affine(naturalSize: next.canvasSize)
        } else {
            destinationAffine = .identity
        }
        guard let rebased = LayerTransform.rebased(world: world,
                                                   destinationParent: destinationAffine) else { return false }
        moved.transform = rebased
        guard next.insertLayer(moved, into: parentGroupID, at: index) else { return false }
        guard next != model else { return true }
        update(undoManager, actionName: "Move Layer") { $0 = next }
        return original.id == moved.id
    }

    /// Canvas-space bounding box of a layer (through any parent groups).
    @MainActor
    func worldBounds(of layer: Layer, renderStore: RenderStore) -> CGRect {
        let naturalSize = renderStore.naturalSize(for: layer, model: model)
        let parent = model.parentAffine(of: layer.id)
        let corners = layer.transform.corners(naturalSize: naturalSize).map { $0.applying(parent) }
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                      width: (xs.max() ?? 0) - (xs.min() ?? 0),
                      height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    /// Moves a layer by a canvas-space delta, mapped through its parent
    /// group's transform so nested layers move correctly.
    @MainActor
    private func canvasDelta(_ delta: CGVector, intoParentOf id: UUID) -> CGVector {
        let parent = model.parentAffine(of: id)
        guard parent != .identity, parent.isInvertible else { return delta }
        let inverse = parent.inverted()
        // Linear part only (deltas have no translation).
        return CGVector(dx: delta.dx * inverse.a + delta.dy * inverse.c,
                        dy: delta.dx * inverse.b + delta.dy * inverse.d)
    }

    enum AlignEdge: String, CaseIterable {
        case left, centerH, right, top, centerV, bottom

        var displayName: String {
            switch self {
            case .left: "Left"
            case .centerH: "Horizontal Centers"
            case .right: "Right"
            case .top: "Top"
            case .centerV: "Vertical Centers"
            case .bottom: "Bottom"
            }
        }
    }

    /// Aligns layers to each other (2+ selected) or to the canvas (1).
    @MainActor
    func alignLayers(ids: Set<UUID>, edge: AlignEdge, renderStore: RenderStore, undoManager: UndoManager?) {
        let layers = ids.compactMap { model.layer(id: $0) }.filter { !$0.isLocked }
        guard !layers.isEmpty else { return }
        let boundsByID = Dictionary(uniqueKeysWithValues: layers.map {
            ($0.id, worldBounds(of: $0, renderStore: renderStore))
        })
        let reference: CGRect = layers.count > 1
            ? boundsByID.values.reduce(CGRect.null) { $0.union($1) }
            : CGRect(origin: .zero, size: model.canvasSize)

        var deltas: [UUID: CGVector] = [:]
        for layer in layers {
            guard let bounds = boundsByID[layer.id] else { continue }
            var delta = CGVector.zero
            switch edge {
            case .left: delta.dx = reference.minX - bounds.minX
            case .centerH: delta.dx = reference.midX - bounds.midX
            case .right: delta.dx = reference.maxX - bounds.maxX
            case .top: delta.dy = reference.minY - bounds.minY
            case .centerV: delta.dy = reference.midY - bounds.midY
            case .bottom: delta.dy = reference.maxY - bounds.maxY
            }
            deltas[layer.id] = canvasDelta(delta, intoParentOf: layer.id)
        }

        update(undoManager, actionName: "Align Layers") { model in
            for (id, delta) in deltas {
                model.modifyLayer(id: id) { layer in
                    layer.transform.position.x += delta.dx
                    layer.transform.position.y += delta.dy
                }
            }
        }
    }

    /// Distributes 3+ layers so their centers are evenly spaced.
    @MainActor
    func distributeLayers(ids: Set<UUID>, horizontally: Bool, renderStore: RenderStore, undoManager: UndoManager?) {
        let layers = ids.compactMap { model.layer(id: $0) }.filter { !$0.isLocked }
        guard layers.count >= 3 else { return }
        let entries = layers.map { layer -> (id: UUID, center: CGPoint) in
            let bounds = worldBounds(of: layer, renderStore: renderStore)
            return (layer.id, CGPoint(x: bounds.midX, y: bounds.midY))
        }.sorted { horizontally ? $0.center.x < $1.center.x : $0.center.y < $1.center.y }

        guard let first = entries.first, let last = entries.last else { return }
        let span = horizontally ? last.center.x - first.center.x : last.center.y - first.center.y
        let step = span / CGFloat(entries.count - 1)

        var deltas: [UUID: CGVector] = [:]
        for (index, entry) in entries.enumerated() {
            let target = (horizontally ? first.center.x : first.center.y) + step * CGFloat(index)
            let delta = horizontally
                ? CGVector(dx: target - entry.center.x, dy: 0)
                : CGVector(dx: 0, dy: target - entry.center.y)
            deltas[entry.id] = canvasDelta(delta, intoParentOf: entry.id)
        }

        update(undoManager, actionName: "Distribute Layers") { model in
            for (id, delta) in deltas {
                model.modifyLayer(id: id) { layer in
                    layer.transform.position.x += delta.dx
                    layer.transform.position.y += delta.dy
                }
            }
        }
    }

    // MARK: - Flip / lock

    @MainActor
    func flipLayer(id: UUID, horizontally: Bool, undoManager: UndoManager?) {
        guard !model.isEffectivelyLocked(id) else { return }
        update(undoManager, actionName: horizontally ? "Flip Horizontal" : "Flip Vertical") { model in
            model.modifyLayer(id: id) { layer in
                if horizontally {
                    layer.transform.flippedHorizontally.toggle()
                } else {
                    layer.transform.flippedVertically.toggle()
                }
            }
        }
    }

    @MainActor
    func toggleLock(id: UUID, undoManager: UndoManager?) {
        update(undoManager, actionName: "Lock Layer") { model in
            model.modifyLayer(id: id) { $0.isLocked.toggle() }
        }
    }

    // MARK: - Copy / cut / paste

    /// Pasteboard payload for a layer: the model + every image referenced in
    /// its subtree (content and masks) + a flattened PNG for other apps.
    @MainActor
    func transferPayload(for layerID: UUID, renderStore: RenderStore) -> LayerTransfer? {
        guard let layer = model.layer(id: layerID) else { return nil }
        var images: [String: Data] = [:]
        for key in layer.referencedImageKeys {
            if let data = imageData(for: key) {
                images[key] = data
            }
        }
        let png = layerBitmap(id: layerID, renderStore: renderStore, maxDimension: 4096)
            .flatMap { PNGExporter.pngData($0) }
        return LayerTransfer(layer: layer, images: images, flattenedPNG: png)
    }

    @MainActor
    func copyLayer(id: UUID, renderStore: RenderStore) {
        guard let payload = transferPayload(for: id, renderStore: renderStore) else { return }
        LayerPasteboard.write(payload)
    }

    @MainActor
    func cutLayer(id: UUID, renderStore: RenderStore, undoManager: UndoManager?) {
        guard let payload = transferPayload(for: id, renderStore: renderStore) else { return }
        LayerPasteboard.write(payload)
        deleteLayer(id: id, undoManager: undoManager)
    }

    /// Pastes a transferred layer (or group subtree) on top of the stack;
    /// returns the new id.
    @MainActor
    @discardableResult
    func pasteLayer(_ transfer: LayerTransfer, undoManager: UndoManager?) -> UUID {
        var layer = transfer.layer.withFreshIDs()
        // Nudge so a paste-in-place is visibly a new layer.
        layer.transform.position.x += model.canvasSize.width * 0.02
        layer.transform.position.y += model.canvasSize.height * 0.02

        // Re-store every transferred image under new keys and rewrite the
        // subtree's references (source-document keys mean nothing here).
        var keyMap: [String: String] = [:]
        for (oldKey, data) in transfer.images ?? [:] {
            let ext = (oldKey as NSString).pathExtension
            keyMap[oldKey] = storeImage(data: data, fileExtension: ext.isEmpty ? "png" : ext)
        }
        layer.remapImageKeys(keyMap)

        // Drop references to keys we can't resolve (e.g. a bare image layer
        // pasted into a different document with no bytes attached).
        if let config = layer.imageConfig, imageData(for: config.imageKey) == nil {
            return layer.id
        }
        if var config = layer.patternConfig,
           let sourceID = config.sourceImageLayerID,
           model.layer(id: sourceID) == nil {
            config.sourceImageLayerID = nil
            layer.kind = .pattern(config)
        }

        let pasted = layer
        update(undoManager, actionName: "Paste Layer") { model in
            model.layers.append(pasted)
        }
        return pasted.id
    }

    /// Move a layer within its container (root or group): +1 = one step
    /// toward the front, -1 = one step toward the back, .max/.min = ends.
    @MainActor
    func reorderLayer(id: UUID, offset: Int, undoManager: UndoManager?) {
        guard !model.isEffectivelyLocked(id) else { return }
        update(undoManager, actionName: "Reorder Layer") { model in
            model.modifyContainer(of: id) { container in
                guard let index = container.firstIndex(where: { $0.id == id }) else { return }
                let layer = container.remove(at: index)
                let target = offset == Int.max ? container.count
                    : offset == Int.min ? 0
                    : min(max(index + offset, 0), container.count)
                container.insert(layer, at: target)
            }
        }
    }

    /// Reroll a pattern layer's seed; optionally randomize its parameters too.
    @MainActor
    func reroll(layerID: UUID, randomizeParams: Bool, undoManager: UndoManager?) {
        update(undoManager, actionName: randomizeParams ? "Randomize" : "Reroll Seed") { model in
            model.modifyLayer(id: layerID) { layer in
                layer.modifyPattern { config in
                    let seed = SeededRNG.randomSeed()
                    config.seed = seed
                    if randomizeParams {
                        config.params = ParamValues.randomized(specs: config.generator.generator.specs,
                                                               seed: config.seed,
                                                               keeping: config.params)
                    }
                }
            }
        }
    }

    @MainActor
    func applyPatternVariation(seed: UInt64, params: ParamValues,
                               layerID: UUID, undoManager: UndoManager?) {
        update(undoManager, actionName: "Choose Variation") { model in
            model.modifyLayer(id: layerID) { layer in
                layer.modifyPattern { config in
                    config.seed = seed
                    config.params = params
                }
            }
        }
    }

    @MainActor
    func applyAnimationVariation(seed: UInt64, params: ParamValues,
                                 keyframeID: UUID, undoManager: UndoManager?) {
        update(undoManager, actionName: "Choose Keyframe Variation") { model in
            guard let index = model.animation.keyframes.firstIndex(where: { $0.id == keyframeID }) else { return }
            model.animation.keyframes[index].seed = seed
            model.animation.keyframes[index].parameters = params.storage
        }
    }

    @MainActor
    func setPatternMask(on layerID: UUID, generator: GeneratorType,
                        renderStore: RenderStore, undoManager: UndoManager?) {
        guard let layer = model.layer(id: layerID), !model.isEffectivelyLocked(layerID) else { return }
        let natural = renderStore.naturalSize(for: layer, model: model)
        let cap = 2048.0
        let scale = min(1, cap / Double(max(natural.width, natural.height)))
        let pixelSize = CGSize(width: max(8, (natural.width * scale).rounded()),
                               height: max(8, (natural.height * scale).rounded()))
        let config = PatternConfig(generator: generator,
                                   params: ParamValues(defaults: generator.generator.specs))
        update(undoManager, actionName: "Pattern Mask") { model in
            model.modifyLayer(id: layerID) {
                $0.mask = LayerMask(imageKey: "", pixelSize: pixelSize, pattern: config)
            }
        }
    }

    @MainActor
    func rerollPatternMask(on layerID: UUID, undoManager: UndoManager?) {
        guard !model.isEffectivelyLocked(layerID) else { return }
        update(undoManager, actionName: "Reroll Pattern Mask") { model in
            model.modifyLayer(id: layerID) { layer in
                guard var pattern = layer.mask?.pattern else { return }
                pattern.seed = SeededRNG.randomSeed()
                layer.mask?.pattern = pattern
            }
        }
    }

    @MainActor
    func captureAnimationKeyframe(layerID: UUID, time: Double,
                                  undoManager: UndoManager?) {
        let clampedTime = min(max(time, 0), model.animation.duration)
        guard let config = model.model(at: clampedTime).layer(id: layerID)?.patternConfig else { return }
        let keyframe = AnimationKeyframe(time: clampedTime,
                                         layerID: layerID, seed: config.seed,
                                         parameters: config.params.storage)
        update(undoManager, actionName: "Add Keyframe") { model in
            model.animation.keyframes.removeAll {
                $0.layerID == layerID && abs($0.time - keyframe.time) < 0.0001
            }
            model.animation.keyframes.append(keyframe)
            model.animation.keyframes.sort { $0.time < $1.time }
        }
    }

    @MainActor
    func updateAnimationKeyframe(_ id: UUID, seed: UInt64? = nil,
                                 parameter key: String? = nil, value: Double? = nil,
                                 parameters: ParamValues? = nil,
                                 undoManager: UndoManager?, actionName: String) {
        update(undoManager, actionName: actionName) { model in
            guard let index = model.animation.keyframes.firstIndex(where: { $0.id == id }) else { return }
            if let seed { model.animation.keyframes[index].seed = seed }
            if let key, let value { model.animation.keyframes[index].parameters[key] = value }
            if let parameters { model.animation.keyframes[index].parameters = parameters.storage }
        }
    }

    @MainActor
    func removeAnimationKeyframe(_ id: UUID, undoManager: UndoManager?) {
        update(undoManager, actionName: "Delete Keyframe") {
            $0.animation.keyframes.removeAll { $0.id == id }
        }
    }

    /// Crop the canvas to a rectangle (canvas coordinates): the canvas takes
    /// the rect's size and every layer shifts so content stays in place.
    @MainActor
    func cropCanvas(rect: CGRect, undoManager: UndoManager?) {
        let size = CGSize(width: max(16, rect.width.rounded()), height: max(16, rect.height.rounded()))
        update(undoManager, actionName: "Crop Canvas") { model in
            model.canvasSize = size
            for i in model.layers.indices {
                model.layers[i].transform.position.x -= rect.minX
                model.layers[i].transform.position.y -= rect.minY
            }
        }
    }

    /// Resize the canvas, shifting all layers so the composition stays centered.
    @MainActor
    func setCanvasSize(_ size: CGSize, undoManager: UndoManager?) {
        update(undoManager, actionName: "Canvas Size") { model in
            let dx = (size.width - model.canvasSize.width) / 2
            let dy = (size.height - model.canvasSize.height) / 2
            model.canvasSize = size
            for i in model.layers.indices {
                model.layers[i].transform.position.x += dx
                model.layers[i].transform.position.y += dy
            }
        }
    }
}
