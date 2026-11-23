import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import PixelFailure

/// End-to-end sweep: a document holding every layer kind, every editor
/// command and document operation run against it, and the same invariants
/// checked after each step (renders, exports, save, undo, unique ids).
///
/// Takes several minutes, so it's opt-in:
/// `TEST_RUNNER_PF_SWEEP=1 xcodebuild … test`
@Suite("App sweep", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PF_SWEEP"] != nil, "Set PF_SWEEP=1 to run the full sweep"))
@MainActor
struct AppSweepTests {
    // MARK: Fixture

    static func photoData(_ w: Int = 400, _ h: Int = 300) -> Data {
        let ctx = ColorSettings.default.makeRGBAContext(width: w, height: h)!
        let colors = [CGColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 1), CGColor(red: 0.1, green: 0.2, blue: 0.6, alpha: 1)] as CFArray
        ctx.drawLinearGradient(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!,
                               start: .zero, end: CGPoint(x: w, y: h), options: [])
        ctx.setFillColor(CGColor(red: 0.2, green: 0.8, blue: 0.3, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: w / 4, y: h / 4, width: w / 3, height: h / 3))
        return PNGExporter.pngData(ctx.makeImage()!)!
    }

    struct Fixture {
        let document: PixelDocument
        let store: RenderStore
        let state: EditorState
        let undo: UndoManager
        var focus: EditorFocus { EditorFocus(document: document, editorState: state, renderStore: store, undoManager: undo) }
    }

    static func richFixture(colorSettings: ColorSettings = .default) -> Fixture {
        let document = PixelDocument(model: {
            var m = ProjectModel()
            m.canvasSize = CGSize(width: 800, height: 600)
            m.colorSettings = colorSettings
            return m
        }())
        let store = RenderStore(document: document)
        let undo = UndoManager()
        undo.groupsByEvent = false
        let photo = document.addImageLayer(data: photoData(), suggestedName: "Photo", undoManager: nil)!
        document.update(nil) { m in
            m.modifyLayer(id: photo) { layer in
                layer.modifyImage { $0.effects = [Effect(type: .adjust, params: EffectType.adjust.defaultParams),
                                                  Effect(type: .datamosh, params: EffectType.datamosh.defaultParams)] }
            }
        }
        document.addMask(to: photo, hideAll: false, renderStore: store, undoManager: nil)
        _ = document.addPatternLayer(.flowField, undoManager: nil)
        let rings = document.addPatternLayer(.rings, undoManager: nil)
        document.update(nil) { m in m.modifyLayer(id: rings) { $0.clipsToBelow = true; $0.blendMode = .multiply } }
        _ = document.addPatternLayer(.voronoi, undoManager: nil)
        let text = document.addTextLayer(undoManager: nil)
        let kaleido = document.addPatternLayer(.circlePacking, undoManager: nil)
        document.update(nil) { m in
            m.modifyLayer(id: kaleido) { layer in
                layer.modifyPattern {
                    $0.params.set("stage.symmetry", 5)
                    $0.params.set("stage.region", 1)
                    $0.regionLayerID = text
                }
            }
        }
        for kind in ShapeKind.allCases { _ = document.addShapeLayer(kind, undoManager: nil) }
        _ = document.addFillLayer(undoManager: nil)
        let path = document.addPathLayer(firstPoint: CGPoint(x: 100, y: 100), undoManager: nil)
        for point in [CGPoint(x: 300, y: 120), CGPoint(x: 260, y: 400), CGPoint(x: 120, y: 380)] {
            document.addPathNode(to: path, canvasPoint: point, undoManager: nil)
        }
        let a = document.addShapeLayer(.ellipse, undoManager: nil)
        let b = document.addShapeLayer(.star, undoManager: nil)
        _ = document.groupLayers(ids: [a, b], undoManager: nil)
        _ = document.addAdjustmentLayer(undoManager: nil)
        _ = document.addPaintLayer(undoManager: nil)
        return Fixture(document: document, store: store, state: EditorState(), undo: undo)
    }

    // MARK: Invariants

    /// Labels whose export checks already ran (exports are the slow part).
    static var exportedKinds = Set<String>()

    static func checkInvariants(_ f: Fixture, _ label: String, exports: Bool = false) {
        let model = f.document.model
        // Unique ids across the whole tree.
        let ids = model.allLayers.map(\.id)
        #expect(Set(ids).count == ids.count, "\(label): duplicate layer ids")
        // Finite transforms.
        for layer in model.allLayers {
            let t = layer.transform
            let values = [t.position.x, t.position.y, t.scale, t.rotationDegrees]
            #expect(values.allSatisfy { $0.isFinite }, "\(label): non-finite transform on \(layer.name)")
        }
        // Every tier renders.
        for quality in exports ? [RenderQuality.proxy, .preview, .full] : [.preview] {
            let items = f.store.renderItems(model: model, quality: quality)
            let image = PNGExporter.render(items: items, background: model.background, canvasSize: model.canvasSize,
                                           targetPixelSize: CGSize(width: 200, height: 150),
                                           colorSettings: model.colorSettings)
            #expect(image != nil, "\(label): \(quality) render failed")
        }
        if exports {
        // Thumbnails.
        for layer in model.allLayers where layer.kind.isGroup == false && !layer.kind.isAdjustment {
            _ = f.store.thumbnail(for: layer, model: model)
        }
        // SVG parses.
        let items = f.store.renderItems(model: model, quality: .full)
        let svg = SVGExporter.svg(items: items, background: model.background, canvasSize: model.canvasSize,
                                  skippedGlobalEffects: !model.canvasEffects.isEmpty,
                                  workingSpace: model.colorSettings.workingSpace)
        let parser = XMLParser(data: Data(svg.utf8))
        #expect(parser.parse(), "\(label): SVG is not valid XML (\(parser.parserError.map { "\($0)" } ?? "?"))")
        let plotter = PlotterSVG.svg(items: items, canvasSize: model.canvasSize)
        #expect(XMLParser(data: Data(plotter.utf8)).parse(), "\(label): plotter SVG is not valid XML")
        // PSD round-trips when there's anything to write.
        if !model.layers.isEmpty, let psd = PSDExporter.data(model: model, renderStore: f.store) {
            #expect((try? PSDImporter.decode(psd)) != nil, "\(label): exported PSD doesn't decode")
        }
        }
        // Saving keeps every image the model or snapshots reference.
        if let snapshot = try? f.document.snapshot(contentType: .pixelFailureProject) {
            let missing = model.referencedImageKeys.subtracting(snapshot.images.keys)
            #expect(missing.isEmpty, "\(label): save would drop images \(missing)")
            let data = try? JSONEncoder().encode(snapshot.model)
            let decoded = data.flatMap { try? JSONDecoder().decode(ProjectModel.self, from: $0) }
            #expect(decoded == snapshot.model, "\(label): manifest doesn't round-trip")
        } else {
            Issue.record("\(label): snapshot failed")
        }
    }

    /// Runs `body` as one undo group, checks invariants, then undoes and
    /// expects the exact prior model back.
    static func step(_ f: Fixture, _ label: String, expectsUndo: Bool = true, _ body: () -> Void) {
        let before = f.document.model
        f.undo.beginUndoGrouping()
        body()
        f.undo.endUndoGrouping()
        // Full export checks once per kind of step (the label's first word).
        let kind = String(label.split(separator: " ").first ?? "")
        checkInvariants(f, label, exports: exportedKinds.insert(kind).inserted)
        guard f.document.model != before else { return }
        if expectsUndo {
            #expect(f.undo.canUndo, "\(label): changed the model without an undo step")
            f.undo.undo()
            #expect(f.document.model == before, "\(label): undo didn't restore the previous state")
        }
    }

    // MARK: Tests

    @Test func fixtureIsHealthy() {
        let f = Self.richFixture()
        #expect(f.document.model.allLayers.count >= 18)
        Self.checkInvariants(f, "fixture", exports: true)
    }

    @Test func everyEditorCommandOnEveryLayer() {
        let f = Self.richFixture()
        // One layer of each kind (plus none): commands behave per kind, not per layer.
        var seenKinds = Set<String>()
        let representatives = f.document.model.allLayers.filter { layer in
            let kind = "\(layer.kind)".prefix(while: { $0 != "(" }) + (layer.clipsToBelow ? "-clipped" : "")
                + (layer.patternConfig?.generator.isRaster == true ? "-raster" : "")
            return seenKinds.insert(String(kind)).inserted
        }
        let layerIDs: [UUID?] = [nil] + representatives.map(\.id)
        for action in ShortcutAction.allCases {
            // App-level commands that open windows or panels.
            if [.newDocument, .newBlankCanvas, .openImageAsCanvas, .showHome, .export, .selectSubject].contains(action) { continue }
            for id in layerIDs {
                f.state.selectedLayerID = id
                let isImage = f.document.model.layer(id: id)?.kind.isImage == true
                let selections: [CanvasSelection?] = isImage || id == nil
                    ? [nil, CanvasSelection(path: Path(CGRect(x: 120, y: 90, width: 300, height: 200)))] : [nil]
                for selection in selections {
                    f.state.selection = selection
                    guard EditorActions.canPerform(action, f.focus) else { continue }
                    let name = f.document.model.layer(id: id)?.name ?? "none"
                    Self.step(f, "\(action.rawValue) on \(name)\(selection == nil ? "" : " + selection")") {
                        EditorActions.perform(action, f.focus)
                    }
                }
            }
        }
        // Multi-selection commands.
        f.state.selectedLayerIDs = Set(f.document.model.layers.prefix(4).map(\.id))
        for action in [ShortcutAction.groupLayers, .deleteLayer] where EditorActions.canPerform(action, f.focus) {
            Self.step(f, "\(action.rawValue) on 4 layers") { EditorActions.perform(action, f.focus) }
            f.state.selectedLayerIDs = Set(f.document.model.layers.prefix(4).map(\.id))
        }
    }

    @Test func documentOperationsOnEveryLayer() {
        let f = Self.richFixture()
        let model = f.document.model
        let selection = CanvasSelection(path: Path(ellipseIn: CGRect(x: 150, y: 100, width: 250, height: 200)), feather: 6)
        for layer in model.allLayers {
            let id = layer.id, name = layer.name
            Self.step(f, "duplicate \(name)") { _ = f.document.duplicateLayer(id: id, undoManager: f.undo) }
            Self.step(f, "rasterize \(name)") { f.document.rasterizeLayer(id: id, renderStore: f.store, undoManager: f.undo) }
            Self.step(f, "flip \(name)") { f.document.flipLayer(id: id, horizontally: true, undoManager: f.undo) }
            Self.step(f, "reorder \(name)") { f.document.reorderLayer(id: id, offset: -1, undoManager: f.undo) }
            Self.step(f, "move \(name) to top") { _ = f.document.moveLayer(id: id, to: nil, at: 0, undoManager: f.undo) }
            Self.step(f, "add mask \(name)") { f.document.addMask(to: id, hideAll: true, renderStore: f.store, undoManager: f.undo) }
            Self.step(f, "pattern mask \(name)") {
                f.document.setPatternMask(on: id, generator: .noiseField, renderStore: f.store, undoManager: f.undo)
            }
            Self.step(f, "mask from selection \(name)") {
                f.document.maskFromSelection(selection, layerID: id, renderStore: f.store, undoManager: f.undo)
            }
            if let transfer = f.document.transferPayload(for: id, renderStore: f.store) {
                Self.step(f, "paste copy of \(name)") { _ = f.document.pasteLayer(transfer, undoManager: f.undo) }
            }
            Self.step(f, "keyframe \(name)") { _ = f.document.captureAnimationKeyframe(layerID: id, time: 1, undoManager: f.undo) }
            Self.step(f, "delete \(name)") { f.document.deleteLayer(id: id, undoManager: f.undo) }
            if layer.kind.isImage {
                Self.step(f, "delete pixels \(name)") {
                    f.document.deletePixels(selection: selection, layerID: id, renderStore: f.store, undoManager: f.undo)
                }
                Self.step(f, "fill pixels \(name)") {
                    f.document.fillPixels(selection: selection, layerID: id, color: .white, renderStore: f.store, undoManager: f.undo)
                }
                Self.step(f, "layer from selection \(name)") {
                    _ = f.document.layerFromSelection(selection, layerID: id, renderStore: f.store, undoManager: f.undo)
                }
                Self.step(f, "perspective crop \(name)") {
                    f.document.perspectiveCrop(to: id, renderStore: f.store, undoManager: f.undo)
                }
            }
            if layer.kind.isPattern {
                Self.step(f, "reroll \(name)") { f.document.reroll(layerID: id, randomizeParams: true, undoManager: f.undo) }
            }
        }
        let ids = Set(model.layers.map(\.id))
        for edge in PixelDocument.AlignEdge.allCases {
            Self.step(f, "align \(edge)") { f.document.alignLayers(ids: ids, edge: edge, renderStore: f.store, undoManager: f.undo) }
        }
        Self.step(f, "distribute") { f.document.distributeLayers(ids: ids, horizontally: true, renderStore: f.store, undoManager: f.undo) }
        let shapes = Set(model.layers.filter { $0.kind.isShape || $0.kind.isPath }.map(\.id))
        for op in PixelDocument.BooleanPathOperation.allCases {
            Self.step(f, "boolean \(op)") { _ = f.document.booleanPath(ids: shapes, operation: op, undoManager: f.undo) }
        }
        Self.step(f, "crop canvas") { f.document.cropCanvas(rect: CGRect(x: 50, y: 40, width: 500, height: 400), undoManager: f.undo) }
        Self.step(f, "resize canvas") { f.document.setCanvasSize(CGSize(width: 1200, height: 500), undoManager: f.undo) }
        Self.step(f, "group all") { _ = f.document.groupLayers(ids: ids, undoManager: f.undo) }
        Self.step(f, "delete all") { f.document.deleteLayers(ids: ids, undoManager: f.undo) }
    }

    @Test func everyGeneratorAndStageCombinationRendersInTheStore() {
        let f = Self.richFixture()
        let id = f.document.addPatternLayer(.flowField, undoManager: nil)
        for type in GeneratorType.allCases {
            for stages in [[:], ["stage.symmetry": 4.0, "stage.segments": 5], ["stage.repeat": 2, "stage.brick": 1],
                           ["stage.color": 1]] as [[String: Double]] {
                Self.step(f, "\(type) \(stages)") {
                    f.document.update(f.undo, actionName: "Test") { m in
                        m.modifyLayer(id: id) { layer in
                            layer.modifyPattern { p in
                                p.generator = type
                                p.params = ParamValues(defaults: type.generator.specs)
                                for (k, v) in stages { p.params.set(k, v) }
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func everyEffectOnImageAndAdjustmentLayersInEveryColorMode() {
        for settings in [ColorSettings.default, ColorSettings(workingSpace: .displayP3, bitDepth: .sixteen)] {
            let f = Self.richFixture(colorSettings: settings)
            let photo = f.document.model.allLayers.first { $0.kind.isImage }!.id
            let adjustment = f.document.model.allLayers.first { $0.kind.isAdjustment }!.id
            for type in EffectType.allCases {
                Self.step(f, "\(type) on image \(settings.workingSpace)") {
                    f.document.update(f.undo, actionName: "Effect") { m in
                        m.modifyLayer(id: photo) { $0.modifyImage { $0.effects = [Effect(type: type, params: type.defaultParams)] } }
                    }
                }
                Self.step(f, "\(type) on adjustment \(settings.workingSpace)") {
                    f.document.update(f.undo, actionName: "Effect") { m in
                        m.modifyLayer(id: adjustment) { layer in
                            if case .adjustment(var config) = layer.kind {
                                config.effects = [Effect(type: type, params: type.defaultParams)]
                                layer.kind = .adjustment(config)
                            }
                        }
                    }
                }
                Self.step(f, "\(type) on canvas \(settings.workingSpace)") {
                    f.document.update(f.undo, actionName: "Effect") { $0.canvasEffects = [Effect(type: type, params: type.defaultParams)] }
                }
            }
        }
    }

    /// Writes the package to disk the way a save does (manifest, images,
    /// snapshots) and reopens it: same model, same pixels.
    @Test func savedPackagesReopenIdentically() throws {
        for settings in [ColorSettings.default, ColorSettings(workingSpace: .displayP3, bitDepth: .sixteen)] {
            let f = Self.richFixture(colorSettings: settings)
            f.document.createCheckpoint(name: "Snap")
            let snapshot = try f.document.snapshot(contentType: .pixelFailureProject)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("pixelfailure")
            defer { try? FileManager.default.removeItem(at: url) }
            try FileManager.default.createDirectory(at: url.appendingPathComponent("images"),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot.model).write(to: url.appendingPathComponent("manifest.json"))
            try JSONEncoder().encode(snapshot.checkpoints).write(to: url.appendingPathComponent("snapshots.json"))
            for (key, data) in snapshot.images {
                try data.write(to: url.appendingPathComponent("images").appendingPathComponent(key))
            }
            let reopened = try PixelDocument(contentsOf: url)
            #expect(reopened.model == f.document.model)
            #expect(reopened.checkpoints.count == 1)
            func pixels(_ doc: PixelDocument) -> Data? {
                let store = RenderStore(document: doc)
                let items = store.renderItems(model: doc.model, quality: .full)
                return PNGExporter.render(items: items, background: doc.model.background,
                                          canvasSize: doc.model.canvasSize,
                                          targetPixelSize: doc.model.canvasSize,
                                          colorSettings: doc.model.colorSettings)
                    .flatMap { $0.dataProvider?.data as Data? }
            }
            #expect(pixels(reopened) == pixels(f.document), "\(settings.workingSpace) reopened document renders differently")
        }
    }

    @Test func animationEvaluatesAcrossTheTimeline() {
        let f = Self.richFixture()
        let pattern = f.document.model.allLayers.first { $0.kind.isPattern }!.id
        _ = f.document.captureAnimationKeyframe(layerID: pattern, time: 0, undoManager: nil)
        if let id = f.document.model.animation.keyframes.last?.id {
            f.document.updateAnimationKeyframe(id, parameter: "curl", value: 2.5, undoManager: nil, actionName: "Test")
        }
        _ = f.document.captureAnimationKeyframe(layerID: pattern, time: 2, undoManager: nil)
        for t in stride(from: 0.0, through: 3.0, by: 0.25) {
            let model = f.document.model.model(at: t)
            #expect(!f.store.renderItems(model: model, quality: .preview).isEmpty, "animation at \(t)")
        }
    }
}
