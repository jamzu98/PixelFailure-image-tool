import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Higher-level, undoable document operations used by the UI.
extension PixelDocument {
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

    /// Stores the image data in the bundle and adds a layer scaled to fit the canvas.
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
            model.layers.removeAll { $0.id == id }
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
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
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
        guard let layer = model.layer(id: layerID), layer.mask == nil else { return }
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
                     quality: RenderQuality = .full) -> CGImage? {
        guard let layer = model.layer(id: id) else { return nil }
        let naturalSize = renderStore.naturalSize(for: layer, model: model)
        guard naturalSize.width > 0, naturalSize.height > 0 else { return nil }

        let bakeScale = min(max(layer.transform.scale, 0.01),
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
                                  targetPixelSize: pixelSize)
    }

    /// Bakes a layer into pixels: vector layers (pattern/text/fill/shape)
    /// render at natural size × scale; image layers bake crop + effects.
    /// Position, rotation, opacity, blend mode, and mask stay live.
    @MainActor
    func rasterizeLayer(id: UUID, renderStore: RenderStore, undoManager: UndoManager?) {
        guard let layer = model.layer(id: id),
              let baked = layerBitmap(id: id, renderStore: renderStore),
              let data = PNGExporter.pngData(baked) else { return }

        let pixelSize = CGSize(width: baked.width, height: baked.height)
        let naturalSize = renderStore.naturalSize(for: layer, model: model)
        let key = storeImage(data: data, fileExtension: "png")
        let newScale = layer.transform.scale * Double(naturalSize.width) / Double(pixelSize.width)
        update(undoManager, actionName: "Rasterize Layer") { model in
            model.modifyLayer(id: id) { layer in
                layer.kind = .image(ImageConfig(imageKey: key, pixelSize: pixelSize))
                layer.transform.scale = newScale
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
        guard !ids.isEmpty else { return nil }
        var newModel = model
        let insertionIndex = newModel.layers.lastIndex { ids.contains($0.id) }
        let removed = newModel.removeLayers(ids: ids)
        guard !removed.isEmpty else { return nil }

        let group = Layer(name: "Group",
                          transform: LayerTransform(position: newModel.canvasCenter),
                          kind: .group(GroupConfig(children: removed)))
        let index = min(insertionIndex ?? newModel.layers.count, newModel.layers.count)
        newModel.layers.insert(group, at: index)

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
                    config.seed = SeededRNG.randomSeed()
                    if randomizeParams {
                        config.params = ParamValues.randomized(specs: config.generator.generator.specs,
                                                               seed: config.seed,
                                                               keeping: config.params)
                    }
                }
            }
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
