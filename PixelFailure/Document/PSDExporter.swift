import CoreGraphics
import Foundation

/// Layered 8-bit RGB PSD writer for the interoperable subset PixelFailure
/// imports: names, opacity, blend modes, visibility, and full-canvas pixels.
/// Vector and smart-object editability remains in the native document.
@MainActor
enum PSDExporter {
    private struct EncodedLayer {
        var layer: Layer
        var planes: [[UInt8]] // R, G, B, A
    }

    static func data(model: ProjectModel, renderStore: RenderStore) -> Data? {
        let width = Int(model.canvasSize.width), height = Int(model.canvasSize.height)
        guard width > 0, height > 0 else { return nil }
        let items = renderStore.renderItems(model: model, quality: .full)
        let layers: [EncodedLayer] = model.layers.reversed().compactMap { layer in
            let item: RenderItem
            if layer.kind.isAdjustment {
                // An adjustment has no pixels of its own; the resolved scene
                // carries it as the adjusted stack below, which reproduces it
                // exactly as a pixel layer. Hidden adjustments are dropped.
                guard let resolved = items.first(where: { $0.id == layer.id }) else { return nil }
                item = resolved
            } else {
                // Pixels are written at full strength; opacity and blend mode
                // live only in the layer record, so they apply exactly once.
                var isolated = model
                var flatLayer = layer
                flatLayer.isVisible = true
                flatLayer.opacity = 1
                flatLayer.blendMode = .normal
                flatLayer.clipsToBelow = false
                isolated.layers = [flatLayer]
                guard let resolved = renderStore.renderItems(model: isolated, quality: .full).first else { return nil }
                item = resolved
            }
            var flat = item
            flat.opacity = 1
            flat.blendMode = .normal
            guard let image = PNGExporter.render(items: [flat], background: .clear,
                                                 canvasSize: model.canvasSize,
                                                 targetPixelSize: model.canvasSize,
                                                 colorSettings: .default),
                  let planes = rgbaPlanes(image) else { return nil }
            return EncodedLayer(layer: layer, planes: planes)
        }
        guard !layers.isEmpty else { return nil }

        var records = Data()
        var channelData = Data()
        for encoded in layers {
            records.i32(0); records.i32(0); records.i32(Int32(height)); records.i32(Int32(width))
            records.u16(4)
            for id: Int16 in [0, 1, 2, -1] {
                records.i16(id); records.u32(UInt32(2 + width * height))
            }
            records.ascii("8BIM"); records.ascii(blendKey(encoded.layer.blendMode))
            records.u8(UInt8(min(255, max(0, Int((encoded.layer.opacity * 255).rounded())))))
            records.u8(encoded.layer.clipsToBelow ? 1 : 0)
            records.u8(encoded.layer.isVisible ? 0 : 2); records.u8(0)
            var extra = Data(); extra.u32(0); extra.u32(0)
            let nameData = encoded.layer.name.data(using: .macOSRoman) ?? Data("Layer".utf8)
            let length = min(nameData.count, 255)
            extra.u8(UInt8(length)); extra.append(nameData.prefix(length))
            while extra.count % 4 != 0 { extra.u8(0) }
            // Unicode name, so names outside Mac Roman survive the round trip.
            let unicode = Array(encoded.layer.name.utf16)
            var luni = Data(); luni.u32(UInt32(unicode.count))
            for unit in unicode { luni.u16(unit) }
            if !luni.count.isMultiple(of: 4) { luni.u16(0) }
            extra.ascii("8BIM"); extra.ascii("luni"); extra.u32(UInt32(luni.count)); extra.append(luni)
            records.u32(UInt32(extra.count)); records.append(extra)
            for plane in encoded.planes { channelData.u16(0); channelData.append(contentsOf: plane) }
        }

        var layerInfo = Data(); layerInfo.i16(Int16(layers.count)); layerInfo.append(records); layerInfo.append(channelData)
        if !layerInfo.count.isMultiple(of: 2) { layerInfo.u8(0) }
        var layerMask = Data(); layerMask.u32(UInt32(layerInfo.count)); layerMask.append(layerInfo); layerMask.u32(0)

        var output = Data(); output.ascii("8BPS"); output.u16(1)
        output.append(contentsOf: [UInt8](repeating: 0, count: 6))
        output.u16(4); output.u32(UInt32(height)); output.u32(UInt32(width)); output.u16(8); output.u16(3)
        output.u32(0); output.u32(0)
        output.u32(UInt32(layerMask.count)); output.append(layerMask)

        // Composite image data, raw planar RGBA.
        guard let composite = PNGExporter.render(items: items, background: model.background,
                                                 canvasSize: model.canvasSize,
                                                 targetPixelSize: model.canvasSize,
                                                 colorSettings: .default),
              let compositePlanes = rgbaPlanes(composite) else { return nil }
        output.u16(0)
        for plane in compositePlanes { output.append(contentsOf: plane) }
        return output
    }

    private static func rgbaPlanes(_ image: CGImage) -> [[UInt8]]? {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &bytes, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Bitmap memory is already top-down, which is PSD's row order; a flip
        // here wrote every layer (and the composite) upside down.
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var planes = [[UInt8](repeating: 0, count: width * height),
                      [UInt8](repeating: 0, count: width * height),
                      [UInt8](repeating: 0, count: width * height),
                      [UInt8](repeating: 0, count: width * height)]
        for pixel in 0..<(width * height) {
            let alpha = Int(bytes[pixel * 4 + 3])
            planes[3][pixel] = UInt8(alpha)
            if alpha > 0 {
                planes[0][pixel] = UInt8(min(255, Int(bytes[pixel * 4]) * 255 / alpha))
                planes[1][pixel] = UInt8(min(255, Int(bytes[pixel * 4 + 1]) * 255 / alpha))
                planes[2][pixel] = UInt8(min(255, Int(bytes[pixel * 4 + 2]) * 255 / alpha))
            }
        }
        return planes
    }

    private static func blendKey(_ mode: LayerBlendMode) -> String {
        switch mode {
        case .normal: "norm"; case .multiply: "mul "; case .screen: "scrn"; case .overlay: "over"
        case .darken: "dark"; case .lighten: "lite"; case .colorDodge: "div "; case .colorBurn: "idiv"
        case .softLight: "sLit"; case .hardLight: "hLit"; case .difference: "diff"; case .exclusion: "smud"
        case .hue: "hue "; case .saturation: "sat "; case .color: "colr"; case .luminosity: "lum "
        }
    }
}

private extension Data {
    mutating func u8(_ value: UInt8) { append(value) }
    mutating func u16(_ value: UInt16) { append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xff)]) }
    mutating func i16(_ value: Int16) { u16(UInt16(bitPattern: value)) }
    mutating func u32(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 0xff),
                            UInt8((value >> 8) & 0xff), UInt8(value & 0xff)])
    }
    mutating func i32(_ value: Int32) { u32(UInt32(bitPattern: value)) }
    mutating func ascii(_ value: String) { append(Data(value.utf8)) }
}
