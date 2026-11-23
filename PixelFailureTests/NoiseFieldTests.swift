import Foundation
import Testing
@testable import PixelFailure

struct NoiseFieldTests {
    @Test func everyKindIsDeterministicAndBounded() {
        for kind in NoiseKind.allCases {
            let a = NoiseField(kind: kind, seed: 7, octaves: 3, warp: 0.6)
            let b = NoiseField(kind: kind, seed: 7, octaves: 3, warp: 0.6)
            var values: [Double] = []
            for i in 0..<400 {
                let x = Double(i % 20) * 0.37, y = Double(i / 20) * 0.41
                let v = a.value(x, y)
                #expect(v == b.value(x, y), "\(kind) not deterministic")
                #expect((-1...1).contains(v), "\(kind) out of range: \(v)")
                values.append(v)
            }
            // Not a constant field.
            #expect((values.max()! - values.min()!) > 0.2, "\(kind) has no variation")
        }
    }

    @Test func seedsChangeTheField() {
        for kind in NoiseKind.allCases {
            let a = NoiseField(kind: kind, seed: 1), b = NoiseField(kind: kind, seed: 2)
            let differs = (0..<50).contains { i in
                a.value(Double(i) * 0.53, 0.7) != b.value(Double(i) * 0.53, 0.7)
            }
            #expect(differs, "\(kind) ignores its seed")
        }
    }

    @Test func curlIsDivergenceFree() {
        let field = NoiseField(kind: .simplex, seed: 3)
        let e = 0.01
        for i in 0..<20 {
            let x = Double(i) * 0.31 + 0.1, y = Double(i) * 0.17 + 0.2
            let dvx = (field.curl(x + e, y).0 - field.curl(x - e, y).0) / (2 * e)
            let dvy = (field.curl(x, y + e).1 - field.curl(x, y - e).1) / (2 * e)
            #expect(abs(dvx + dvy) < 0.05)
        }
    }

    @Test @MainActor func newNoiseOptionsChangeFlowFields() {
        let generator = GeneratorType.flowField.generator
        let context = GeneratorGoldenTests.context(for: .flowField)
        let base = ParamValues(defaults: generator.specs)
        let baseline = PrimitiveDigest.of(generator.generate(params: base, seed: 42, context: context))
        for (key, value) in [("noiseType", 1.0), ("noiseWarp", 0.8), ("curlFlow", 1.0)] {
            var params = base
            params.set(key, value)
            let digest = PrimitiveDigest.of(generator.generate(params: params, seed: 42, context: context))
            #expect(digest != baseline, "\(key) had no effect")
        }
    }
}
