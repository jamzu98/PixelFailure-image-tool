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
