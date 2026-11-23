import CoreGraphics
import Foundation
import Testing
@testable import PixelFailure

@MainActor
struct GlitchEffectTests {
    static let glitches: [EffectType] = [.pixelSort, .datamosh, .noiseShift, .dither]

    private func photo(_ w: Int = 240, _ h: Int = 160) -> CGImage {
        let ctx = ColorSettings.default.makeRGBAContext(width: w, height: h)!
        let colors = [CGColor(red: 0.95, green: 0.6, blue: 0.2, alpha: 1),
                      CGColor(red: 0.1, green: 0.2, blue: 0.7, alpha: 1)] as CFArray
        ctx.drawLinearGradient(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                          locations: [0, 1])!,
                               start: .zero, end: CGPoint(x: w, y: h), options: [])
        var rng = SeededRNG(seed: 2)
        for _ in 0..<60 {
            ctx.setFillColor(CGColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1))
            ctx.fillEllipse(in: CGRect(x: rng.range(0, Double(w)), y: rng.range(0, Double(h)), width: 18, height: 18))
        }
        return ctx.makeImage()!
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        let ctx = ColorSettings.default.makeRGBAContext(width: image.width, height: image.height)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self),
                                         count: image.width * image.height * 4))
    }

    @Test func everyGlitchChangesPixelsDeterministicallyAndKeepsSize() throws {
        try #require(MetalCompute.shared != nil)
        let input = photo()
        let original = pixels(input)
        for type in Self.glitches {
            let effect = Effect(type: type, params: type.defaultParams)
            let a = EffectPipeline.shared.apply(effects: [effect], to: input, palette: BuiltInPalettes.default)
            let b = EffectPipeline.shared.apply(effects: [effect], to: input, palette: BuiltInPalettes.default)
            #expect(a.width == input.width && a.height == input.height, "\(type) changed size")
            let pa = pixels(a)
            #expect(pa != original, "\(type) did nothing")
            #expect(pa == pixels(b), "\(type) is not deterministic")
        }
    }

    @Test func variantReseedsDatamoshAndNoiseShift() throws {
        try #require(MetalCompute.shared != nil)
        let input = photo()
        for type in [EffectType.datamosh, .noiseShift] {
            var params = type.defaultParams
            let first = EffectPipeline.shared.apply(effects: [Effect(type: type, params: params)], to: input,
                                                    palette: BuiltInPalettes.default)
            params.set("variant", 17)
            let second = EffectPipeline.shared.apply(effects: [Effect(type: type, params: params)], to: input,
                                                     palette: BuiltInPalettes.default)
            #expect(pixels(first) != pixels(second), "\(type) ignores Variant")
        }
    }

    @Test func ditherUsesOnlyPaletteColors() throws {
        try #require(MetalCompute.shared != nil)
        for method in 0...3 {
            var params = EffectType.dither.defaultParams
            params.set("method", Double(method))
            params.set("colors", 1) // black & white
            let out = EffectPipeline.shared.apply(effects: [Effect(type: .dither, params: params)], to: photo(),
                                                  palette: BuiltInPalettes.default)
            let px = pixels(out)
            let offPalette = stride(from: 0, to: px.count, by: 4).filter { i in
                let v = px[i]
                return !(v < 3 || v > 252) || px[i] != px[i + 1] || px[i] != px[i + 2]
            }
            #expect(offPalette.isEmpty, "method \(method): \(offPalette.count) off-palette pixels")
        }
    }

    @Test func pixelSortOrdersSpansByBrightness() throws {
        // A single row of random grays with the full range selected sorts ascending.
        let ctx = ColorSettings.default.makeRGBAContext(width: 64, height: 1)!
        var rng = SeededRNG(seed: 5)
        for x in 0..<64 {
            let v = rng.range(0.3, 0.7)
            ctx.setFillColor(CGColor(red: v, green: v, blue: v, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: 1))
        }
        var params = EffectType.pixelSort.defaultParams
        params.set("low", 0); params.set("high", 1); params.set("maxSpan", 1)
        let out = EffectPipeline.shared.apply(effects: [Effect(type: .pixelSort, params: params)],
                                              to: ctx.makeImage()!, palette: BuiltInPalettes.default)
        let px = pixels(out)
        let row = stride(from: 0, to: px.count, by: 4).map { Int(px[$0]) }
        #expect(row == row.sorted() || row == row.sorted(by: >))
    }

    @Test func menuGroupsCoverEveryTypeOnce() {
        let effects = EffectType.groups.flatMap(\.types)
        #expect(effects.count == EffectType.allCases.count && Set(effects) == Set(EffectType.allCases))
        let generators = GeneratorType.groups.flatMap { $0 }
        #expect(generators.count == GeneratorType.allCases.count && Set(generators) == Set(GeneratorType.allCases))
    }
}
