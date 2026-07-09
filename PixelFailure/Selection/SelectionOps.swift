import CoreGraphics
import CoreImage
import SwiftUI

// MARK: - Selection geometry transforms (expand / contract)

@MainActor
enum SelectionTransforms {
    /// Grows (positive) or shrinks (negative) the selection by `pixels`
    /// canvas px: rasterize → Core Image morphology → re-trace the contour.
    static func offset(_ selection: CanvasSelection, by pixels: Double, canvasSize: CGSize) -> CanvasSelection? {
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

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])
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
        guard let layer = model.layer(id: layerID), !layer.isLocked,
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
                                                       color: color) else { return }

        let width = max(1, Int(config.pixelSize.width))
        let height = max(1, Int(config.pixelSize.height))
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.draw(base, in: rect)
        ctx.setBlendMode(blendMode)
        ctx.draw(mask, in: rect)
        guard let result = ctx.makeImage(), let data = PNGExporter.pngData(result) else { return }

        let key = storeImage(data: data, fileExtension: "png")
        update(undoManager, actionName: actionName) { model in
            model.modifyLayer(id: layerID) { layer in
                layer.modifyImage { $0.imageKey = key }
            }
        }
    }

    /// Copies the selected region of an image layer into a new layer
    /// ("layer via copy"): what you see — crop and effects baked in.
    @MainActor
    @discardableResult
    func layerFromSelection(_ selection: CanvasSelection, layerID: UUID,
                            renderStore: RenderStore, undoManager: UndoManager?) -> UUID? {
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
                                                       pixelSize: bufferSize) else { return nil }

        let width = Int(bufferSize.width)
        let height = Int(bufferSize.height)
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
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
        let pad = selection.feather * 2 + 2
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
        let key = storeImage(data: data, fileExtension: "png")
        let newLayer = Layer(name: layer.name + " Selection",
                             transform: LayerTransform(position: canvasCenter,
                                                       scale: layer.transform.scale * naturalSize.width / bufferSize.width,
                                                       rotationDegrees: layer.transform.rotationDegrees,
                                                       flippedHorizontally: layer.transform.flippedHorizontally,
                                                       flippedVertically: layer.transform.flippedVertically),
                             kind: .image(ImageConfig(imageKey: key,
                                                      pixelSize: CGSize(width: bufferRect.width,
                                                                        height: bufferRect.height))))
        update(undoManager, actionName: "Layer from Selection") { model in
            model.layers.append(newLayer)
        }
        return newLayer.id
    }

    /// Converts the selection into the layer's mask (replacing any existing
    /// mask content): white inside, black outside, feather respected.
    @MainActor
    func maskFromSelection(_ selection: CanvasSelection, layerID: UUID,
                           renderStore: RenderStore, undoManager: UndoManager?) {
        guard let layer = model.layer(id: layerID) else { return }
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
