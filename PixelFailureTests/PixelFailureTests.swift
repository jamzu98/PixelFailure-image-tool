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
        #expect(model.canvasEffects.isEmpty)
        #expect(model.layers[0].mask == nil)
        #expect(model.layers[0].patternConfig?.seed == 42)
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
