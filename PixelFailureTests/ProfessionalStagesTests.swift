import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import PixelFailure

@Suite("Stages 4–10 professional workflow")
@MainActor
struct ProfessionalStagesTests {
    private func image(size: Int = 32) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: size, height: size,
                                             bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(RGBAColor(hex: "#D06030").cgColor)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return try #require(context.makeImage())
    }

    @Test func transformBackCompatAndMeshGeometry() throws {
        let json = #"{"position":[10,20],"scale":1,"rotationDegrees":0}"#
        let legacy = try JSONDecoder().decode(LayerTransform.self, from: Data(json.utf8))
        #expect(legacy.skewXDegrees == 0)
        #expect(legacy.deformation == nil)

        let pin = LayerDeformation.cornerPin([
            .zero, CGPoint(x: 1, y: 0.1), CGPoint(x: 0.9, y: 1), CGPoint(x: 0.1, y: 0.9),
        ])
        let triangles = pin.triangles(size: CGSize(width: 200, height: 100))
        #expect(triangles.count == 2)
        let map = try #require(triangles[0].affine)
        #expect(triangles[0].source.0.applying(map) == triangles[0].destination.0)

        let item = RenderItem(id: UUID(), opacity: 1, blendMode: .normal,
                              transform: .identity, naturalSize: CGSize(width: 200, height: 100),
                              content: .fill(FillConfig(style: .solid, colors: [.white])),
                              deformation: pin)
        let svg = SVGExporter.svg(items: [item], background: .black,
                                  canvasSize: CGSize(width: 200, height: 100))
        #expect(svg.contains("clipPath id=\"mesh"))
        #expect(PNGExporter.render(items: [item], background: .black,
                                  canvasSize: CGSize(width: 200, height: 100),
                                  targetPixelSize: CGSize(width: 200, height: 100)) != nil)
    }

    @Test func typographyV2FieldsRoundTripAndAlignVertically() throws {
        let config = TextConfig(text: "office", size: 24, boxSize: CGSize(width: 200, height: 160),
                                verticalAlignment: .bottom, ligatures: true,
                                smallCaps: true, stylisticAlternates: 1)
        let decoded = try JSONDecoder().decode(TextConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded == config)
        let result = TextOutliner.render(config)
        #expect(result.size == CGSize(width: 200, height: 160))
        #expect(!result.primitives.isEmpty)
    }

    @Test func brushPresetRoundTripAndTexturedTipPaints() throws {
        let preset = BrushPreset.builtIns[2]
        let data = try BrushPresetLibrary.export([preset])
        #expect(try BrushPresetLibrary.import(data, fileExtension: "pfbrush") == [preset])
        let base = try image()
        let session = try #require(PaintSession(target: .content(layerID: UUID()), base: base,
                                                pixelSize: CGSize(width: 32, height: 32)))
        let before = PNGExporter.pngData(base)
        session.stroke(to: CGPoint(x: 16, y: 16), radius: 10, hardness: 0.7,
                       opacity: 1, color: .white, erase: false,
                       spacing: preset.spacing, smoothing: preset.smoothing,
                       scatter: preset.scatter, sizeJitter: preset.sizeJitter,
                       opacityJitter: preset.opacityJitter, angleJitter: preset.angleJitter,
                       tipAspect: preset.tipAspect, grain: preset.grain)
        #expect(session.currentImage.flatMap(PNGExporter.pngData) != before)
    }

    @Test func historySnapshotsAndRecoveryPreserveAppendOnlyImages() throws {
        let document = PixelDocument()
        let original = document.model.background
        document.update(nil, actionName: "Background") { $0.background = .white }
        #expect(document.history.last?.name == "Background")
        document.createCheckpoint(name: "White")
        document.update(nil, actionName: "Again") { $0.background = .black }
        let checkpoint = try #require(document.checkpoints.first)
        document.restoreCheckpoint(checkpoint.id, undoManager: nil)
        #expect(document.model.background == .white)
        #expect(document.model.background != original || original == .white)

        let identifier = UUID()
        let url = try RecoveryStore.save(document, identifier: identifier)
        defer { try? RecoveryStore.discard(url) }
        let archive = try RecoveryStore.load(url)
        #expect(archive.model == document.model)
        #expect(archive.checkpoints.count == 1)
    }

    @Test func recentHistoryCapsAtMaxHistoryCount() {
        let document = PixelDocument()
        #expect(document.history.count == 1)
        for i in 0..<(PixelDocument.maxHistoryCount + 25) {
            document.update(nil, actionName: "Edit \(i)") {
                $0.background = RGBAColor(r: Double(i % 255) / 255, g: 0, b: 0, a: 1)
            }
        }
        #expect(document.history.count == PixelDocument.maxHistoryCount)
        #expect(document.history.last?.name == "Edit \(PixelDocument.maxHistoryCount + 24)")
    }

    @Test func photoCompletionEffectsRetainSize() throws {
        let input = try image(size: 48)
        let effects = [EffectType.sharpen, .noiseReduction, .lensCorrection, .rawDevelop].map {
            Effect(type: $0, params: $0.defaultParams)
        }
        let output = EffectPipeline.shared.apply(effects: effects, to: input,
                                                 palette: BuiltInPalettes.default)
        #expect(output.width == input.width)
        #expect(output.height == input.height)
    }

    @Test func printSlicesPSDAndActionsRoundTrip() throws {
        let oldJSON = #"{"canvasSize":[100,50],"background":{"r":0,"g":0,"b":0,"a":1},"layers":[],"palette":{"name":"P","colors":[{"r":0,"g":0,"b":0,"a":1}]}}"#
        let legacy = try JSONDecoder().decode(ProjectModel.self, from: Data(oldJSON.utf8))
        #expect(legacy.printSettings.dpi == 72)
        #expect(legacy.exportSlices.isEmpty)

        let source = try image(size: 16)
        let assets = AssetExporter.assets(from: source,
                                          slices: [ExportSlice(name: "Icon",
                                                               rect: CGRect(x: 0, y: 0, width: 8, height: 8),
                                                               scales: [1, 2, 3])])
        #expect(assets.map(\.scale) == [1, 2, 3])

        var model = ProjectModel(canvasSize: CGSize(width: 32, height: 32), layers: [
            Layer(name: "Orange", transform: LayerTransform(position: CGPoint(x: 16, y: 16)),
                  kind: .shape(ShapeConfig(kind: .rectangle, size: CGSize(width: 24, height: 24)))),
            Layer(name: "Hidden", isVisible: false,
                  transform: LayerTransform(position: CGPoint(x: 16, y: 16)),
                  kind: .shape(ShapeConfig(kind: .ellipse, size: CGSize(width: 12, height: 12)))),
        ])
        let action = RecordedAction(name: "Web", steps: [
            .setDPI(144), .setBackground(RGBAColor(hex: "#102030")),
            .addCanvasEffect(Effect(type: .sharpen, params: EffectType.sharpen.defaultParams)),
        ])
        ActionExecutor.apply(action, to: &model)
        #expect(model.printSettings.dpi == 144)
        #expect(model.canvasEffects.count == 1)

        let document = PixelDocument()
        document.actionRecorder.start()
        document.update(nil) { $0 = model }
        let recorded = document.actionRecorder.stop(name: "Captured")
        #expect(recorded.steps.contains(.setDPI(144)))
        let store = RenderStore(document: document)
        let psd = try #require(PSDExporter.data(model: model, renderStore: store))
        let decodedPSD = try PSDImporter.decode(psd)
        #expect(decodedPSD.size == model.canvasSize)
        #expect(decodedPSD.layers.count == 2)
        #expect(Set(decodedPSD.layers.map(\.name)) == ["Orange", "Hidden"])
    }
}
