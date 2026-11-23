import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import PixelFailure

@MainActor
struct WorkflowTests {
    @Test func everyBuiltInPresetUsesRealKeysAndRenders() {
        for type in GeneratorType.allCases {
            let presets = BuiltInGeneratorPresets.presets(for: type)
            #expect(!presets.isEmpty, "\(type) has no presets")
            let keys = Set(type.generator.specs.map(\.key)).union(GenStages.keys)
            for preset in presets {
                let unknown = Set(preset.params.keys).subtracting(keys)
                #expect(unknown.isEmpty, "\(type) “\(preset.name)” has unknown keys \(unknown)")
            }
        }
    }

    @Test func applyingAPresetKeepsSeedStagesAndValidLocks() {
        var config = PatternConfig(generator: .flowField, seed: 77,
                                   params: ParamValues(defaults: GeneratorType.flowField.generator.specs))
        config.params.set("stage.repeat", 1)
        config.lockedParams = ["curl", "steps"]
        let preset = GeneratorPreset(name: "Test", generator: .contours, params: ["levels": 30])
        let applied = preset.applied(to: config)
        #expect(applied.generator == .contours)
        #expect(applied.seed == 77)
        #expect(applied.params.int("levels") == 30)
        #expect(applied.params.int("stage.repeat") == 1)
        #expect(applied.lockedParams.isEmpty) // flow-field keys don't exist on contours
    }

    @Test func userPresetsRoundTrip() {
        let defaults = UserDefaults(suiteName: "pf-preset-test-\(UUID().uuidString)")!
        let store = UserPresetStore(defaults: defaults)
        let config = PatternConfig(generator: .rings, seed: 1,
                                   params: ParamValues(defaults: GeneratorType.rings.generator.specs))
        store.save(GeneratorPreset.capture(config, name: "Mine"))
        store.save(GeneratorPreset.capture(config, name: "Mine")) // replaces
        let reloaded = UserPresetStore(defaults: defaults)
        #expect(reloaded.presets(for: .rings).count == 1)
        #expect(reloaded.presets(for: .rings).first?.params["ringCount"] == 26)
    }

    @Test func mutateStaysCloseAndRespectsLocks() {
        let specs = GeneratorType.flowField.generator.specs
        let base = ParamValues(defaults: specs)
        let a = ParamValues.mutated(specs: specs, seed: 3, from: base, strength: 0.1, locked: ["curl"])
        let b = ParamValues.mutated(specs: specs, seed: 3, from: base, strength: 0.1, locked: ["curl"])
        #expect(a == b)
        #expect(a.double("curl") == base.double("curl"))
        #expect(a.storage != base.storage)
        // Sliders move by at most 10% of their range.
        for spec in specs {
            if case .slider(let min, let max) = spec.kind {
                #expect(abs(a.double(spec.key) - base.double(spec.key)) <= (max - min) * 0.1 + 1e-9)
            }
        }
    }

    @Test func seedHistoryKeepsTwentyNewestFirst() {
        let state = EditorState()
        let id = UUID()
        for seed in 0..<25 { state.recordSeed(UInt64(seed), for: id) }
        state.recordSeed(10, for: id)
        let history = state.seedHistory[id]!
        #expect(history.count == 20)
        #expect(history.first == 10)
        #expect(Set(history).count == history.count)
    }

    @Test func plotterSVGIsStrokesOnlyGroupedAndShorterToTravel() throws {
        let document = PixelDocument()
        let store = RenderStore(document: document)
        var params = ParamValues(defaults: GeneratorType.flowField.generator.specs)
        params.set("lineCount", 300)
        params.set("colorMode", 1)
        let layer = Layer(name: "Flow", transform: LayerTransform(position: CGPoint(x: 400, y: 300)),
                          kind: .pattern(PatternConfig(generator: .flowField, seed: 4, params: params)))
        let fillShape = Layer(name: "Box", transform: LayerTransform(position: CGPoint(x: 100, y: 100)),
                              kind: .shape(ShapeConfig(kind: .rectangle, size: CGSize(width: 80, height: 80))))
        document.update(nil) {
            $0.canvasSize = CGSize(width: 800, height: 600)
            $0.layers = [fillShape, layer]
        }
        let items = store.renderItems(model: document.model, quality: .full)
        let svg = PlotterSVG.svg(items: items, canvasSize: document.model.canvasSize)
        #expect(svg.contains("inkscape:groupmode=\"layer\""))
        #expect(!svg.contains("<image"))
        #expect(!svg.replacingOccurrences(of: "fill=\"none\"", with: "").contains("fill="))
        let collected = PlotterSVG.collect(items, canvasSize: document.model.canvasSize)
        #expect(!collected.isEmpty)
        for stroke in collected {
            for p in stroke.points {
                #expect(p.x >= -0.01 && p.x <= 800.01 && p.y >= -0.01 && p.y <= 600.01)
            }
        }
        let ordered = PlotterSVG.order(collected)
        #expect(PlotterSVG.travel(ordered) < PlotterSVG.travel(collected))
    }
}
