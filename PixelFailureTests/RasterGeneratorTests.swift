import CoreGraphics
import Foundation
import Testing
@testable import PixelFailure

@MainActor
struct RasterGeneratorTests {
    static let raster: [GeneratorType] = [.noiseField, .voronoi, .plasma, .reactionDiffusion]

    private func pixels(_ image: CGImage) -> [UInt8] {
        let ctx = ColorSettings.default.makeRGBAContext(width: image.width, height: image.height)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: data, count: image.width * image.height * 4))
    }

    private func render(_ type: GeneratorType, seed: UInt64, params: ParamValues? = nil,
                        size: CGSize = CGSize(width: 192, height: 128)) -> CGImage? {
        let generator = type.generator as! any RasterGenerator
        return generator.render(params: params ?? ParamValues(defaults: generator.specs), seed: seed,
                                pixelSize: size, palette: BuiltInPalettes.default, colorSettings: .default)
    }

    @Test func kernelsCompile() {
        #expect(MetalCompute.shared != nil, "\(MetalCompute.compileError.withLock { $0 } ?? "no device")")
    }

    @Test func everyRasterGeneratorRendersDeterministically() throws {
        try #require(MetalCompute.shared != nil)
        for type in Self.raster {
            var params = ParamValues(defaults: type.generator.specs)
            if type == .reactionDiffusion { params.set("iterations", 400) }
            let a = try #require(render(type, seed: 7, params: params), "\(type) rendered nothing")
            #expect(a.width == 192 && a.height == 128)
            let b = try #require(render(type, seed: 7, params: params))
            let c = try #require(render(type, seed: 8, params: params))
            let pa = pixels(a)
            #expect(pa == pixels(b), "\(type) is not deterministic")
            #expect(pa != pixels(c), "\(type) ignores its seed")
            // Not a flat image.
            #expect(Set(stride(from: 0, to: pa.count, by: 4 * 97).map { pa[$0] }).count > 3, "\(type) is flat")
        }
    }

    @Test func rasterPatternsResolveAtEachTier() throws {
        try #require(MetalCompute.shared != nil)
        let document = PixelDocument()
        let store = RenderStore(document: document)
        let layer = Layer(name: "Noise", transform: LayerTransform(position: CGPoint(x: 1500, y: 1000)),
                          kind: .pattern(PatternConfig(generator: .noiseField, seed: 3,
                                                       params: ParamValues(defaults: GeneratorType.noiseField.generator.specs))))
        document.update(nil) {
            $0.canvasSize = CGSize(width: 3000, height: 2000)
            $0.layers = [layer]
        }
        for (quality, width) in [(RenderQuality.proxy, 512), (.preview, 1600), (.full, 3000)] {
            let items = store.renderItems(model: document.model, quality: quality)
            guard case .raster(let image) = items.first?.content else {
                Issue.record("\(quality) has no raster"); continue
            }
            #expect(image.width == width)
            #expect(items.first?.svgWarning != nil)
        }
    }

    @Test func rasterPatternsWorkAsMasks() throws {
        try #require(MetalCompute.shared != nil)
        let document = PixelDocument()
        let store = RenderStore(document: document)
        var shape = Layer(name: "Box", transform: LayerTransform(position: CGPoint(x: 100, y: 100)),
                          kind: .shape(ShapeConfig(kind: .rectangle, size: CGSize(width: 200, height: 200))))
        shape.mask = LayerMask(imageKey: "", pixelSize: CGSize(width: 200, height: 200),
                               pattern: PatternConfig(generator: .voronoi, seed: 1,
                                                      params: ParamValues(defaults: GeneratorType.voronoi.generator.specs)))
        document.update(nil) {
            $0.canvasSize = CGSize(width: 200, height: 200)
            $0.layers = [shape]
        }
        let items = store.renderItems(model: document.model, quality: .full)
        #expect(items.first?.mask != nil)
    }
}
