import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
@testable import PixelFailure

struct RNGTests {
    @Test func seededRNGIsDeterministic() {
        var a = SeededRNG(seed: 42)
        var b = SeededRNG(seed: 42)
        for _ in 0..<100 {
            #expect(a.next() == b.next())
        }
    }

    @Test func differentSeedsDiverge() {
        var a = SeededRNG(seed: 1)
        var b = SeededRNG(seed: 2)
        let va = (0..<10).map { _ in a.next() }
        let vb = (0..<10).map { _ in b.next() }
        #expect(va != vb)
    }

    @Test func unitStaysInRange() {
        var rng = SeededRNG(seed: 7)
        for _ in 0..<1000 {
            let v = rng.unit()
            #expect(v >= 0 && v < 1)
        }
    }
}

@MainActor
struct GeneratorTests {
    private var context: GeneratorContext {
        GeneratorContext(size: CGSize(width: 1000, height: 1000),
                         palette: BuiltInPalettes.default,
                         sampler: nil)
    }

    @Test func generatorsAreDeterministicForSameSeed() {
        for type in GeneratorType.allCases where type != .sampledGrid {
            let generator = type.generator
            let params = ParamValues(defaults: generator.specs)
            let a = generator.generate(params: params, seed: 99, context: context)
            let b = generator.generate(params: params, seed: 99, context: context)
            #expect(a.count == b.count, "\(type) count differs between runs")
            if let firstA = a.first, let firstB = b.first {
                #expect(firstA.path.description == firstB.path.description,
                        "\(type) geometry differs between runs")
            }
        }
    }

    @Test func generatorsProduceContent() {
        for type in GeneratorType.allCases where type != .sampledGrid {
            let generator = type.generator
            let params = ParamValues(defaults: generator.specs)
            let primitives = generator.generate(params: params, seed: 5, context: context)
            #expect(!primitives.isEmpty, "\(type) produced no primitives")
        }
    }
}

struct SerializationTests {
    @Test func modelRoundTripsThroughJSON() throws {
        var model = ProjectModel.starter()
        model.layers.append(Layer(name: "Text",
                                  transform: LayerTransform(position: CGPoint(x: 10, y: 20), scale: 2, rotationDegrees: 45),
                                  kind: .text(TextConfig(text: "Hello\nWorld"))))
        model.layers.append(Layer(name: "Image",
                                  opacity: 0.5,
                                  blendMode: .multiply,
                                  transform: LayerTransform(position: .zero),
                                  kind: .image(ImageConfig(imageKey: "abc.png",
                                                           pixelSize: CGSize(width: 640, height: 480),
                                                           crop: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
                                                           effects: [Effect(type: .duotone),
                                                                     Effect(type: .sliceGlitch, isEnabled: false)]))))

        let data = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(ProjectModel.self, from: data)
        #expect(decoded == model)
    }
}

@MainActor
struct SVGTests {
    @Test func svgContainsExpectedStructure() {
        let generator = GeneratorType.rings.generator
        let params = ParamValues(defaults: generator.specs)
        let context = GeneratorContext(size: CGSize(width: 500, height: 500),
                                       palette: BuiltInPalettes.default,
                                       sampler: nil)
        let primitives = generator.generate(params: params, seed: 1, context: context)
        let item = RenderItem(id: UUID(),
                              opacity: 0.8,
                              blendMode: .multiply,
                              transform: .identity,
                              naturalSize: CGSize(width: 500, height: 500),
                              content: .primitives(primitives))
        let svg = SVGExporter.svg(items: [item],
                                  background: RGBAColor(hex: "#211E1B"),
                                  canvasSize: CGSize(width: 500, height: 500))

        #expect(svg.contains("<svg"))
        #expect(svg.contains("viewBox=\"0 0 500 500\""))
        #expect(svg.contains("<path d=\"M"))
        #expect(svg.contains("mix-blend-mode:multiply"))
        #expect(svg.contains("opacity=\"0.8\""))
        #expect(svg.hasSuffix("</svg>\n"))
    }
}

@MainActor
struct ExportTests {
    @Test func pngRendersAtExactTargetSize() {
        let generator = GeneratorType.gridLattice.generator
        let params = ParamValues(defaults: generator.specs)
        let canvas = CGSize(width: 400, height: 400)
        let context = GeneratorContext(size: canvas, palette: BuiltInPalettes.default, sampler: nil)
        let primitives = generator.generate(params: params, seed: 3, context: context)
        let item = RenderItem(id: UUID(),
                              opacity: 1,
                              blendMode: .normal,
                              transform: .identity,
                              naturalSize: canvas,
                              content: .primitives(primitives))
        let image = PNGExporter.render(items: [item],
                                       background: .black,
                                       canvasSize: canvas,
                                       targetPixelSize: CGSize(width: 1920, height: 1080))
        #expect(image?.width == 1920)
        #expect(image?.height == 1080)
    }
}

struct PaletteTests {
    @Test func rampInterpolatesEndpoints() {
        let palette = Palette(name: "Test", hex: ["#000000", "#FFFFFF"])
        #expect(palette.ramp(0).luminance < 0.01)
        #expect(palette.ramp(1).luminance > 0.99)
    }

    @Test func extractionFindsDominantColors() throws {
        // Synthesize a half red / half blue image.
        let size = 64
        guard let ctx = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            Issue.record("context creation failed")
            return
        }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size / 2, height: size))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: size / 2, y: 0, width: size / 2, height: size))
        let image = try #require(ctx.makeImage())

        let palette = try #require(PaletteExtractor.extract(from: image, colorCount: 2))
        let hasRed = palette.colors.contains { $0.r > 0.7 && $0.b < 0.3 }
        let hasBlue = palette.colors.contains { $0.b > 0.7 && $0.r < 0.3 }
        #expect(hasRed && hasBlue)
    }
}

// MARK: - Image-editor expansion tests

struct BackCompatTests {
    /// A manifest saved before fill/shape/mask/canvasEffects existed must decode.
    @Test func oldManifestStillDecodes() throws {
        let old = """
        {
          "background": {"a": 1, "b": 0.1, "g": 0.12, "r": 0.13},
          "canvasSize": [1000, 1000],
          "layers": [
            {
              "id": "6F1E0F52-7E4B-4E5A-9B7B-111111111111",
              "isVisible": true,
              "kind": {"pattern": {"_0": {
                "generator": "flowField",
                "params": {"storage": {"curl": 1.2}},
                "seed": 42
              }}},
              "name": "Flow Field",
              "opacity": 1,
              "blendMode": "normal",
              "transform": {"position": [500, 500], "rotationDegrees": 0, "scale": 1}
            }
          ],
          "palette": {"colors": [{"a": 1, "b": 0.2, "g": 0.4, "r": 0.6}], "name": "Test"}
        }
        """
        let model = try JSONDecoder().decode(ProjectModel.self, from: Data(old.utf8))
        #expect(model.layers.count == 1)
        #expect(model.schemaVersion == 1)
        #expect(model.canvasEffects.isEmpty)
        #expect(model.workspace.guides.isEmpty)
        #expect(model.layers[0].mask == nil)
        #expect(model.layers[0].patternConfig?.seed == 42)
    }

    @Test func obsoleteSeedHistoryDecodesButIsNotReencoded() throws {
        let old = """
        {
          "generator": "flowField",
          "seed": 42,
          "params": {"storage": {}},
          "seedHistory": [12, 24, 42],
          "seedHistoryIndex": 2
        }
        """
        let config = try JSONDecoder().decode(PatternConfig.self, from: Data(old.utf8))
        #expect(config.seed == 42)
        let data = try JSONEncoder().encode(config)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["seedHistory"] == nil)
        #expect(object["seedHistoryIndex"] == nil)
    }

    @Test func newFieldsRoundTrip() throws {
        var model = ProjectModel()
        model.canvasEffects = [Effect(type: .grain)]
        model.layers = [
            Layer(name: "Fill", transform: LayerTransform(position: .zero),
                  kind: .fill(FillConfig(style: .radialGradient)),
                  mask: LayerMask(imageKey: "m.png", pixelSize: CGSize(width: 10, height: 10), inverted: true)),
            Layer(name: "Star", transform: LayerTransform(position: .zero),
                  kind: .shape(ShapeConfig(kind: .star, sides: 5))),
        ]
        let data = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(ProjectModel.self, from: data)
        #expect(decoded == model)
    }
}

@MainActor
struct FillShapeSVGTests {
    @Test func gradientFillExportsDefs() {
        let config = FillConfig(style: .linearGradient,
                                colors: [RGBAColor(hex: "#000000"), RGBAColor(hex: "#FFFFFF")],
                                angle: 90)
        let item = RenderItem(id: UUID(), opacity: 1, blendMode: .normal,
                              transform: .identity,
                              naturalSize: CGSize(width: 100, height: 100),
                              content: .fill(config), mask: nil)
        let svg = SVGExporter.svg(items: [item], background: .black,
                                  canvasSize: CGSize(width: 100, height: 100))
        #expect(svg.contains("<linearGradient"))
        #expect(svg.contains("url(#grad"))
    }

    @Test func shapeStaysVector() {
        let config = ShapeConfig(kind: .star, size: CGSize(width: 200, height: 200))
        let primitives = ShapeGeometry.primitives(for: config)
        #expect(primitives.count == 1)
        #expect(primitives[0].fill != nil)
        let item = RenderItem(id: UUID(), opacity: 1, blendMode: .normal,
                              transform: .identity,
                              naturalSize: config.size,
                              content: .primitives(primitives), mask: nil)
        let svg = SVGExporter.svg(items: [item], background: .black,
                                  canvasSize: CGSize(width: 200, height: 200))
        #expect(svg.contains("<path d=\"M"))
        #expect(!svg.contains("<image"))
    }

    @Test func globalEffectsCommentAppears() {
        let svg = SVGExporter.svg(items: [], background: .black,
                                  canvasSize: CGSize(width: 10, height: 10),
                                  skippedGlobalEffects: true)
        #expect(svg.contains("Canvas-level effects"))
    }
}

@MainActor
struct RasterizeTests {
    @Test func rasterizeReplacesVectorWithImage() {
        let document = PixelDocument()
        let store = RenderStore(document: document)
        let layerID = document.model.layers[0].id
        #expect(document.model.layers[0].kind.isPattern)

        document.rasterizeLayer(id: layerID, renderStore: store, undoManager: nil)

        let layer = document.model.layer(id: layerID)
        #expect(layer?.kind.isImage == true)
        // Baked at canvas resolution: natural size matches the canvas.
        #expect(layer?.imageConfig?.pixelSize == document.model.canvasSize)
        #expect(abs((layer?.transform.scale ?? 0) - 1) < 0.001)
        // The baked PNG is retrievable.
        let key = layer?.imageConfig?.imageKey ?? ""
        #expect(document.imageData(for: key) != nil)
    }
}

@MainActor
struct PaintSessionTests {
    @Test func strokeChangesPixels() throws {
        let session = try #require(PaintSession(target: .content(layerID: UUID()),
                                                base: nil,
                                                pixelSize: CGSize(width: 64, height: 64)))
        let before = try #require(session.currentImage?.dataProvider?.data as Data?)
        session.stroke(to: CGPoint(x: 32, y: 32), radius: 16, hardness: 0.8,
                       opacity: 1, color: RGBAColor(hex: "#FF0000"), erase: false)
        let after = try #require(session.currentImage?.dataProvider?.data as Data?)
        #expect(before != after)
    }

    @Test func maskSessionIsGrayscale() throws {
        let session = try #require(PaintSession(target: .mask(layerID: UUID()),
                                                base: nil,
                                                pixelSize: CGSize(width: 32, height: 32)))
        session.stroke(to: CGPoint(x: 16, y: 16), radius: 10, hardness: 1,
                       opacity: 1, color: .white, erase: false)
        let image = try #require(session.currentImage)
        #expect(image.colorSpace?.model == .monochrome)
    }
}

struct PaletteNormalizationTests {
    @Test func normalizedIsAlwaysFiveColors() {
        let seven = Palette(name: "Seven", hex: ["#111111", "#222222", "#333333",
                                                 "#444444", "#555555", "#666666", "#777777"])
        #expect(seven.normalized.colors.count == Palette.swatchCount)

        let two = Palette(name: "Two", hex: ["#000000", "#FFFFFF"])
        let normalized = two.normalized
        #expect(normalized.colors.count == Palette.swatchCount)
        // Endpoints preserved when padding via the ramp.
        #expect(normalized.colors.first?.luminance ?? 1 < 0.01)
        #expect(normalized.colors.last?.luminance ?? 0 > 0.99)

        let five = BuiltInPalettes.default
        #expect(five.normalized == five)
    }
}

// MARK: - Stage 1 (interop) tests

struct ImageEncoderTests {
    private func sampleImage() -> CGImage? {
        guard let ctx = CGContext(data: nil, width: 32, height: 32,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.4, blue: 0.2, alpha: 0.5))
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        return ctx.makeImage()
    }

    @Test func encodesAllFormatsDecodably() throws {
        let image = try #require(sampleImage())
        for format in ImageEncoder.Format.allCases {
            let data = try #require(ImageEncoder.encode(image, format: format, quality: 0.8),
                                    "\(format) failed to encode")
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)
            #expect(decoded != nil, "\(format) failed to decode")
        }
    }

    @Test func jpegHasNoAlpha() throws {
        let image = try #require(sampleImage())
        let data = try #require(ImageEncoder.encode(image, format: .jpeg, quality: 0.9))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.alphaInfo == .none || decoded.alphaInfo == .noneSkipLast
                || decoded.alphaInfo == .noneSkipFirst)
    }
}

struct FlipAndLockTests {
    @Test func transformWithoutFlipKeysDecodesToFalse() throws {
        let json = #"{"position": [10, 20], "scale": 1.5, "rotationDegrees": 30}"#
        let transform = try JSONDecoder().decode(LayerTransform.self, from: Data(json.utf8))
        #expect(!transform.flippedHorizontally)
        #expect(!transform.flippedVertically)
        #expect(transform.scale == 1.5)
    }

    @Test func horizontalFlipMirrorsWithinContentBox() {
        let size = CGSize(width: 100, height: 60)
        var transform = LayerTransform(position: CGPoint(x: 50, y: 30))
        transform.flippedHorizontally = true
        // Local left edge midpoint should land on the right edge.
        let mapped = CGPoint(x: 0, y: 30).applying(transform.affine(naturalSize: size))
        #expect(abs(mapped.x - 100) < 0.001)
        #expect(abs(mapped.y - 30) < 0.001)
    }

    @Test func layerWithoutLockKeyDecodesUnlocked() throws {
        var layer = Layer(name: "L", transform: LayerTransform(position: .zero),
                          kind: .text(TextConfig()))
        layer.isLocked = true
        let data = try JSONEncoder().encode(layer)
        // Round-trip keeps the flag.
        #expect(try JSONDecoder().decode(Layer.self, from: data).isLocked)

        // A pre-lock manifest (key stripped) decodes to unlocked.
        var dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        dict.removeValue(forKey: "isLocked")
        let stripped = try JSONSerialization.data(withJSONObject: dict)
        #expect(try JSONDecoder().decode(Layer.self, from: stripped).isLocked == false)
    }
}

struct LayerTransferEncodingTests {
    /// flattenedPNG is a pasteboard-only representation; it must not bloat
    /// the persisted JSON payload.
    @Test func flattenedPNGIsNotPersisted() throws {
        let transfer = LayerTransfer(layer: Layer(name: "T", transform: LayerTransform(position: .zero),
                                                  kind: .text(TextConfig())),
                                     images: nil,
                                     flattenedPNG: Data([1, 2, 3]))
        let data = try JSONEncoder().encode(transfer)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("flattenedPNG"))
        let decoded = try JSONDecoder().decode(LayerTransfer.self, from: data)
        #expect(decoded.flattenedPNG == nil)
    }
}

// MARK: - Stage 2 (selections) tests

@MainActor
struct SelectionTests {
    @Test func booleanCombineAndInvert() {
        let a = CanvasSelection(path: Path(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let union = a.union(Path(CGRect(x: 50, y: 0, width: 100, height: 100)))
        #expect(abs(union.bounds.width - 150) < 1)

        let subtracted = a.subtracting(Path(CGRect(x: -10, y: -10, width: 200, height: 200)))
        #expect(subtracted.isEmpty)

        let inverted = a.inverted(canvasSize: CGSize(width: 400, height: 400))
        #expect(!inverted.contains(CGPoint(x: 50, y: 50)))
        #expect(inverted.contains(CGPoint(x: 300, y: 300)))
    }

    @Test func grayMaskIsWhiteInsideBlackOutside() throws {
        let selection = CanvasSelection(path: Path(CGRect(x: 0, y: 0, width: 50, height: 100)))
        let mask = try #require(SelectionRasterizer.grayMask(
            selection: selection,
            transform: .identity,
            pixelSize: CGSize(width: 100, height: 100)))
        let sampler = try #require(ImageSampler(cgImage: mask, maxDimension: 100))
        // Left half selected (transform has no flip, but left/right is
        // unaffected by vertical orientation).
        #expect(sampler.luminance(atUnitX: 0.25, y: 0.5) > 0.9)
        #expect(sampler.luminance(atUnitX: 0.75, y: 0.5) < 0.1)
    }

    @Test func contourTracerRoundTripsARectangle() throws {
        let width = 20, height = 20
        var grid = [Bool](repeating: false, count: width * height)
        for y in 5..<15 {
            for x in 3..<12 {
                grid[y * width + x] = true
            }
        }
        let path = try #require(ContourTracer.trace(grid: grid, width: width, height: height,
                                                    scale: CGPoint(x: 10, y: 10)))
        let bounds = path.boundingRect
        #expect(abs(bounds.minX - 30) < 0.01)
        #expect(abs(bounds.minY - 50) < 0.01)
        #expect(abs(bounds.width - 90) < 0.01)
        #expect(abs(bounds.height - 100) < 0.01)
        #expect(path.contains(CGPoint(x: 70, y: 100), eoFill: true))
        #expect(!path.contains(CGPoint(x: 10, y: 10), eoFill: true))
    }

    @Test func magicWandSelectsAContiguousColorRegion() throws {
        // Left half red, right half blue.
        let size = 100
        let ctx = try #require(CGContext(data: nil, width: size, height: size,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size / 2, height: size))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: size / 2, y: 0, width: size / 2, height: size))
        let image = try #require(ctx.makeImage())

        let canvasSize = CGSize(width: 1000, height: 1000)
        let path = try #require(MagicWand.select(at: CGPoint(x: 250, y: 500),
                                                 tolerance: 0.2,
                                                 composite: image,
                                                 canvasSize: canvasSize))
        let bounds = path.boundingRect
        #expect(bounds.width < 520)   // roughly the left half only
        #expect(bounds.height > 950)  // full height
        #expect(path.contains(CGPoint(x: 100, y: 500), eoFill: true))
        #expect(!path.contains(CGPoint(x: 800, y: 500), eoFill: true))
    }

    @Test func expandGrowsAndContractShrinks() throws {
        let selection = CanvasSelection(path: Path(CGRect(x: 400, y: 400, width: 200, height: 200)))
        let canvasSize = CGSize(width: 1000, height: 1000)
        let expanded = try #require(SelectionTransforms.offset(selection, by: 50, canvasSize: canvasSize))
        #expect(expanded.bounds.width > 260)
        let contracted = try #require(SelectionTransforms.offset(selection, by: -50, canvasSize: canvasSize))
        #expect(contracted.bounds.width < 140)
    }
}

@MainActor
struct SelectionPixelOpsTests {
    @Test func deletePixelsClearsSelectedRegion() throws {
        let document = PixelDocument()
        let store = RenderStore(document: document)

        // A solid red 100x100 image layer centered on a 1000x1000 canvas at 2x.
        let ctx = try #require(CGContext(data: nil, width: 100, height: 100,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let red = try #require(ctx.makeImage())
        let png = try #require(PNGExporter.pngData(red))
        let key = document.storeImage(data: png, fileExtension: "png")

        let layer = Layer(name: "Red",
                          transform: LayerTransform(position: CGPoint(x: 500, y: 500), scale: 2),
                          kind: .image(ImageConfig(imageKey: key,
                                                   pixelSize: CGSize(width: 100, height: 100))))
        document.update(nil) { model in
            model.canvasSize = CGSize(width: 1000, height: 1000)
            model.layers = [layer]
        }

        // Select the layer's left half in canvas coords: x 400...500.
        let selection = CanvasSelection(path: Path(CGRect(x: 400, y: 400, width: 100, height: 200)))
        document.deletePixels(selection: selection, layerID: layer.id,
                              renderStore: store, undoManager: nil)

        let newKey = try #require(document.model.layer(id: layer.id)?.imageConfig?.imageKey)
        #expect(newKey != key, "imageKey should change after delete")
        let newData = try #require(document.imageData(for: newKey))
        let source = try #require(CGImageSourceCreateWithData(newData as CFData, nil))
        let result = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let sampler = try #require(ImageSampler(cgImage: result, maxDimension: 100))
        // Left half cleared, right half still red.
        #expect(sampler.color(atUnitX: 0.25, y: 0.5).a < 0.1,
                "left half should be transparent, got \(sampler.color(atUnitX: 0.25, y: 0.5))")
        #expect(sampler.color(atUnitX: 0.75, y: 0.5).a > 0.9,
                "right half should stay opaque")
    }
}

@MainActor
struct SelectionFlippedLayerTests {
    @Test func deletePixelsRespectsFlippedLayers() throws {
        let document = PixelDocument()
        let store = RenderStore(document: document)

        // Left half red, right half green, so we can verify mirroring.
        let ctx = try #require(CGContext(data: nil, width: 100, height: 100,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 50, y: 0, width: 50, height: 100))
        let image = try #require(ctx.makeImage())
        let png = try #require(PNGExporter.pngData(image))
        let key = document.storeImage(data: png, fileExtension: "png")

        var transform = LayerTransform(position: CGPoint(x: 500, y: 500), scale: 2)
        transform.flippedHorizontally = true
        let layer = Layer(name: "Two-tone", transform: transform,
                          kind: .image(ImageConfig(imageKey: key,
                                                   pixelSize: CGSize(width: 100, height: 100))))
        document.update(nil) { model in
            model.canvasSize = CGSize(width: 1000, height: 1000)
            model.layers = [layer]
        }

        // On canvas, the flipped layer shows GREEN on the left (400...500).
        // Deleting the canvas-left half must clear the buffer's RIGHT half.
        let selection = CanvasSelection(path: Path(CGRect(x: 400, y: 400, width: 100, height: 200)))
        document.deletePixels(selection: selection, layerID: layer.id,
                              renderStore: store, undoManager: nil)

        let newKey = try #require(document.model.layer(id: layer.id)?.imageConfig?.imageKey)
        let newData = try #require(document.imageData(for: newKey))
        let source = try #require(CGImageSourceCreateWithData(newData as CFData, nil))
        let result = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let sampler = try #require(ImageSampler(cgImage: result, maxDimension: 100))
        #expect(sampler.color(atUnitX: 0.75, y: 0.5).a < 0.1,
                "buffer right half (canvas left) should be cleared")
        #expect(sampler.color(atUnitX: 0.25, y: 0.5).a > 0.9,
                "buffer left half (canvas right) should stay")
    }
}

// MARK: - Stage 3 (groups & multi-select) tests

@MainActor
struct GroupTests {
    private func starShapeLayer(at position: CGPoint) -> Layer {
        Layer(name: "Star",
              transform: LayerTransform(position: position),
              kind: .shape(ShapeConfig(kind: .star, size: CGSize(width: 100, height: 100),
                                       fill: RGBAColor(hex: "#FF0000"))))
    }

    /// Grouping must not change a single rendered pixel.
    @Test func groupingIsVisuallyLossless() throws {
        let document = PixelDocument()
        let store = RenderStore(document: document)
        let a = starShapeLayer(at: CGPoint(x: 120, y: 150))
        let b = starShapeLayer(at: CGPoint(x: 300, y: 320))
        document.update(nil) { model in
            model.canvasSize = CGSize(width: 400, height: 400)
            model.layers = [a, b]
        }

        func flat() -> Data? {
            let items = store.renderItems(model: document.model, quality: .full)
            return PNGExporter.render(items: items, background: .black,
                                      canvasSize: document.model.canvasSize,
                                      targetPixelSize: CGSize(width: 200, height: 200))
                .flatMap { PNGExporter.pngData($0) }
        }
        let before = try #require(flat())

        let groupID = try #require(document.groupLayers(ids: [a.id, b.id], undoManager: nil))
        #expect(document.model.layers.count == 1)
        #expect(document.model.layer(id: groupID)?.groupConfig?.children.count == 2)
        // Children remain findable through recursion.
        #expect(document.model.layer(id: a.id) != nil)
        let afterGroup = try #require(flat())
        #expect(before == afterGroup, "grouping changed the render")

        // Move + scale the group, then ungroup: children must compose the
        // group transform and the render must stay identical.
        document.update(nil) { model in
            model.modifyLayer(id: groupID) {
                $0.transform.position.x += 40
                $0.transform.scale = 1.5
                $0.transform.rotationDegrees = 30
            }
        }
        let movedGroup = try #require(flat())
        document.ungroup(id: groupID, undoManager: nil)
        #expect(document.model.layers.count == 2)
        #expect(document.model.layer(id: groupID) == nil)
        let afterUngroup = try #require(flat())
        #expect(movedGroup == afterUngroup, "ungrouping changed the render")
    }

    @Test func duplicateOfGroupRegeneratesAllIDs() throws {
        let document = PixelDocument()
        let a = starShapeLayer(at: CGPoint(x: 100, y: 100))
        document.update(nil) { model in
            model.layers = [a]
        }
        let groupID = try #require(document.groupLayers(ids: [a.id], undoManager: nil))
        let copyID = try #require(document.duplicateLayer(id: groupID, undoManager: nil))
        let copy = try #require(document.model.layer(id: copyID))
        let copiedChild = try #require(copy.groupConfig?.children.first)
        #expect(copyID != groupID)
        #expect(copiedChild.id != a.id)
    }

    @Test func parentAffineComposesForNestedLayers() throws {
        let document = PixelDocument()
        let a = starShapeLayer(at: CGPoint(x: 100, y: 100))
        document.update(nil) { model in
            model.canvasSize = CGSize(width: 400, height: 400)
            model.layers = [a]
        }
        let groupID = try #require(document.groupLayers(ids: [a.id], undoManager: nil))
        document.update(nil) { model in
            model.modifyLayer(id: groupID) { $0.transform.position.x += 50 }
        }
        let parent = document.model.parentAffine(of: a.id)
        let world = CGPoint(x: 100, y: 100).applying(parent)
        #expect(abs(world.x - 150) < 0.01)
        #expect(abs(world.y - 100) < 0.01)
    }

    @Test func alignAndDistribute() throws {
        let document = PixelDocument()
        let store = RenderStore(document: document)
        let a = starShapeLayer(at: CGPoint(x: 100, y: 100))
        let b = starShapeLayer(at: CGPoint(x: 250, y: 200))
        let c = starShapeLayer(at: CGPoint(x: 260, y: 350))
        document.update(nil) { model in
            model.canvasSize = CGSize(width: 400, height: 400)
            model.layers = [a, b, c]
        }

        document.alignLayers(ids: [a.id, b.id, c.id], edge: .left, renderStore: store, undoManager: nil)
        let minXs = [a.id, b.id, c.id].map {
            document.worldBounds(of: document.model.layer(id: $0)!, renderStore: store).minX
        }
        #expect(abs(minXs[0] - minXs[1]) < 0.01)
        #expect(abs(minXs[1] - minXs[2]) < 0.01)

        document.distributeLayers(ids: [a.id, b.id, c.id], horizontally: false,
                                  renderStore: store, undoManager: nil)
        let centers = [a.id, b.id, c.id].map {
            document.worldBounds(of: document.model.layer(id: $0)!, renderStore: store).midY
        }.sorted()
        let gap1 = centers[1] - centers[0]
        let gap2 = centers[2] - centers[1]
        #expect(abs(gap1 - gap2) < 0.5)
    }
}

// MARK: - Foundation closeout regression tests

@MainActor
struct FoundationCloseoutTests {
    private func shape(_ name: String, at point: CGPoint) -> Layer {
        Layer(name: name, transform: LayerTransform(position: point),
              kind: .shape(ShapeConfig(kind: .rectangle,
                                       size: CGSize(width: 60, height: 40))))
    }

    @Test func currentManifestWritesSchemaVersion() throws {
        let model = ProjectModel()
        let encoded = try JSONEncoder().encode(model)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == ProjectModel.currentSchemaVersion)
    }

    @Test func nestedDeleteReallyRemovesChild() throws {
        let document = PixelDocument()
        let child = shape("Child", at: CGPoint(x: 80, y: 90))
        let group = Layer(name: "Group",
                          transform: LayerTransform(position: document.model.canvasCenter),
                          kind: .group(GroupConfig(children: [child])))
        document.update(nil) { $0.layers = [group] }

        document.deleteLayer(id: child.id, undoManager: nil)
        #expect(document.model.layer(id: child.id) == nil)
        #expect(document.model.layer(id: group.id)?.groupConfig?.children.isEmpty == true)
    }

    @Test func reparentPreservesRenderingAndRejectsCycles() throws {
        let document = PixelDocument()
        let store = RenderStore(document: document)
        let child = shape("Child", at: CGPoint(x: 90, y: 110))
        var groupTransform = LayerTransform(position: CGPoint(x: 220, y: 180), scale: 1.3,
                                            rotationDegrees: 20)
        groupTransform.flippedHorizontally = true
        let group = Layer(name: "Group", transform: groupTransform,
                          kind: .group(GroupConfig(children: [child])))
        document.update(nil) {
            $0.canvasSize = CGSize(width: 400, height: 400)
            $0.layers = [group]
        }

        #expect(!document.moveLayer(id: group.id, to: child.id, at: 0, undoManager: nil))
        func pixels() throws -> Data {
            let items = store.renderItems(model: document.model, quality: .full)
            let image = try #require(PNGExporter.render(items: items, background: .black,
                                                        canvasSize: document.model.canvasSize,
                                                        targetPixelSize: CGSize(width: 400, height: 400)))
            return try #require(PNGExporter.pngData(image))
        }
        let before = try pixels()
        #expect(document.moveLayer(id: child.id, to: nil, at: 1, undoManager: nil))
        #expect(document.model.parentGroupID(of: child.id) == nil)
        #expect(try pixels() == before)
    }

    @Test func ancestorLockBlocksTransformAndReparent() throws {
        let document = PixelDocument()
        let child = shape("Child", at: CGPoint(x: 100, y: 100))
        let group = Layer(name: "Locked Group", transform: LayerTransform(position: document.model.canvasCenter),
                          kind: .group(GroupConfig(children: [child])), isLocked: true)
        document.update(nil) { $0.layers = [group] }
        let original = try #require(document.model.layer(id: child.id)?.transform)

        document.flipLayer(id: child.id, horizontally: true, undoManager: nil)
        #expect(document.model.layer(id: child.id)?.transform == original)
        #expect(!document.moveLayer(id: child.id, to: nil, at: 0, undoManager: nil))
    }

    @Test func selectionTransferContainsOnlyCroppedPixelsAndDoesNotMutateStore() throws {
        let document = PixelDocument()
        let store = RenderStore(document: document)
        let ctx = try #require(CGContext(data: nil, width: 100, height: 100,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let png = try #require(ctx.makeImage().flatMap(PNGExporter.pngData))
        let key = document.storeImage(data: png, fileExtension: "png")
        let layer = Layer(name: "Pixels", transform: LayerTransform(position: CGPoint(x: 50, y: 50)),
                          kind: .image(ImageConfig(imageKey: key,
                                                   pixelSize: CGSize(width: 100, height: 100))))
        document.update(nil) {
            $0.canvasSize = CGSize(width: 100, height: 100)
            $0.layers = [layer]
        }
        let selection = CanvasSelection(path: Path(CGRect(x: 0, y: 0, width: 50, height: 100)))
        let beforeKeys = Set(document.images.keys)
        let transfer = try #require(document.transferPayload(for: selection, layerID: layer.id,
                                                              renderStore: store))
        #expect(Set(document.images.keys) == beforeKeys)
        #expect(transfer.images?.count == 1)
        #expect(transfer.layer.imageConfig?.pixelSize.width ?? 100 < 60)
        #expect(transfer.flattenedPNG != nil)
    }
}

@MainActor
struct CoreAdjustmentTests {
    @Test func paramArraysAreBackwardCompatible() throws {
        let legacy = Data(#"{"storage":{"exposure":1.25}}"#.utf8)
        var values = try JSONDecoder().decode(ParamValues.self, from: legacy)
        #expect(values.double("exposure") == 1.25)
        #expect(values.array("points").isEmpty)
        values.setArray("points", [0, 0, 1, 1])
        let roundTrip = try JSONDecoder().decode(ParamValues.self,
                                                 from: JSONEncoder().encode(values))
        #expect(roundTrip.array("points") == [0, 0, 1, 1])
    }

    @Test func coreAdjustmentsRenderAtInputSize() throws {
        let width = 32, height = 32
        let context = try #require(CGContext(data: nil, width: width, height: height,
                                             bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let colors = [CGColor(gray: 0.15, alpha: 1), CGColor(gray: 0.85, alpha: 1)] as CFArray
        let gradient = try #require(CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                               colors: colors, locations: [0, 1]))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        let input = try #require(context.makeImage())

        var curves = EffectType.curves.defaultParams
        curves.setArray("points", [0, 0.1, 0.25, 0.35, 0.5, 0.65, 0.75, 0.85, 1, 1])
        var levels = EffectType.levels.defaultParams
        levels.set("gamma", 1.4)
        var hsl = EffectType.targetedHSL.defaultParams
        hsl.set("saturation", 1.4)
        let effects = [
            Effect(type: .curves, params: curves),
            Effect(type: .levels, params: levels),
            Effect(type: .targetedHSL, params: hsl),
            Effect(type: .whiteBalance, params: EffectType.whiteBalance.defaultParams),
            Effect(type: .vibrance, params: EffectType.vibrance.defaultParams),
            Effect(type: .shadowsHighlights, params: EffectType.shadowsHighlights.defaultParams),
        ]
        let output = EffectPipeline.shared.apply(effects: effects, to: input,
                                                 palette: BuiltInPalettes.default)
        #expect(output.width == width)
        #expect(output.height == height)
    }
}

@MainActor
struct WorkspaceAndCompositingTests {
    @Test func workspaceSettingsPersist() throws {
        var model = ProjectModel()
        model.workspace.guides = [CanvasGuide(orientation: .vertical, position: 123),
                                  CanvasGuide(orientation: .horizontal, position: 456)]
        model.workspace.grid = GridSettings(isVisible: true, spacing: 64,
                                            subdivisions: 4, snapsToGrid: true)
        model.workspace.showsNavigator = false
        let decoded = try JSONDecoder().decode(ProjectModel.self,
                                                from: JSONEncoder().encode(model))
        #expect(decoded.workspace == model.workspace)
    }

    @Test func adjustmentLayerResolvesAboveExistingStack() throws {
        let document = PixelDocument()
        let store = RenderStore(document: document)
        let base = Layer(name: "Base", transform: LayerTransform(position: CGPoint(x: 50, y: 50)),
                         kind: .fill(FillConfig(style: .solid,
                                               colors: [RGBAColor(hex: "#808080")])))
        var params = EffectType.adjust.defaultParams
        params.set("exposure", 1)
        let adjustment = Layer(name: "Brighten", transform: LayerTransform(position: CGPoint(x: 50, y: 50)),
                               kind: .adjustment(AdjustmentConfig(effects: [Effect(type: .adjust,
                                                                                  params: params)])))
        document.update(nil) {
            $0.canvasSize = CGSize(width: 100, height: 100)
            $0.layers = [base, adjustment]
        }
        let items = store.renderItems(model: document.model, quality: .full)
        #expect(items.count == 2)
        #expect(items.last?.svgWarning != nil)
        let svg = SVGExporter.svg(items: items, background: .clear,
                                  canvasSize: document.model.canvasSize)
        #expect(svg.contains("Adjustment layer rendered as a raster overlay"))
    }

    @Test func clippingUsesAlphaOfSiblingBelow() throws {
        let document = PixelDocument()
        let store = RenderStore(document: document)
        let base = Layer(name: "Base", transform: LayerTransform(position: CGPoint(x: 50, y: 50)),
                         kind: .shape(ShapeConfig(kind: .rectangle,
                                                 size: CGSize(width: 40, height: 40),
                                                 fill: RGBAColor(hex: "#FF0000"))))
        let clipped = Layer(name: "Clipped", transform: LayerTransform(position: CGPoint(x: 50, y: 50)),
                            kind: .fill(FillConfig(style: .solid,
                                                  colors: [RGBAColor(hex: "#00FF00")])),
                            clipsToBelow: true)
        document.update(nil) {
            $0.canvasSize = CGSize(width: 100, height: 100)
            $0.layers = [base, clipped]
        }
        let items = store.renderItems(model: document.model, quality: .full)
        let output = try #require(PNGExporter.render(items: items, background: .clear,
                                                     canvasSize: document.model.canvasSize,
                                                     targetPixelSize: document.model.canvasSize))
        let sampler = try #require(ImageSampler(cgImage: output, maxDimension: 100))
        #expect(sampler.color(atUnitX: 0.5, y: 0.5).a > 0.9)
        #expect(sampler.color(atUnitX: 0.05, y: 0.05).a < 0.1)
    }

    @Test func layerStylesAreRetainedByRasterAndSVGRenderers() {
        let style = LayerStyle(type: .dropShadow, color: RGBAColor(hex: "#000000"),
                               size: 6, opacity: 0.8, offsetX: 4, offsetY: 4)
        let item = RenderItem(id: UUID(), opacity: 1, blendMode: .normal,
                              transform: .identity, naturalSize: CGSize(width: 40, height: 40),
                              content: .fill(FillConfig(style: .solid,
                                                        colors: [RGBAColor(hex: "#FF0000")])),
                              mask: nil, styles: [style])
        let svg = SVGExporter.svg(items: [item], background: .clear,
                                  canvasSize: CGSize(width: 80, height: 80))
        #expect(svg.contains("<filter id=\"style"))
        #expect(svg.contains("<feDropShadow"))
    }
}

@MainActor
struct SignatureFeatureTests {
    @Test func completeVariationAppliesSeedAndParametersTogether() throws {
        let document = PixelDocument()
        let layerID = try #require(document.model.layers.first?.id)
        var params = try #require(document.model.layer(id: layerID)?.patternConfig?.params)
        params.set("curl", 1.75)
        document.applyPatternVariation(seed: 999, params: params,
                                       layerID: layerID, undoManager: nil)
        let config = try #require(document.model.layer(id: layerID)?.patternConfig)
        #expect(config.seed == 999)
        #expect(config.params.double("curl") == 1.75)
    }

    @Test func variationRandomizationIsDeterministicAndPreservesUnsafeParameters() {
        let specs = GeneratorType.flowField.generator.specs
        var existing = ParamValues(defaults: specs)
        existing.set("lineCount", 777)
        let first = ParamValues.randomized(specs: specs, seed: 123, keeping: existing)
        let second = ParamValues.randomized(specs: specs, seed: 123, keeping: existing)
        #expect(first == second)
        #expect(first.int("lineCount") == 777)
        #expect(first.storage != existing.storage)
    }

    @Test func numericSliderValuesClampAndRoundToStep() {
        #expect(NumericSliderValue.normalized(12, range: 0...10, step: nil) == 10)
        #expect(NumericSliderValue.normalized(-2, range: 0...10, step: nil) == 0)
        #expect(NumericSliderValue.normalized(4.6, range: 0...10, step: 1) == 5)
        #expect(NumericSliderValue.normalized(0.24, range: 0...1, step: 0.1) == 0.2)
    }

    @Test func everyPaletteHarmonyProducesFiveValidColors() {
        for harmony in PaletteHarmony.allCases {
            let palette = BuiltInPalettes.default.harmony(harmony)
            #expect(palette.colors.count == Palette.swatchCount)
            #expect(palette.colors.allSatisfy {
                (0...1).contains($0.r) && (0...1).contains($0.g)
                    && (0...1).contains($0.b) && (0...1).contains($0.a)
            })
        }
    }

    @Test func proceduralPatternMaskResolvesWithoutStoredImage() throws {
        let document = PixelDocument()
        let store = RenderStore(document: document)
        let layer = Layer(name: "Masked", transform: LayerTransform(position: CGPoint(x: 100, y: 100)),
                          kind: .shape(ShapeConfig(kind: .rectangle,
                                                  size: CGSize(width: 100, height: 100))))
        document.update(nil) {
            $0.canvasSize = CGSize(width: 200, height: 200)
            $0.layers = [layer]
        }
        document.setPatternMask(on: layer.id, generator: .rings,
                                renderStore: store, undoManager: nil)
        let mask = try #require(document.model.layer(id: layer.id)?.mask)
        #expect(mask.imageKey.isEmpty)
        #expect(mask.pattern?.generator == .rings)
        let item = try #require(store.renderItems(model: document.model, quality: .full).first)
        #expect(item.mask != nil)
    }
}

@MainActor
struct BrushV2Tests {
    private func splitImage() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 32, height: 32,
                                             bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(RGBAColor(hex: "#FF0000").cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 32))
        context.setFillColor(RGBAColor(hex: "#0000FF").cgColor)
        context.fill(CGRect(x: 16, y: 0, width: 16, height: 32))
        return try #require(context.makeImage())
    }

    @Test func builtInBrushPresetsCoverSoftHardScatterAndInk() {
        #expect(BrushPreset.builtIns.count >= 4)
        #expect(BrushPreset.builtIns.contains { $0.scatter > 0 })
        #expect(BrushPreset.builtIns.contains { $0.smoothing > 0.7 })
    }

    @Test func dynamicsStrokeAndEveryRetouchModeProducePixels() throws {
        let base = try splitImage()
        let baseData = try #require(PNGExporter.pngData(base))
        let paint = try #require(PaintSession(target: .content(layerID: UUID()), base: base,
                                              pixelSize: CGSize(width: 32, height: 32)))
        paint.stroke(to: CGPoint(x: 16, y: 16), radius: 7, hardness: 0.5,
                     opacity: 0.8, color: .white, erase: false,
                     spacing: 0.25, smoothing: 0.7, scatter: 0.5,
                     sizeJitter: 0.4, opacityJitter: 0.4)
        #expect(paint.currentImage.flatMap(PNGExporter.pngData) != baseData)

        for mode in [PaintSession.RetouchMode.clone, .heal, .smudge, .dodge, .burn] {
            let session = try #require(PaintSession(target: .content(layerID: UUID()), base: base,
                                                    pixelSize: CGSize(width: 32, height: 32)))
            session.retouch(to: CGPoint(x: 24, y: 16), source: CGPoint(x: 8, y: 16),
                            mode: mode, radius: 6, hardness: 0.5, opacity: 1,
                            spacing: 0.15, smoothing: 0.2)
            if mode == .smudge {
                session.retouch(to: CGPoint(x: 14, y: 16), source: nil,
                                mode: mode, radius: 8, hardness: 0.5, opacity: 1,
                                spacing: 0.15, smoothing: 0.1)
            }
            #expect(session.currentImage.flatMap(PNGExporter.pngData) != baseData,
                    "\(mode) did not alter the buffer")
        }
    }
}

@MainActor
struct TypographyVectorTests {
    @Test func paragraphRangeStylesAndTextPathStayVector() {
        let red = RGBAColor(hex: "#FF0000")
        let blue = RGBAColor(hex: "#0000FF")
        let paragraph = TextConfig(text: "Red blue words wrap inside a paragraph box",
                                   size: 28, color: red,
                                   boxSize: CGSize(width: 180, height: 120),
                                   styleRuns: [TextStyleRun(location: 4, length: 4, color: blue)])
        let boxed = TextOutliner.render(paragraph)
        #expect(boxed.size == CGSize(width: 180, height: 120))
        #expect(boxed.primitives.contains { $0.fill == red })
        let ranged = TextOutliner.render(TextConfig(text: "RedBlue", size: 28, tracking: 0,
                                                    color: red, allCaps: false,
                                                    styleRuns: [TextStyleRun(location: 3, length: 4,
                                                                                   color: blue)]))
        #expect(ranged.primitives.contains { $0.fill == red })
        #expect(ranged.primitives.contains { $0.fill == blue },
                "fills: \(ranged.primitives.map(\.fill))")

        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: 60))
        baseline.addCurve(to: CGPoint(x: 300, y: 60),
                          control1: CGPoint(x: 100, y: 0),
                          control2: CGPoint(x: 200, y: 120))
        let onPath = TextOutliner.render(TextConfig(text: "Text on a curve", size: 24), path: baseline)
        #expect(!onPath.primitives.isEmpty)
        #expect(onPath.primitives.allSatisfy { !$0.path.isEmpty })
    }

    @Test func editablePathRoundTripsAndExportsAsSVGPath() throws {
        let config = PathConfig(size: CGSize(width: 300, height: 200), nodes: [
            BezierNode(anchor: CGPoint(x: 10, y: 100), outControl: CGPoint(x: 80, y: 10)),
            BezierNode(anchor: CGPoint(x: 290, y: 100), inControl: CGPoint(x: 220, y: 190)),
        ], stroke: RGBAColor(hex: "#00FFAA"), strokeWidth: 5)
        let decoded = try JSONDecoder().decode(PathConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded == config)

        let item = RenderItem(id: UUID(), opacity: 1, blendMode: .normal,
                              transform: .identity, naturalSize: config.size,
                              content: .primitives(PathGeometry.primitives(for: config)))
        let svg = SVGExporter.svg(items: [item], background: .clear, canvasSize: config.size)
        #expect(svg.contains("<path d="))
        #expect(!svg.contains("<image"))
    }

    @Test func booleanOperationProducesEditablePathLayer() throws {
        let document = PixelDocument()
        let a = Layer(name: "A", transform: LayerTransform(position: CGPoint(x: 90, y: 100)),
                      kind: .shape(ShapeConfig(kind: .rectangle,
                                               size: CGSize(width: 120, height: 120))))
        let b = Layer(name: "B", transform: LayerTransform(position: CGPoint(x: 150, y: 100)),
                      kind: .shape(ShapeConfig(kind: .ellipse,
                                               size: CGSize(width: 120, height: 120))))
        document.update(nil) {
            $0.canvasSize = CGSize(width: 300, height: 200)
            $0.layers = [a, b]
        }
        let resultID = try #require(document.booleanPath(ids: [a.id, b.id], operation: .union,
                                                         undoManager: nil))
        #expect(document.model.layers.count == 1)
        #expect(document.model.layer(id: resultID)?.kind.isPath == true)
        #expect((document.model.layer(id: resultID)?.pathConfig?.commands?.count ?? 0) > 0)
    }
}

@MainActor
struct PlatformMLPerformanceTests {
    private func layeredPSD() -> Data {
        func u16(_ value: UInt16) -> [UInt8] {
            [UInt8(value >> 8), UInt8(value & 0xff)]
        }
        func u32(_ value: UInt32) -> [UInt8] {
            [UInt8(value >> 24), UInt8((value >> 16) & 0xff),
             UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
        }
        var record = Data()
        for value: UInt32 in [0, 0, 1, 2] { record.append(contentsOf: u32(value)) }
        record.append(contentsOf: u16(4))
        for id: UInt16 in [0, 1, 2, UInt16.max] {
            record.append(contentsOf: u16(id))
            record.append(contentsOf: u32(4))
        }
        record.append(Data("8BIMnorm".utf8))
        record.append(contentsOf: [128, 0, 0, 0])
        var extra = Data()
        extra.append(contentsOf: u32(0))
        extra.append(contentsOf: u32(0))
        extra.append(4)
        extra.append(Data("Test".utf8))
        extra.append(contentsOf: [0, 0, 0])
        record.append(contentsOf: u32(UInt32(extra.count)))
        record.append(extra)
        var layerInfo = Data(u16(1))
        layerInfo.append(record)
        for plane: [UInt8] in [[255, 0], [0, 255], [0, 0], [255, 255]] {
            layerInfo.append(contentsOf: u16(0))
            layerInfo.append(contentsOf: plane)
        }
        var layerMask = Data(u32(UInt32(layerInfo.count)))
        layerMask.append(layerInfo)
        var psd = Data("8BPS".utf8)
        psd.append(contentsOf: u16(1))
        psd.append(contentsOf: [UInt8](repeating: 0, count: 6))
        psd.append(contentsOf: u16(4))
        psd.append(contentsOf: u32(1))
        psd.append(contentsOf: u32(2))
        psd.append(contentsOf: u16(8))
        psd.append(contentsOf: u16(3))
        psd.append(contentsOf: u32(0))
        psd.append(contentsOf: u32(0))
        psd.append(contentsOf: u32(UInt32(layerMask.count)))
        psd.append(layerMask)
        return psd
    }

    private func testImage(width: Int = 64, height: Int = 64) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height,
                                             bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(RGBAColor(hex: "#203040").cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(RGBAColor(hex: "#F08040").cgColor)
        context.fillEllipse(in: CGRect(x: width / 4, y: height / 4,
                                       width: width / 2, height: height / 2))
        return try #require(context.makeImage())
    }

    @Test func pdfRoundTripUsesExplicitFlattenedImportPath() throws {
        let image = try testImage()
        let pdf = try #require(PDFExporter.data(image: image,
                                                pageSize: CGSize(width: 64, height: 64)))
        #expect(pdf.starts(with: Data("%PDF".utf8)))
        let document = PixelDocument()
        let outcome = try #require(document.importAsset(data: pdf, fileExtension: "pdf",
                                                        suggestedName: "Test", undoManager: nil))
        #expect(document.model.layer(id: outcome.layerID)?.kind.isImage == true)
        #expect(outcome.warning?.contains("rasterized page 1") == true)
    }

    @Test func layeredPSDImportsNamesOpacityBlendAndPixels() throws {
        let psd = layeredPSD()
        let decoded = try PSDImporter.decode(psd)
        #expect(decoded.size == CGSize(width: 2, height: 1))
        #expect(decoded.layers.count == 1)
        #expect(decoded.layers[0].name == "Test")
        #expect(abs(decoded.layers[0].opacity - Double(128) / 255) < 0.0001)
        #expect(decoded.layers[0].blendMode == .normal)

        let document = PixelDocument()
        let outcome = try #require(document.importAsset(data: psd, fileExtension: "psd",
                                                        suggestedName: "Layers", undoManager: nil))
        let group = try #require(document.model.layer(id: outcome.layerID)?.groupConfig)
        #expect(group.children.count == 1)
        #expect(group.children[0].name == "Test")
        #expect(outcome.warning?.contains("Imported 1 PSD layers") == true)
    }

    @Test func featureDetectedWebPAndUpscaleEncodeAtExpectedSize() throws {
        let image = try testImage()
        let upscaled = try #require(ImageUpscaler.upscale2x(image))
        #expect(upscaled.width == image.width * 2)
        #expect(upscaled.height == image.height * 2)
        if ImageEncoder.Format.webp.isAvailable {
            #expect(ImageEncoder.encode(image, format: .webp) != nil)
        }
    }

    @Test func contentAwareFillReplacesMaskedPixelsDeterministically() throws {
        let image = try testImage()
        let maskContext = try #require(CGContext(data: nil, width: image.width, height: image.height,
                                                 bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceGray(),
                                                 bitmapInfo: CGImageAlphaInfo.none.rawValue))
        maskContext.setFillColor(CGColor(gray: 0, alpha: 1))
        maskContext.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        maskContext.setFillColor(CGColor(gray: 1, alpha: 1))
        maskContext.fillEllipse(in: CGRect(x: 12, y: 12, width: 40, height: 40))
        let mask = try #require(maskContext.makeImage())
        let a = try #require(ContentAwareInpainting.fill(image, mask: mask))
        let b = try #require(ContentAwareInpainting.fill(image, mask: mask))
        #expect(PNGExporter.pngData(a) == PNGExporter.pngData(b))
        #expect(PNGExporter.pngData(a) != PNGExporter.pngData(image))
    }

    @Test func representativeLargeDocumentRenderBenchmark() throws {
        let canvas = CGSize(width: 2000, height: 1400)
        let context = GeneratorContext(size: canvas, palette: BuiltInPalettes.default, sampler: nil)
        var params = ParamValues(defaults: GeneratorType.gridLattice.generator.specs)
        params.set("columns", 60)
        params.set("rows", 42)
        let primitives = GeneratorType.gridLattice.generator.generate(params: params, seed: 44,
                                                                        context: context)
        let item = RenderItem(id: UUID(), opacity: 1, blendMode: .normal,
                              transform: .identity, naturalSize: canvas,
                              content: .primitives(primitives))
        let clock = ContinuousClock()
        let start = clock.now
        let image = PNGExporter.render(items: [item], background: .black,
                                       canvasSize: canvas, targetPixelSize: canvas)
        let elapsed = start.duration(to: clock.now)
        #expect(image?.width == 2000)
        #expect(elapsed < .seconds(8), "2K representative render took \(elapsed)")
    }
}

@MainActor
struct AnimationTests {
    @Test func keyframesRoundTripAndInterpolateDeterministically() throws {
        var model = ProjectModel.starter()
        let layerID = try #require(model.layers.first?.id)
        model.animation = AnimationSettings(duration: 2, framesPerSecond: 12, keyframes: [
            AnimationKeyframe(time: 0, layerID: layerID, seed: 10,
                              parameters: ["curl": 0, "step": 4]),
            AnimationKeyframe(time: 2, layerID: layerID, seed: 20,
                              parameters: ["curl": 2, "step": 12]),
        ])
        let middleA = model.model(at: 1)
        let middleB = model.model(at: 1)
        #expect(middleA == middleB)
        #expect(middleA.layer(id: layerID)?.patternConfig?.seed == 20)
        #expect(middleA.layer(id: layerID)?.patternConfig?.params.double("curl") == 1)
        #expect(middleA.layer(id: layerID)?.patternConfig?.params.double("step") == 8)
        let decoded = try JSONDecoder().decode(ProjectModel.self, from: JSONEncoder().encode(model))
        #expect(decoded.animation == model.animation)
        #expect(decoded.schemaVersion == ProjectModel.currentSchemaVersion)
    }

    @Test func directKeyframeEditingDoesNotMutateBaseLayer() throws {
        let document = PixelDocument()
        let layerID = try #require(document.model.layers.first?.id)
        let base = try #require(document.model.layer(id: layerID)?.patternConfig)
        document.captureAnimationKeyframe(layerID: layerID, time: 0, undoManager: nil)
        let id = try #require(document.model.animation.keyframes.first?.id)
        document.updateAnimationKeyframe(id, seed: 999, parameter: "curl", value: 1.5,
                                         undoManager: nil, actionName: "Test Keyframe Edit")
        let frame = try #require(document.model.animation.keyframes.first)
        #expect(frame.seed == 999)
        #expect(frame.parameters["curl"] == 1.5)
        #expect(document.model.layer(id: layerID)?.patternConfig == base)
    }

    @Test func insertionAtPlayheadCapturesEvaluatedAnimationState() throws {
        let document = PixelDocument()
        let layerID = try #require(document.model.layers.first?.id)
        document.update(nil, actionName: "Test Setup") { model in
            model.animation = AnimationSettings(duration: 2, framesPerSecond: 12, keyframes: [
                AnimationKeyframe(time: 0, layerID: layerID, seed: 10,
                                  parameters: ["curl": 0, "steps": 4]),
                AnimationKeyframe(time: 2, layerID: layerID, seed: 20,
                                  parameters: ["curl": 2, "steps": 12]),
            ])
        }
        document.captureAnimationKeyframe(layerID: layerID, time: 1, undoManager: nil)
        let middle = try #require(document.model.animation.keyframes.first { abs($0.time - 1) < 0.0001 })
        #expect(middle.seed == 20)
        #expect(middle.parameters["curl"] == 1)
        #expect(middle.parameters["steps"] == 8)
    }

    @Test func gifExporterWritesEveryDeterministicFrame() async throws {
        var model = ProjectModel.starter()
        let layerID = try #require(model.layers.first?.id)
        model.canvasSize = CGSize(width: 64, height: 64)
        model.animation = AnimationSettings(duration: 0.5, framesPerSecond: 4, keyframes: [
            AnimationKeyframe(time: 0, layerID: layerID, seed: 1, parameters: [:]),
            AnimationKeyframe(time: 0.5, layerID: layerID, seed: 2, parameters: [:]),
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("animation-test-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        try await AnimationExporter.export(format: .gif, to: url, model: model,
                                           size: model.canvasSize, render: { frame, size in
            let layer = frame.layers[0]
            let config = layer.patternConfig!
            let primitives = config.generator.generator.generate(
                params: config.params, seed: config.seed,
                context: GeneratorContext(size: frame.canvasSize, palette: frame.palette,
                                          sampler: nil))
            let item = RenderItem(id: layer.id, opacity: 1, blendMode: .normal,
                                  transform: .identity, naturalSize: frame.canvasSize,
                                  content: .primitives(primitives))
            return PNGExporter.render(items: [item], background: frame.background,
                                      canvasSize: frame.canvasSize, targetPixelSize: size)
        }, progress: { _ in })
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == model.animation.frameCount)
    }
}

@MainActor
struct ColorManagementTests {
    /// Documents saved before v5 carry no colorSettings and must decode as
    /// sRGB / 8-bit — the exact pipeline they were authored in.
    @Test func preV5ManifestDecodesAsSRGB8() throws {
        let old = """
        {
          "background": {"a": 1, "b": 0.1, "g": 0.12, "r": 0.13},
          "canvasSize": [1000, 1000],
          "layers": [],
          "palette": {"colors": [{"a": 1, "b": 0.2, "g": 0.4, "r": 0.6}], "name": "Test"}
        }
        """
        let model = try JSONDecoder().decode(ProjectModel.self, from: Data(old.utf8))
        #expect(model.colorSettings == .default)
        #expect(model.colorSettings.workingSpace == .sRGB)
        #expect(model.colorSettings.bitDepth == .eight)
    }

    @Test func colorSettingsRoundTrip() throws {
        var model = ProjectModel()
        model.colorSettings = ColorSettings(workingSpace: .displayP3, bitDepth: .sixteen)
        let decoded = try JSONDecoder().decode(ProjectModel.self, from: JSONEncoder().encode(model))
        #expect(decoded.colorSettings.workingSpace == .displayP3)
        #expect(decoded.colorSettings.bitDepth == .sixteen)
    }

    @Test func renderHonorsWorkingSpaceAndDepth() throws {
        let item = RenderItem(id: UUID(), opacity: 1, blendMode: .normal,
                              transform: .identity, naturalSize: CGSize(width: 32, height: 32),
                              content: .fill(FillConfig(style: .solid, colors: [RGBAColor(r: 1, g: 0, b: 0)])))
        let settings = ColorSettings(workingSpace: .displayP3, bitDepth: .sixteen)
        let image = try #require(PNGExporter.render(items: [item], background: .black,
                                                    canvasSize: CGSize(width: 32, height: 32),
                                                    targetPixelSize: CGSize(width: 32, height: 32),
                                                    colorSettings: settings))
        #expect(image.bitsPerComponent == 16)
        #expect(image.colorSpace?.name == CGColorSpace.displayP3)
    }

    /// The PNG encoder must preserve 16-bit depth and embed the P3 profile,
    /// and both must survive a decode round-trip.
    @Test func pngRoundTripKeepsDepthAndProfile() throws {
        let settings = ColorSettings(workingSpace: .displayP3, bitDepth: .sixteen)
        let ctx = try #require(settings.makeRGBAContext(width: 8, height: 8))
        ctx.setFillColor(RGBAColor(r: 1, g: 0, b: 0).cgColor(in: .displayP3))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(ctx.makeImage())
        let data = try #require(PNGExporter.pngData(image))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.bitsPerComponent == 16)
        let profile = try #require(decoded.colorSpace?.name as String?)
        #expect(profile.contains("P3"))
    }

    @Test func jpegExportEmbedsWorkingSpaceProfile() throws {
        let settings = ColorSettings(workingSpace: .displayP3, bitDepth: .eight)
        let ctx = try #require(settings.makeRGBAContext(width: 8, height: 8))
        ctx.setFillColor(RGBAColor(r: 0.5, g: 0.5, b: 0.5).cgColor(in: .displayP3))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(ctx.makeImage())
        let data = try #require(ImageEncoder.encode(image, format: .jpeg, quality: 0.9))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let profile = try #require(props[kCGImagePropertyProfileName] as? String)
        #expect(profile.contains("P3"))
    }

    /// sRGB pure red sits inside P3, so its P3 coordinates pull off the gamut
    /// edge; converting back must return (within rounding) to where it began.
    @Test func workingSpaceConversionIsSaneAndReversible() {
        let red = RGBAColor(r: 1, g: 0, b: 0)
        let inP3 = red.converted(from: .sRGB, to: .displayP3)
        #expect(inP3.r < 0.95 && inP3.r > 0.85)
        let back = inP3.converted(from: .displayP3, to: .sRGB)
        #expect(abs(back.r - 1) < 0.02 && abs(back.g) < 0.02 && abs(back.b) < 0.02)
    }

    @Test func paintSessionBuffersMatchDocumentDepth() {
        let settings = ColorSettings(workingSpace: .displayP3, bitDepth: .sixteen)
        let session = PaintSession(target: .content(layerID: UUID()), base: nil,
                                   pixelSize: CGSize(width: 16, height: 16),
                                   colorSettings: settings)
        #expect(session?.currentImage?.bitsPerComponent == 16)
        #expect(session?.currentImage?.colorSpace?.name == CGColorSpace.displayP3)
    }

    /// SVG output is sRGB by definition — P3 components must convert, not
    /// pass through as misinterpreted sRGB values.
    @Test func svgConvertsWideGamutColors() {
        let item = RenderItem(id: UUID(), opacity: 1, blendMode: .normal,
                              transform: .identity, naturalSize: CGSize(width: 10, height: 10),
                              content: .primitives([VectorPrimitive(
                                path: Path(CGRect(x: 0, y: 0, width: 10, height: 10)),
                                fill: RGBAColor(r: 1, g: 0, b: 0))]))
        let svg = SVGExporter.svg(items: [item], background: .black,
                                  canvasSize: CGSize(width: 10, height: 10),
                                  workingSpace: .displayP3)
        // P3 pure red is outside sRGB: it clips to rgb(255,...) with low g/b.
        #expect(svg.contains("rgb(255,"))
    }
}

@MainActor
struct LayerSourceTests {
    /// Rasterizing records the vector source; revert restores it exactly,
    /// including the transform scale the bake folded into pixels.
    @Test func rasterizeRecordsSourceAndRevertRestoresIt() {
        let document = PixelDocument()
        let store = RenderStore(document: document)
        let layerID = document.model.layers[0].id
        let originalKind = document.model.layers[0].kind
        document.update(nil) { $0.modifyLayer(id: layerID) { $0.transform.scale = 0.5 } }

        document.rasterizeLayer(id: layerID, renderStore: store, undoManager: nil)
        let baked = document.model.layer(id: layerID)
        #expect(baked?.kind.isImage == true)
        #expect(baked?.source?.kind == originalKind)
        #expect(baked?.source?.scale == 0.5)

        document.revertLayerToSource(id: layerID, undoManager: nil)
        let reverted = document.model.layer(id: layerID)
        #expect(reverted?.kind == originalKind)
        #expect(reverted?.transform.scale == 0.5)
        #expect(reverted?.source == nil)
    }

    /// A second bake keeps the earliest snapshot — revert always returns to
    /// the authored content, not an intermediate bake.
    @Test func laterBakesKeepEarliestSource() {
        let document = PixelDocument()
        let store = RenderStore(document: document)
        let layerID = document.model.layers[0].id
        let originalKind = document.model.layers[0].kind

        document.rasterizeLayer(id: layerID, renderStore: store, undoManager: nil)
        document.superResolveLayer(layerID: layerID, renderStore: store, undoManager: nil)

        let layer = document.model.layer(id: layerID)
        #expect(layer?.source?.kind == originalKind)
        document.revertLayerToSource(id: layerID, undoManager: nil)
        #expect(document.model.layer(id: layerID)?.kind == originalKind)
    }

    /// Rasterizing a scaled-down layer must not bake away resolution.
    @Test func rasterizeKeepsNativeResolutionWhenScaledDown() {
        let document = PixelDocument()
        let store = RenderStore(document: document)
        let layerID = document.model.layers[0].id
        document.update(nil) { $0.modifyLayer(id: layerID) { $0.transform.scale = 0.25 } }

        document.rasterizeLayer(id: layerID, renderStore: store, undoManager: nil)
        let config = document.model.layer(id: layerID)?.imageConfig
        // Baked at natural (canvas) resolution, not 25% of it.
        #expect(config?.pixelSize == document.model.canvasSize)
        #expect(abs((document.model.layer(id: layerID)?.transform.scale ?? 0) - 0.25) < 0.001)
    }

    @Test func sourceSurvivesEncodeAndOldManifestsDecodeWithoutIt() throws {
        let document = PixelDocument()
        let store = RenderStore(document: document)
        let layerID = document.model.layers[0].id
        document.rasterizeLayer(id: layerID, renderStore: store, undoManager: nil)

        let data = try JSONEncoder().encode(document.model)
        let decoded = try JSONDecoder().decode(ProjectModel.self, from: data)
        #expect(decoded.layer(id: layerID)?.source != nil)
        #expect(decoded.layer(id: layerID)?.source == document.model.layer(id: layerID)?.source)

        // A layer JSON without "source" decodes to nil.
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var layers = try #require(object["layers"] as? [[String: Any]])
        layers[0]["source"] = nil
        object["layers"] = layers
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let old = try JSONDecoder().decode(ProjectModel.self, from: stripped)
        #expect(old.layer(id: layerID)?.source == nil)
    }

    /// The pasteboard payload must carry the source's image bytes, or a
    /// pasted layer could never revert. Uses an image layer so the source
    /// snapshot actually references stored pixels.
    @Test func transferPayloadIncludesSourceImageKeys() throws {
        let document = PixelDocument()
        let store = RenderStore(document: document)
        let ctx = try #require(ColorSettings.default.makeRGBAContext(width: 8, height: 8))
        ctx.setFillColor(RGBAColor(r: 0.4, g: 0.5, b: 0.6).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let bitmap = try #require(ctx.makeImage())
        let png = try #require(PNGExporter.pngData(bitmap))
        let originalKey = document.storeImage(data: png, fileExtension: "png")
        let layer = Layer(name: "Photo", transform: LayerTransform(position: .zero),
                          kind: .image(ImageConfig(imageKey: originalKey,
                                                   pixelSize: CGSize(width: 8, height: 8))))
        document.update(nil) { $0.layers.append(layer) }

        document.superResolveLayer(layerID: layer.id, renderStore: store, undoManager: nil)

        let baked = try #require(document.model.layer(id: layer.id))
        #expect(baked.imageConfig?.imageKey != originalKey)
        #expect(baked.source?.kind == layer.kind)
        #expect(baked.referencedImageKeys.contains(originalKey))

        let transfer = document.transferPayload(for: layer.id, renderStore: store)
        #expect(transfer?.images?[originalKey] != nil)
    }
}
