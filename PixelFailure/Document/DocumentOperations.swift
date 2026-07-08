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
