import CoreGraphics
import Foundation
import QuartzCore
import SwiftUI
import Testing
@testable import PixelFailure

@MainActor
struct NewGeneratorTests {
    static let added: [GeneratorType] = [.circlePacking, .contours, .stipple, .subdivision, .spaceFilling,
                                         .lSystem, .growth, .waveTiles, .stringArt]

    private func context(_ type: GeneratorType, size: CGFloat = 1000, params: ParamValues? = nil) -> GeneratorContext {
        let p = params ?? ParamValues(defaults: type.generator.specs)
        return GeneratorContext(size: CGSize(width: size, height: size), palette: BuiltInPalettes.default,
                                sampler: type.generator.wantsSourceImage(p) || type.generator.needsSourceImage
                                    ? GeneratorGoldenTests.sampler : nil)
    }

    @Test func everyNewGeneratorIsDeterministicAndSeeded() {
        for type in Self.added {
            let generator = type.generator
            let params = ParamValues(defaults: generator.specs)
            let a = PrimitiveDigest.of(generator.generate(params: params, seed: 11, context: context(type)))
            let b = PrimitiveDigest.of(generator.generate(params: params, seed: 11, context: context(type)))
            let c = PrimitiveDigest.of(generator.generate(params: params, seed: 12, context: context(type)))
            #expect(a == b, "\(type) is not deterministic")
            #expect(a != c, "\(type) ignores its seed")
            #expect(!generator.generate(params: params, seed: 11, context: context(type)).isEmpty, "\(type) is empty")
        }
    }

    @Test func everyChoiceOfEveryNewGeneratorProducesContent() {
        for type in Self.added {
            let generator = type.generator
            for spec in generator.specs {
                guard case .choice(let options) = spec.kind else { continue }
                for option in options.indices {
                    var params = ParamValues(defaults: generator.specs)
                    params.set(spec.key, Double(option))
                    let out = generator.generate(params: params, seed: 3, context: context(type, params: params))
                    #expect(!out.isEmpty, "\(type) \(spec.key)=\(options[option]) is empty")
                }
            }
        }
    }

    /// Defaults stay interactive on a large canvas (Debug build, generous bound).
    @Test func newGeneratorsStayWithinBudget() {
        var report: [String] = []
        for type in Self.added {
            let generator = type.generator
            let params = ParamValues(defaults: generator.specs)
            let start = CACurrentMediaTime()
            _ = generator.generate(params: params, seed: 5, context: context(type, size: 3000))
            let ms = (CACurrentMediaTime() - start) * 1000
            report.append("\(type) \(Int(ms)) ms")
            #expect(ms < 2500, "\(type) took \(Int(ms)) ms")
        }
        print("GENERATOR TIMINGS: " + report.joined(separator: ", "))
    }

    @Test func curvesVisitNeighboringCells() {
        func check(_ cells: [(Int, Int)], closed: Bool, name: String) {
            for k in 1..<cells.count {
                let d = abs(cells[k].0 - cells[k - 1].0) + abs(cells[k].1 - cells[k - 1].1)
                #expect(d == 1, "\(name) jumps at \(k): \(cells[k - 1]) → \(cells[k])")
                if d != 1 { return }
            }
            let unique = Set(cells.map { $0.0 * 100_000 + $0.1 })
            #expect(unique.count == cells.count - (closed ? 1 : 0), "\(name) revisits cells")
        }
        check(SpaceFillingGenerator.hilbert(order: 4), closed: false, name: "Hilbert")
        check(SpaceFillingGenerator.moore(order: 4), closed: true, name: "Moore")
        check(SpaceFillingGenerator.peano(order: 3), closed: false, name: "Peano")
    }

    @Test func waveTileNeighborsAlwaysAgree() {
        var rng = SeededRNG(seed: 4)
        var tiles: [WaveTilesGenerator.Tile] = []
        for n in 0...2 { for e in 0...2 { for s in 0...2 { for w in 0...2 {
            tiles.append(.init(sockets: [n, e, s, w], weight: 1))
        } } } }
        let grid = try! #require(WaveTilesGenerator.collapse(tiles: tiles, columns: 12, rows: 9,
                                                             closedEdges: true, rng: &rng))
        for row in 0..<9 {
            for column in 0..<12 {
                let t = tiles[grid[row * 12 + column]].sockets
                if column < 11 { #expect(t[1] == tiles[grid[row * 12 + column + 1]].sockets[3]) }
                if row < 8 { #expect(t[2] == tiles[grid[(row + 1) * 12 + column]].sockets[0]) }
                if row == 0 { #expect(t[0] == 0) }
                if column == 0 { #expect(t[3] == 0) }
            }
        }
    }

    @Test func stringArtTimesTableConnectsPinIToIk() {
        var params = ParamValues(defaults: GeneratorType.stringArt.generator.specs)
        params.set("pins", 10); params.set("multiplier", 3)
        let out = GeneratorType.stringArt.generator.generate(params: params, seed: 1, context: context(.stringArt))
        var segments = 0
        for primitive in out { primitive.path.forEach { if case .line = $0 { segments += 1 } } }
        // Every pin draws one line except those mapping to themselves (0 and 5).
        let expected = (0..<10).filter { ($0 * 3) % 10 != $0 }.count
        #expect(segments == expected)
    }
}
