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
        guard let index = model.layerIndex(id: id) else { return nil }
        var copy = model.layers[index]
        copy.id = UUID()
        copy.name += " Copy"
        copy.transform.position.x += model.canvasSize.width * 0.02
        copy.transform.position.y += model.canvasSize.height * 0.02
        if case .pattern(var config) = copy.kind {
            config.seed = SeededRNG.randomSeed()
            copy.kind = .pattern(config)
        }
        let newID = copy.id
        update(undoManager, actionName: "Duplicate Layer") { model in
            model.layers.insert(copy, at: index + 1)
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

    /// Bakes a layer into pixels: vector layers (pattern/text/fill/shape)
    /// render at natural size × scale; image layers bake crop + effects.
    /// Position, rotation, opacity, blend mode, and mask stay live.
    @MainActor
    func rasterizeLayer(id: UUID, renderStore: RenderStore, undoManager: UndoManager?) {
        guard let layer = model.layer(id: id) else { return }

        let naturalSize = renderStore.naturalSize(for: layer, model: model)
        guard naturalSize.width > 0, naturalSize.height > 0 else { return }

        // Bake at the effective on-canvas resolution, capped for sanity.
        let bakeScale = min(max(layer.transform.scale, 0.01),
                            8192 / Double(max(naturalSize.width, naturalSize.height)))
        let pixelSize = CGSize(width: max(1, (naturalSize.width * bakeScale).rounded()),
                               height: max(1, (naturalSize.height * bakeScale).rounded()))

        // Render just this layer's content, untransformed, into a bitmap.
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

        let items = renderStore.renderItems(model: soloModel, quality: .full)
        guard let baked = PNGExporter.render(items: items,
                                             background: .clear,
                                             canvasSize: naturalSize,
                                             targetPixelSize: pixelSize),
              let data = PNGExporter.pngData(baked) else { return }

        let key = storeImage(data: data, fileExtension: "png")
        let newScale = layer.transform.scale * Double(naturalSize.width) / Double(pixelSize.width)
        update(undoManager, actionName: "Rasterize Layer") { model in
            model.modifyLayer(id: id) { layer in
                layer.kind = .image(ImageConfig(imageKey: key, pixelSize: pixelSize))
                layer.transform.scale = newScale
            }
        }
    }

    // MARK: - Copy / cut / paste

    /// Pasteboard payload for a layer, bundling image bytes for image layers.
    @MainActor
    func transferPayload(for layerID: UUID) -> LayerTransfer? {
        guard let layer = model.layer(id: layerID) else { return nil }
        let data = layer.imageConfig.flatMap { imageData(for: $0.imageKey) }
        return LayerTransfer(layer: layer, imageData: data)
    }

    @MainActor
    func copyLayer(id: UUID) {
        guard let payload = transferPayload(for: id) else { return }
        LayerPasteboard.write(payload)
    }

    @MainActor
    func cutLayer(id: UUID, undoManager: UndoManager?) {
        guard let payload = transferPayload(for: id) else { return }
        LayerPasteboard.write(payload)
        deleteLayer(id: id, undoManager: undoManager)
    }

    /// Pastes a transferred layer on top of the stack; returns the new id.
    @MainActor
    @discardableResult
    func pasteLayer(_ transfer: LayerTransfer, undoManager: UndoManager?) -> UUID {
        var layer = transfer.layer
        layer.id = UUID()
        // Nudge so a paste-in-place is visibly a new layer.
        layer.transform.position.x += model.canvasSize.width * 0.02
        layer.transform.position.y += model.canvasSize.height * 0.02

        if var config = layer.imageConfig {
            // Re-store the image bytes: the key from the source document
            // means nothing here (and pasting within one document is
            // harmless — the store is append-only).
            if let data = transfer.imageData {
                let ext = (config.imageKey as NSString).pathExtension
                config.imageKey = storeImage(data: data, fileExtension: ext.isEmpty ? "png" : ext)
                layer.kind = .image(config)
            } else if imageData(for: config.imageKey) == nil {
                // No bytes and unknown key: drop the paste rather than add a broken layer.
                return layer.id
            }
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

    /// Move a layer within the stack: +1 = one step toward the front,
    /// -1 = one step toward the back, .max/.min = all the way.
    @MainActor
    func reorderLayer(id: UUID, offset: Int, undoManager: UndoManager?) {
        update(undoManager, actionName: "Reorder Layer") { model in
            guard let index = model.layerIndex(id: id) else { return }
            let layer = model.layers.remove(at: index)
            let target = offset == Int.max ? model.layers.count
                : offset == Int.min ? 0
                : min(max(index + offset, 0), model.layers.count)
            model.layers.insert(layer, at: target)
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
