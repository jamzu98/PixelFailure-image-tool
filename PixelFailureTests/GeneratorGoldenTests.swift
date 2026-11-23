import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import PixelFailure

/// Fingerprints of every original generator's output at default settings.
/// Recorded before Phase 4 changed any generator code: if one of these
/// moves, documents saved before Phase 4 would no longer render the same.
@MainActor
struct GeneratorGoldenTests {
    static let golden: [GeneratorType: UInt64] = [
        .gridLattice: 17815413514978830722,
        .phyllotaxis: 929929339763293033,
        .flowField: 10026513379586394596,
        .truchet: 13123343304313440055,
        .waves: 8844097485473540334,
        .rings: 14788816869265872965,
        .sampledGrid: 15005308478320456417,
    ]

    static var sampler: ImageSampler {
        let context = ColorSettings.default.makeRGBAContext(width: 64, height: 64)!
        let colors = [CGColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1),
                      CGColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: colors, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 64, y: 64), options: [])
        return ImageSampler(cgImage: context.makeImage()!, maxDimension: 64)!
    }

    static func context(for type: GeneratorType) -> GeneratorContext {
        GeneratorContext(size: CGSize(width: 1000, height: 1000), palette: BuiltInPalettes.default,
                         sampler: type.generator.needsSourceImage ? sampler : nil)
    }

    /// The seven generators that existed before Phase 4.
    static let originals: [GeneratorType] = [.gridLattice, .phyllotaxis, .flowField, .truchet,
                                             .waves, .rings, .sampledGrid]

    @Test func originalGeneratorsAreUnchanged() {
        for type in Self.originals {
            let generator = type.generator
            let output = generator.generate(params: ParamValues(defaults: generator.specs),
                                            seed: 42, context: Self.context(for: type))
            let digest = PrimitiveDigest.of(output)
            #expect(digest == Self.golden[type], "\(type) digest \(digest)")
        }
    }

    /// With every shared stage at its default, the pipeline is a no-op.
    @Test func pipelineWithDefaultStagesMatchesTheGenerator() {
        for type in Self.originals {
            var params = ParamValues(defaults: type.generator.specs)
            for spec in GenStages.allSpecs { params.set(spec.key, spec.defaultValue) }
            let config = PatternConfig(generator: type, seed: 42, params: params)
            let digest = PrimitiveDigest.of(config.generate(context: Self.context(for: type)))
            #expect(digest == Self.golden[type], "\(type) changed through the pipeline")
        }
    }
}

/// Stable FNV-1a fingerprint of primitives: geometry rounded to 1/1000 px,
/// colors to 1/10000, plus stroke style.
nonisolated enum PrimitiveDigest {
    static func of(_ primitives: [VectorPrimitive]) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        func mix(_ value: Int64) {
            var v = UInt64(bitPattern: value)
            for _ in 0..<8 {
                hash ^= v & 0xff
                hash = hash &* 0x100000001b3
                v >>= 8
            }
        }
        func point(_ p: CGPoint) { mix(Int64((p.x * 1000).rounded())); mix(Int64((p.y * 1000).rounded())) }
        func color(_ c: RGBAColor?) {
            guard let c else { mix(-1); return }
            for component in [c.r, c.g, c.b, c.a] { mix(Int64((component * 10000).rounded())) }
        }
        mix(Int64(primitives.count))
        for primitive in primitives {
            primitive.path.forEach { element in
                switch element {
                case .move(let p): mix(1); point(p)
                case .line(let p): mix(2); point(p)
                case .quadCurve(let p, let c): mix(3); point(p); point(c)
                case .curve(let p, let c1, let c2): mix(4); point(p); point(c1); point(c2)
                case .closeSubpath: mix(5)
                }
            }
            color(primitive.fill)
            color(primitive.stroke)
            mix(Int64((primitive.lineWidth * 1000).rounded()))
            mix(Int64(primitive.lineCap.rawValue))
            mix(Int64(primitive.lineJoin.rawValue))
            for dash in primitive.dash { mix(Int64((dash * 1000).rounded())) }
        }
        return hash
    }
}
