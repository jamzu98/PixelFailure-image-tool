import CoreGraphics
import CoreImage
import SwiftUI

// MARK: - Selection geometry transforms (expand / contract)

@MainActor
enum SelectionTransforms {
    /// Grows (positive) or shrinks (negative) the selection by `pixels`
    /// canvas px: rasterize → Core Image morphology → re-trace the contour.
    static func offset(_ selection: CanvasSelection, by pixels: Double, canvasSize: CGSize) -> CanvasSelection? {
        if let matte = selection.matte {
            guard let grown = matte.morphed(by: pixels) else { return nil }
            return CanvasSelection(matte: grown, feather: selection.feather)
        }
        let maxDim = 1200.0
        let scale = min(1, maxDim / Double(max(canvasSize.width, canvasSize.height)))
        let pixelSize = CGSize(width: max(8, canvasSize.width * scale),
                               height: max(8, canvasSize.height * scale))
        // No y-flip here: we go straight back to a grid, so orientation only
        // needs to be self-consistent.
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        var hard = selection
        hard.feather = 0
        guard let mask = SelectionRasterizer.grayMask(selection: hard,
                                                      transform: transform,
                                                      pixelSize: pixelSize) else { return nil }

        let radius = abs(pixels) * scale
        guard radius >= 0.5 else { return selection }
        let filter = pixels > 0 ? "CIMorphologyMaximum" : "CIMorphologyMinimum"
        let extent = CGRect(origin: .zero, size: pixelSize)
        let processed = CIImage(cgImage: mask)
            .clampedToExtent()
            .applyingFilter(filter, parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)
        guard let output = ciContext.createCGImage(processed, from: extent),
              let (grid, width, height) = ContourTracer.grid(from: output) else { return nil }

        // grayMask draws bottom-up; the grid reads top-down, mirroring the
        // selection vertically. Flip rows back.
        var upright = grid
        for y in 0..<height {
            for x in 0..<width {
                upright[y * width + x] = grid[(height - 1 - y) * width + x]
            }
        }

        let gridScale = CGPoint(x: canvasSize.width / CGFloat(width),
                                y: canvasSize.height / CGFloat(height))
        guard let path = ContourTracer.trace(grid: upright, width: width, height: height, scale: gridScale) else {
            return nil
        }
        let result = CanvasSelection(path: path, feather: selection.feather)
        return result.isEmpty ? nil : result
    }

    private static var ciContext: CIContext { CoreImageContext.shared }
}

// MARK: - Pixel operations on image layers

extension PixelDocument {
    /// Erases the selected region from an image layer's source pixels.
    /// One undo step via the append-only image store.
    @MainActor
    func deletePixels(selection: CanvasSelection, layerID: UUID, renderStore: RenderStore,
                      undoManager: UndoManager?) {
        applyToLayerBuffer(selection: selection, layerID: layerID, renderStore: renderStore,
                           undoManager: undoManager, actionName: "Delete Selection",
                           blendMode: .destinationOut, color: .white)
    }

    /// Fills the selected region with a color (respecting feather).
    @MainActor
    func fillPixels(selection: CanvasSelection, layerID: UUID, color: RGBAColor,
                    renderStore: RenderStore, undoManager: UndoManager?) {
        applyToLayerBuffer(selection: selection, layerID: layerID, renderStore: renderStore,
                           undoManager: undoManager, actionName: "Fill Selection",
                           blendMode: .normal, color: color)
    }

    @MainActor
    private func applyToLayerBuffer(selection: CanvasSelection, layerID: UUID,
                                    renderStore: RenderStore, undoManager: UndoManager?,
                                    actionName: String, blendMode: CGBlendMode, color: RGBAColor) {
        guard let layer = model.layer(id: layerID), !model.isEffectivelyLocked(layerID),
              let config = layer.imageConfig,
              let base = renderStore.originalImage(key: config.imageKey) else { return }
        let naturalSize = renderStore.naturalSize(for: layer, model: model)
        guard let transform = SelectionRasterizer.canvasToContentBuffer(layer: layer,
                                                                        naturalSize: naturalSize,
                                                                        config: config,
                                                                        parentAffine: model.parentAffine(of: layerID)),
              let mask = SelectionRasterizer.colorMask(selection: selection,
                                                       transform: transform,
                                                       pixelSize: config.pixelSize,
                                                       color: color,
                                                       colorSettings: model.colorSettings) else { return }

        let width = max(1, Int(config.pixelSize.width))
        let height = max(1, Int(config.pixelSize.height))
        guard let ctx = model.colorSettings.makeRGBAContext(width: width, height: height) else { return }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.draw(base, in: rect)
        ctx.setBlendMode(blendMode)
        ctx.draw(mask, in: rect)
        guard let result = ctx.makeImage() else { return }

        // Delete and Fill stay synchronous (Cut is copy + delete), but the
        // PNG encode happens in the background; the bitmap is used directly.
        let key = storeImageDeferringEncode(result)
        renderStore.adoptOriginalImage(result, for: key)
        update(undoManager, actionName: actionName) { model in
            model.modifyLayer(id: layerID) { layer in
                layer.recordSourceIfNeeded()
                layer.modifyImage { $0.imageKey = key }
            }
        }
    }

    @MainActor
    func contentAwareFill(selection: CanvasSelection, layerID: UUID,
                          renderStore: RenderStore, undoManager: UndoManager?) {
        guard let layer = model.layer(id: layerID), !model.isEffectivelyLocked(layerID),
              let config = layer.imageConfig,
              let base = renderStore.originalImage(key: config.imageKey),
              let transform = SelectionRasterizer.canvasToContentBuffer(
                layer: layer, naturalSize: renderStore.naturalSize(for: layer, model: model),
                config: config, parentAffine: model.parentAffine(of: layerID)),
              let mask = SelectionRasterizer.grayMask(selection: selection, transform: transform,
                                                       pixelSize: config.pixelSize) else { return }
        let inputs = BakeInputs(base: base, mask: mask)
        bakeLayerInBackground(layerID: layerID, label: "Content-Aware Fill",
                              actionName: "Content-Aware Fill",
                              renderStore: renderStore, undoManager: undoManager) {
            ContentAwareInpainting.fill(inputs.base, mask: inputs.mask)
        }
    }

    /// Selection-based patch/heal. `sourceOffset` is measured in canvas
    /// coordinates from the target selection toward the clean source area.
    @MainActor
    func patchSelection(_ selection: CanvasSelection, layerID: UUID,
                        sourceOffset: CGVector, renderStore: RenderStore,
                        undoManager: UndoManager?) {
        guard let layer = model.layer(id: layerID), !model.isEffectivelyLocked(layerID),
              let config = layer.imageConfig,
              let base = renderStore.originalImage(key: config.imageKey),
              let transform = SelectionRasterizer.canvasToContentBuffer(
                layer: layer, naturalSize: renderStore.naturalSize(for: layer, model: model),
                config: config, parentAffine: model.parentAffine(of: layerID)),
              let mask = SelectionRasterizer.colorMask(selection: selection, transform: transform,
                                                        pixelSize: config.pixelSize,
                                                        colorSettings: model.colorSettings) else { return }
        let width = Int(config.pixelSize.width), height = Int(config.pixelSize.height)
        guard let patch = model.colorSettings.makeRGBAContext(width: width, height: height),
              let output = model.colorSettings.makeRGBAContext(width: width, height: height) else { return }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let scale = config.pixelSize.width / max(renderStore.naturalSize(for: layer, model: model).width, 1)
        patch.translateBy(x: -sourceOffset.dx * scale, y: sourceOffset.dy * scale)
        patch.draw(base, in: rect)
        patch.setBlendMode(.destinationIn); patch.draw(mask, in: rect)
        guard let patchImage = patch.makeImage() else { return }
        output.draw(base, in: rect)
        output.setAlpha(0.82); output.draw(patchImage, in: rect)
        guard let result = output.makeImage(), let data = PNGExporter.pngData(result) else { return }
        let key = storeImage(data: data, fileExtension: "png")
        update(undoManager, actionName: "Patch Selection") { model in
            model.modifyLayer(id: layerID) { layer in
                layer.recordSourceIfNeeded(); layer.modifyImage { $0.imageKey = key }
            }
        }
    }

    /// Largest side Super Resolution will produce. Beyond this a single
    /// layer buffer costs over a gigabyte and stalls every render.
    static let superResolutionMaxDimension = 16_384

    enum SuperResolutionOutcome { case started, tooLarge, unavailable }

    @MainActor
    @discardableResult
    func superResolveLayer(layerID: UUID, renderStore: RenderStore,
                           undoManager: UndoManager?) -> SuperResolutionOutcome {
        guard let layer = model.layer(id: layerID), !model.isEffectivelyLocked(layerID),
              let config = layer.imageConfig,
              let base = renderStore.originalImage(key: config.imageKey) else { return .unavailable }
        guard max(base.width, base.height) * 2 <= Self.superResolutionMaxDimension else { return .tooLarge }
        let inputs = BakeInputs(base: base, mask: nil)
        bakeLayerInBackground(layerID: layerID, label: "Super Resolution",
                              actionName: "Super Resolution 2×",
                              renderStore: renderStore, undoManager: undoManager,
                              work: { ImageUpscaler.upscale2x(inputs.base) },
                              finish: { layer, result in
                                  layer.modifyImage {
                                      $0.pixelSize = CGSize(width: result.width, height: result.height)
                                  }
                                  layer.transform.scale *= 0.5
                              })
        return .started
    }

    /// Copies the selected region of an image layer into a new layer
    /// ("layer via copy"): what you see — crop and effects baked in.
    @MainActor
    @discardableResult
    func layerFromSelection(_ selection: CanvasSelection, layerID: UUID,
                            renderStore: RenderStore, undoManager: UndoManager?) -> UUID? {
        guard var payload = selectionLayerPayload(selection, layerID: layerID,
                                                  renderStore: renderStore) else { return nil }
        let key = storeImage(data: payload.data, fileExtension: "png")
        payload.layer.modifyImage { $0.imageKey = key }
        let newLayer = payload.layer
        update(undoManager, actionName: "Layer from Selection") { model in
            model.layers.append(newLayer)
        }
        return newLayer.id
    }

    /// Clipboard representation of only the selected pixels. The generated
    /// key is self-contained in the transfer and does not mutate this document.
    @MainActor
    func transferPayload(for selection: CanvasSelection, layerID: UUID,
                         renderStore: RenderStore) -> LayerTransfer? {
        guard let payload = selectionLayerPayload(selection, layerID: layerID,
                                                  renderStore: renderStore),
              let key = payload.layer.imageConfig?.imageKey else { return nil }
        return LayerTransfer(layer: payload.layer,
                             images: [key: payload.data],
                             flattenedPNG: payload.data)
    }

    @MainActor
    func copySelection(_ selection: CanvasSelection, layerID: UUID,
                       renderStore: RenderStore) {
        guard let transfer = transferPayload(for: selection, layerID: layerID,
                                             renderStore: renderStore) else { return }
        LayerPasteboard.write(transfer)
    }

    @MainActor
    func cutSelection(_ selection: CanvasSelection, layerID: UUID,
                      renderStore: RenderStore, undoManager: UndoManager?) {
        guard !model.isEffectivelyLocked(layerID),
              let transfer = transferPayload(for: selection, layerID: layerID,
                                             renderStore: renderStore) else { return }
        LayerPasteboard.write(transfer)
        deletePixels(selection: selection, layerID: layerID,
                     renderStore: renderStore, undoManager: undoManager)
    }

    @MainActor
    private func selectionLayerPayload(_ selection: CanvasSelection, layerID: UUID,
                                       renderStore: RenderStore) -> (layer: Layer, data: Data)? {
        guard let layer = model.layer(id: layerID),
              let config = layer.imageConfig,
              let resolved = renderStore.resolvedImage(for: layer, config: config,
                                                       model: model, quality: .full) else { return nil }
        let naturalSize = renderStore.naturalSize(for: layer, model: model)
        let bufferSize = CGSize(width: resolved.width, height: resolved.height)
        guard let transform = SelectionRasterizer.canvasToLocalBuffer(layer: layer,
                                                                      naturalSize: naturalSize,
                                                                      bufferPixelSize: bufferSize,
                                                                      parentAffine: model.parentAffine(of: layerID)),
              let mask = SelectionRasterizer.colorMask(selection: selection,
                                                       transform: transform,
                                                       pixelSize: bufferSize,
                                                       colorSettings: model.colorSettings) else { return nil }

        let width = Int(bufferSize.width)
        let height = Int(bufferSize.height)
        guard let ctx = model.colorSettings.makeRGBAContext(width: width, height: height) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.draw(resolved, in: rect)
        ctx.setBlendMode(.destinationIn)
        ctx.draw(mask, in: rect)
        guard let masked = ctx.makeImage() else { return nil }

        // Crop to the selection's bounds in local buffer space (y-down local
        // → y-up buffer: cropping() addresses top-down, so re-flip the rect).
        let affine = layer.transform.affine(naturalSize: naturalSize)
            .concatenating(model.parentAffine(of: layerID))
        guard affine.isInvertible else { return nil }
        let localBounds = selection.bounds.applying(affine.inverted())
        let scale = bufferSize.width / naturalSize.width
        // Soft mattes extend a little past their 50% contour.
        let mattePad = selection.matte.map { 2 * $0.canvasSize.width / CGFloat($0.width) + 2 } ?? 0
        let pad = selection.feather * 2 + 2 + mattePad
        let bufferRect = CGRect(x: (localBounds.minX - pad) * scale,
                                y: (localBounds.minY - pad) * scale,
                                width: (localBounds.width + pad * 2) * scale,
                                height: (localBounds.height + pad * 2) * scale)
            .intersection(rect).integral
        guard bufferRect.width > 1, bufferRect.height > 1,
              let cropped = masked.cropping(to: bufferRect),
              let data = PNGExporter.pngData(cropped) else { return nil }

        // Position the new layer so the copied pixels stay in place.
        let localCenter = CGPoint(x: (bufferRect.midX) / scale, y: (bufferRect.midY) / scale)
        let canvasCenter = localCenter.applying(affine)
        let world = model.worldTransform(of: layerID) ?? layer.transform
        let key = UUID().uuidString + ".png"
        let newLayer = Layer(name: layer.name + " Selection",
                             transform: LayerTransform(position: canvasCenter,
                                                       scale: world.scale * naturalSize.width / bufferSize.width,
                                                       rotationDegrees: world.rotationDegrees,
                                                       flippedHorizontally: world.flippedHorizontally,
                                                       flippedVertically: world.flippedVertically),
                             kind: .image(ImageConfig(imageKey: key,
                                                      pixelSize: CGSize(width: bufferRect.width,
                                                                        height: bufferRect.height))))
        return (newLayer, data)
    }

    /// Converts the selection into the layer's mask (replacing any existing
    /// mask content): white inside, black outside, feather respected.
    @MainActor
    func maskFromSelection(_ selection: CanvasSelection, layerID: UUID,
                           renderStore: RenderStore, undoManager: UndoManager?) {
        guard let layer = model.layer(id: layerID), !model.isEffectivelyLocked(layerID) else { return }
        let naturalSize = renderStore.naturalSize(for: layer, model: model)
        guard naturalSize.width > 0, naturalSize.height > 0 else { return }

        let maxDim = 2048.0
        let scale = min(1, maxDim / Double(max(naturalSize.width, naturalSize.height)))
        let pixelSize = CGSize(width: max(8, (naturalSize.width * scale).rounded()),
                               height: max(8, (naturalSize.height * scale).rounded()))
        guard let transform = SelectionRasterizer.canvasToLocalBuffer(layer: layer,
                                                                      naturalSize: naturalSize,
                                                                      bufferPixelSize: pixelSize,
                                                                      parentAffine: model.parentAffine(of: layerID)),
              let mask = SelectionRasterizer.grayMask(selection: selection,
                                                      transform: transform,
                                                      pixelSize: pixelSize),
              let data = PNGExporter.pngData(mask) else { return }

        let key = storeImage(data: data, fileExtension: "png")
        update(undoManager, actionName: "Mask from Selection") { model in
            model.modifyLayer(id: layerID) { layer in
                layer.mask = LayerMask(imageKey: key, pixelSize: pixelSize,
                                       isEnabled: true,
                                       inverted: layer.mask?.inverted ?? false)
            }
        }
    }
}

// MARK: - Background bakes

/// Immutable bitmaps handed to a background bake.
nonisolated struct BakeInputs: @unchecked Sendable {
    let base: CGImage
    let mask: CGImage!

    init(base: CGImage, mask: CGImage?) {
        self.base = base
        self.mask = mask
    }
}

private nonisolated struct BakeOutput: @unchecked Sendable {
    let image: CGImage
    let png: Data
}

extension PixelDocument {
    /// Runs a destructive pixel operation and its PNG encode off the main
    /// actor, then commits the result as one undo step. The status bar shows
    /// `label` meanwhile. If the layer's pixels changed before the work
    /// finished (another stroke, an undo), the stale result is dropped.
    @MainActor
    func bakeLayerInBackground(layerID: UUID, label: String, actionName: String,
                               renderStore: RenderStore, undoManager: UndoManager?,
                               work: @escaping @Sendable () -> CGImage?,
                               finish: @escaping (inout Layer, CGImage) -> Void = { _, _ in }) {
        guard backgroundTaskLabel == nil,
              let startKey = model.layer(id: layerID)?.imageConfig?.imageKey else { return }
        backgroundTaskLabel = label
        Task { @MainActor [weak self, weak renderStore] in
            let output = await Task.detached(priority: .userInitiated) { () -> BakeOutput? in
                guard let image = work(), let png = PNGExporter.pngData(image) else { return nil }
                return BakeOutput(image: image, png: png)
            }.value
            guard let self else { return }
            self.backgroundTaskLabel = nil
            guard let output,
                  self.model.layer(id: layerID)?.imageConfig?.imageKey == startKey else { return }
            let key = self.storeImage(data: output.png, fileExtension: "png")
            renderStore?.adoptOriginalImage(output.image, for: key)
            self.update(undoManager, actionName: actionName) { model in
                model.modifyLayer(id: layerID) { layer in
                    layer.recordSourceIfNeeded()
                    layer.modifyImage { $0.imageKey = key }
                    finish(&layer, output.image)
                }
            }
        }
    }
}
