import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import PixelFailure

@MainActor
struct GeneratorStageTests {
    private let size = CGSize(width: 1000, height: 1000)
    private var context: GeneratorContext {
        GeneratorContext(size: size, palette: BuiltInPalettes.default, sampler: nil)
    }

    private func config(_ type: GeneratorType = .flowField, stages: [String: Double] = [:]) -> PatternConfig {
        var params = ParamValues(defaults: type.generator.specs)
        for (key, value) in stages { params.set(key, value) }
        return PatternConfig(generator: type, seed: 42, params: params)
    }

    private func bounds(_ primitives: [VectorPrimitive]) -> CGRect {
        primitives.reduce(CGRect.null) { $0.union($1.path.boundingRect) }
    }

    @Test func mirrorIsSymmetricAboutTheCenter() {
        let out = config(stages: ["stage.symmetry": 1]).generate(context: context)
        #expect(!out.isEmpty)
        let box = bounds(out)
        #expect(abs((box.minX - 500) + (box.maxX - 500)) < 1)
        // Every primitive has a mirror image.
        let lefts = out.filter { $0.path.boundingRect.midX < 500 }.count
        #expect(lefts * 2 == out.count)
    }

    @Test func radialAndKaleidoscopeMakeTheRightNumberOfCopies() {
        let radial = config(stages: ["stage.symmetry": 4, "stage.segments": 6]).generate(context: context)
        let kaleido = config(stages: ["stage.symmetry": 5, "stage.segments": 4]).generate(context: context)
        #expect(!radial.isEmpty && radial.count % 6 == 0)
        #expect(!kaleido.isEmpty && kaleido.count % 8 == 0)
    }

    @Test func repeatTilesScaledCopiesInsideTheCanvas() {
        let base = config().generate(context: context)
        let tiled = config(stages: ["stage.repeat": 1]).generate(context: context)
        #expect(tiled.count == base.count * 4)
        #expect(abs(tiled[0].lineWidth - base[0].lineWidth / 2) < 1e-9)
        let box = bounds(tiled)
        #expect(box.minX > -size.width * 0.1 && box.maxX < size.width * 1.1)
    }

    @Test func regionKeepsStrokesInsideOrOutside() {
        let square = Path(CGRect(x: 300, y: 300, width: 400, height: 400))
        var inside = context
        inside.region = square
        let kept = config(stages: ["stage.region": 1]).generate(context: inside)
        #expect(!kept.isEmpty)
        for primitive in kept {
            let box = primitive.path.boundingRect
            var elements: [String] = []
            primitive.path.forEach { elements.append("\($0)") }
            #expect(square.boundingRect.insetBy(dx: -1, dy: -1).contains(box),
                    "box \(box) elements \(elements.prefix(6)) count \(elements.count)")
        }
        let outside = config(stages: ["stage.region": 2]).generate(context: inside)
        #expect(outside.allSatisfy { !square.boundingRect.insetBy(dx: 1, dy: 1).contains($0.path.boundingRect) })
    }

    @Test func imageColorSourceRecolorsFromTheSampler() {
        var sampled = context
        sampled.sampler = GeneratorGoldenTests.sampler
        let out = config(.gridLattice, stages: ["stage.color": 1]).generate(context: sampled)
        let first = try! #require(out.first)
        let box = first.path.boundingRect
        let expected = GeneratorGoldenTests.sampler.color(atUnitX: box.midX / 1000, y: box.midY / 1000)
        let actual = first.fill ?? first.stroke!
        #expect(abs(actual.r - expected.r) < 1e-9 && abs(actual.b - expected.b) < 1e-9)
    }

    @Test func regionLayerRendersThroughTheStore() throws {
        let document = PixelDocument()
        let store = RenderStore(document: document)
        let shape = Layer(name: "Box", transform: LayerTransform(position: CGPoint(x: 500, y: 500)),
                          kind: .shape(ShapeConfig(kind: .rectangle, size: CGSize(width: 200, height: 200))))
        var pattern = config(stages: ["stage.region": 1])
        pattern.regionLayerID = shape.id
        let patternLayer = Layer(name: "Flow", transform: LayerTransform(position: CGPoint(x: 500, y: 500)),
                                 kind: .pattern(pattern))
        document.update(nil) {
            $0.canvasSize = CGSize(width: 1000, height: 1000)
            $0.layers = [shape, patternLayer]
        }
        let items = store.renderItems(model: document.model, quality: .full)
        guard case .primitives(let prims) = items.last?.content else { Issue.record("no primitives"); return }
        #expect(!prims.isEmpty)
        #expect(CGRect(x: 399, y: 399, width: 202, height: 202).contains(bounds(prims)))

        // Moving the region re-renders the whole pattern, not just the box.
        var moved = document.model
        moved.modifyLayer(id: shape.id) { $0.transform.position = CGPoint(x: 300, y: 300) }
        let region = RenderInvalidationPlanner.region(from: document.model, to: moved) { layer, model in
            store.renderBounds(for: layer, model: model)
        }
        #expect(region == .full)
    }

    @Test func randomizeKeepsStagesAndLocks() {
        let specs = GeneratorType.flowField.generator.specs
        var existing = ParamValues(defaults: specs)
        existing.set("stage.symmetry", 5)
        existing.set("curl", 2.5)
        let out = ParamValues.randomized(specs: specs, seed: 9, keeping: existing, locked: ["curl"])
        #expect(out.int("stage.symmetry") == 5)
        #expect(out.double("curl") == 2.5)
        #expect(out.storage != existing.storage)
    }

    @Test func oldPatternJSONDecodesWithoutNewFields() throws {
        let json = #"{"generator":"flowField","seed":5,"params":{"storage":{"curl":1.2}}}"#
        let decoded = try JSONDecoder().decode(PatternConfig.self, from: Data(json.utf8))
        #expect(decoded.regionLayerID == nil)
        #expect(decoded.lockedParams.isEmpty)
        let reencoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(!reencoded.contains("lockedParams"))
        #expect(!reencoded.contains("regionLayerID"))
    }
}
