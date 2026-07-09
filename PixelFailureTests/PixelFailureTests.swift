import CoreGraphics
import Foundation
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
        #expect(svg.contains("url(#grad0)"))
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
