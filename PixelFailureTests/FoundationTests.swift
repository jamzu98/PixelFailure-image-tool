import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
@testable import PixelFailure

/// Regression tests for the foundation pass: compositing correctness,
/// export fidelity, storage growth and recovery.
@MainActor
struct FoundationTests {
    private func render(_ document: PixelDocument, store: RenderStore) throws -> ImageSampler {
        let items = store.renderItems(model: document.model, quality: .full)
        let output = try #require(PNGExporter.render(items: items, background: .clear,
                                                     canvasSize: document.model.canvasSize,
                                                     targetPixelSize: document.model.canvasSize))
        return try #require(ImageSampler(cgImage: output, maxDimension: 100))
    }

    private func centered(_ name: String, _ kind: LayerKind, at point: CGPoint = CGPoint(x: 50, y: 50),
                          blendMode: LayerBlendMode = .normal, clips: Bool = false) -> Layer {
        Layer(name: name, blendMode: blendMode,
              transform: LayerTransform(position: point), kind: kind, clipsToBelow: clips)
    }

    private func rect(_ side: CGFloat, _ hex: String) -> LayerKind {
        .shape(ShapeConfig(kind: .rectangle, size: CGSize(width: side, height: side),
                           fill: RGBAColor(hex: hex)))
    }

    private func solid(_ hex: String) -> LayerKind {
        .fill(FillConfig(style: .solid, colors: [RGBAColor(hex: hex)]))
    }

    // MARK: Clipping

    @Test func clippedLayerKeepsItsBlendMode() throws {
        let document = PixelDocument()
        let store = RenderStore(document: document)
        document.update(nil) {
            $0.canvasSize = CGSize(width: 100, height: 100)
            $0.layers = [
                centered("Backdrop", solid("#808080")),
                centered("Base", rect(40, "#FF0000")),
                centered("Clipped", solid("#00FF00"), blendMode: .multiply, clips: true),
            ]
        }
        let sampler = try render(document, store: store)
        // Red × green multiplies to black; a Normal composite would be green.
        let center = sampler.color(atUnitX: 0.5, y: 0.5)
        #expect(center.g < 0.1)
        #expect(center.r < 0.1)
        // Outside the base the clipped layer draws nothing.
        let corner = sampler.color(atUnitX: 0.05, y: 0.05)
        #expect(abs(corner.r - corner.g) < 0.05)
        #expect(corner.r > 0.3)
    }

    @Test func stackedClippedLayersAllClipToTheBase() throws {
        let document = PixelDocument()
        let store = RenderStore(document: document)
        document.update(nil) {
            $0.canvasSize = CGSize(width: 100, height: 100)
            $0.layers = [
                centered("Base", rect(40, "#FF0000")),
                centered("Small", rect(10, "#00FF00"), at: CGPoint(x: 35, y: 35), clips: true),
                centered("Wash", solid("#0000FF"), clips: true),
            ]
        }
        let sampler = try render(document, store: store)
        // Inside the base but outside the first clipped layer: the wash must
        // still show, because it clips to the base, not to "Small".
        let inside = sampler.color(atUnitX: 0.62, y: 0.62)
        #expect(inside.a > 0.9)
        #expect(inside.b > 0.9)
        #expect(sampler.color(atUnitX: 0.05, y: 0.05).a < 0.1)
    }

    @Test func clippedLayerOpacityAppliesOnce() throws {
        let document = PixelDocument()
        let store = RenderStore(document: document)
        var clipped = centered("Clipped", solid("#FFFFFF"), clips: true)
        clipped.opacity = 0.5
        document.update(nil) {
            $0.canvasSize = CGSize(width: 100, height: 100)
            $0.layers = [centered("Base", rect(40, "#000000")), clipped]
        }
        let center = try render(document, store: store).color(atUnitX: 0.5, y: 0.5)
        // 50% white over black ≈ 0.5 (sRGB-encoded), not 0.25.
        #expect(abs(center.r - 0.5) < 0.06)
    }

    // MARK: PSD export

    @Test func psdExportAppliesOpacityOnlyInTheLayerRecord() throws {
        let document = PixelDocument()
        let store = RenderStore(document: document)
        var faded = centered("Fäded ✦", solid("#FF0000"), at: CGPoint(x: 20, y: 20), blendMode: .multiply)
        faded.opacity = 0.5
        document.update(nil) {
            $0.canvasSize = CGSize(width: 40, height: 40)
            $0.layers = [faded]
        }
        let psd = try #require(PSDExporter.data(model: document.model, renderStore: store))
        let decoded = try PSDImporter.decode(psd)
        let layer = try #require(decoded.layers.first)
        #expect(abs(layer.opacity - 0.5) < 0.01)
        #expect(layer.blendMode == .multiply)
        #expect(layer.name == "Fäded ✦")
        let sampler = try #require(ImageSampler(cgImage: layer.image, maxDimension: 40))
        // Pixels stay at full strength; Photoshop applies the 50% itself.
        #expect(sampler.color(atUnitX: 0.5, y: 0.5).a > 0.98)
    }

    @Test func psdExportKeepsAdjustmentLayersAsPixels() throws {
        let document = PixelDocument()
        let store = RenderStore(document: document)
        var params = EffectType.adjust.defaultParams
        params.set("exposure", 1)
        let adjustment = centered("Brighten", .adjustment(AdjustmentConfig(effects: [
            Effect(type: .adjust, params: params),
        ])))
        document.update(nil) {
            $0.canvasSize = CGSize(width: 40, height: 40)
            $0.layers = [centered("Base", solid("#404040"), at: CGPoint(x: 20, y: 20)), adjustment]
        }
        let psd = try #require(PSDExporter.data(model: document.model, renderStore: store))
        let decoded = try PSDImporter.decode(psd)
        #expect(decoded.layers.map(\.name) == ["Brighten", "Base"])
    }
}

@MainActor
struct ImageStoreTests {
    private func pngData(_ gray: CGFloat) throws -> Data {
        let context = try #require(ColorSettings.default.makeRGBAContext(width: 4, height: 4))
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try #require(context.makeImage())
        return try #require(PNGExporter.pngData(image))
    }

    @Test func savedPackageKeepsOnlyReachableImages() throws {
        let document = PixelDocument()
        let first = document.storeImage(data: try pngData(0), fileExtension: "png")
        let layer = Layer(name: "Paint", transform: LayerTransform(position: CGPoint(x: 2, y: 2)),
                          kind: .image(ImageConfig(imageKey: first, pixelSize: CGSize(width: 4, height: 4))))
        document.update(nil) { $0.layers = [layer] }
        document.createCheckpoint(name: "Before strokes")

        // Twenty "strokes", each a new key swapped into the layer.
        var latest = first
        for stroke in 1...20 {
            latest = document.storeImage(data: try pngData(CGFloat(stroke) / 20), fileExtension: "png")
            let key = latest
            document.update(nil) { model in
                model.modifyLayer(id: layer.id) { $0.modifyImage { $0.imageKey = key } }
            }
        }

        let snapshot = try document.snapshot(contentType: .pixelFailureProject)
        // The current stroke plus the image the named snapshot still shows.
        #expect(Set(snapshot.images.keys) == [first, latest])
        // Undo still works: older keys remain in memory.
        #expect(document.imageData(for: first) != nil)
    }
}

@MainActor
struct RecoveryTests {
    @Test func backgroundRecoveryWritesIncrementallyAndLoads() async throws {
        let document = PixelDocument()
        let context = try #require(ColorSettings.default.makeRGBAContext(width: 4, height: 4))
        let blank = try #require(context.makeImage())
        let png = try #require(PNGExporter.pngData(blank))
        let key = document.storeImage(data: png, fileExtension: "png")
        document.update(nil) {
            $0.layers.append(Layer(name: "Photo", transform: LayerTransform(position: .zero),
                                   kind: .image(ImageConfig(imageKey: key,
                                                            pixelSize: CGSize(width: 4, height: 4)))))
        }
        let identifier = UUID()
        let url = try await RecoveryStore.saveInBackground(document, identifier: identifier)
        defer { try? RecoveryStore.discard(url) }
        let imageFile = url.appendingPathComponent("images").appendingPathComponent(key)
        let firstWrite = try imageFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        document.update(nil) { $0.background = .black }
        try await Task.sleep(for: .milliseconds(20))
        try await RecoveryStore.saveInBackground(document, identifier: identifier)
        let secondWrite = try imageFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(firstWrite == secondWrite) // unchanged image not rewritten

        let archive = try RecoveryStore.load(url)
        #expect(archive.model == document.model)
        #expect(archive.images[key] == png)
    }

    @Test func recoveryIsOnlyOfferedToTheDocumentThatWroteIt() throws {
        let fileA = URL(fileURLWithPath: "/tmp/pf-recovery-test/A.pixelfailure")
        let fileB = URL(fileURLWithPath: "/tmp/pf-recovery-test/B.pixelfailure")
        let onDisk = PixelDocument().model
        let edited = PixelDocument()
        edited.update(nil) { $0.background = RGBAColor(hex: "#123456") }

        let identifier = UUID()
        let url = try RecoveryStore.save(edited, identifier: identifier, documentURL: fileA)
        defer { try? RecoveryStore.discard(url) }
        #expect(RecoveryStore.owner(of: url) == RecoveryStore.documentPath(fileA))

        // Another document, or an untitled window, never sees A's autosave.
        #expect(RecoveryStore.recoverableArchive(for: fileB, currentModel: onDisk)?.path != url.path)
        #expect(RecoveryStore.recoverableArchive(for: nil, currentModel: onDisk)?.path != url.path)
        // A itself gets it back.
        #expect(RecoveryStore.recoverableArchive(for: fileA, currentModel: onDisk)?.path == url.path)
        // Nothing to recover when the window already shows the same content,
        // and the spent archive is cleaned up.
        #expect(RecoveryStore.recoverableArchive(for: fileA, currentModel: edited.model) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func liveWindowsAutosavesAreNeverOffered() throws {
        let file = URL(fileURLWithPath: "/tmp/pf-recovery-test/Live.pixelfailure")
        let edited = PixelDocument()
        edited.update(nil) { $0.background = RGBAColor(hex: "#654321") }
        let identifier = UUID()
        let url = try RecoveryStore.save(edited, identifier: identifier, documentURL: file)
        defer { try? RecoveryStore.discard(url) }
        RecoveryStore.markLive(identifier)
        // A second window opening the same file must not pick up the first
        // window's in-progress autosave.
        #expect(RecoveryStore.recoverableArchive(for: file, currentModel: PixelDocument().model) == nil)
        RecoveryStore.discard(identifier: identifier)
    }

    @Test func legacySingleFileArchivesStillLoad() throws {
        let document = PixelDocument()
        let legacy = RecoveryArchive(savedAt: Date(), model: document.model, images: [:], checkpoints: [])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("recovery")
        try JSONEncoder().encode(legacy).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try RecoveryStore.load(url).model == document.model)
    }
}

@MainActor
struct ProgressiveRenderTests {
    @Test func fullQualityEffectsRenderOffMainBehindAPlaceholder() async throws {
        let document = PixelDocument()
        let store = RenderStore(document: document)
        let context = try #require(ColorSettings.default.makeRGBAContext(width: 3000, height: 2000))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        let photo = try #require(context.makeImage())
        let encoded = try #require(PNGExporter.pngData(photo))
        let key = document.storeImage(data: encoded, fileExtension: "png")
        let layer = Layer(name: "Photo", transform: LayerTransform(position: CGPoint(x: 1500, y: 1000)),
                          kind: .image(ImageConfig(imageKey: key, pixelSize: CGSize(width: 3000, height: 2000),
                                                   effects: [Effect(type: .blur)])))
        document.update(nil) {
            $0.canvasSize = CGSize(width: 3000, height: 2000)
            $0.layers = [layer]
        }

        func rasterWidth(_ items: [RenderItem]) -> Int? {
            guard case .raster(let image) = items.first?.content else { return nil }
            return image.width
        }

        // Warm the preview tier, as the viewport does before going idle.
        let preview = store.renderItems(model: document.model, quality: .preview, progressive: true)
        #expect(rasterWidth(preview) == 1600)

        let revision = store.viewportInvalidation.revision
        let placeholder = store.renderItems(model: document.model, quality: .full, progressive: true)
        #expect(rasterWidth(placeholder) == 1600)

        for _ in 0..<200 where store.viewportInvalidation.revision == revision {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(store.viewportInvalidation.revision != revision)
        let full = store.renderItems(model: document.model, quality: .full, progressive: true)
        #expect(rasterWidth(full) == 3000)

        // Exporters never see placeholders.
        var changed = document.model
        changed.palette = BuiltInPalettes.default.harmony(.complementary)
        #expect(rasterWidth(store.renderItems(model: changed, quality: .full)) == 3000)
    }
}

extension PixelDocument {
    /// Waits for a background pixel bake to commit (or give up after 10 s).
    @MainActor
    func waitForBackgroundTask() async {
        for _ in 0..<400 where backgroundTaskLabel != nil {
            try? await Task.sleep(for: .milliseconds(25))
        }
        // The commit runs right after the label clears, on this actor.
        await Task.yield()
    }
}

@MainActor
struct BackgroundBakeTests {
    @Test func superResolutionRefusesOversizedLayers() throws {
        let document = PixelDocument()
        let store = RenderStore(document: document)
        let context = try #require(ColorSettings.default.makeRGBAContext(width: 9000, height: 8))
        let image = try #require(context.makeImage())
        let encoded = try #require(PNGExporter.pngData(image))
        let key = document.storeImage(data: encoded, fileExtension: "png")
        let layer = Layer(name: "Wide", transform: LayerTransform(position: .zero),
                          kind: .image(ImageConfig(imageKey: key, pixelSize: CGSize(width: 9000, height: 8))))
        document.update(nil) { $0.layers = [layer] }
        #expect(document.superResolveLayer(layerID: layer.id, renderStore: store, undoManager: nil) == .tooLarge)
        #expect(document.backgroundTaskLabel == nil)
    }

    @Test func contentAwareFillCommitsOffMainAsOneStep() async throws {
        let document = PixelDocument()
        let store = RenderStore(document: document)
        let context = try #require(ColorSettings.default.makeRGBAContext(width: 64, height: 64))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 24, y: 24, width: 16, height: 16))
        let image = try #require(context.makeImage())
        let encoded = try #require(PNGExporter.pngData(image))
        let key = document.storeImage(data: encoded, fileExtension: "png")
        let layer = Layer(name: "Photo", transform: LayerTransform(position: CGPoint(x: 32, y: 32)),
                          kind: .image(ImageConfig(imageKey: key, pixelSize: CGSize(width: 64, height: 64))))
        document.update(nil) {
            $0.canvasSize = CGSize(width: 64, height: 64)
            $0.layers = [layer]
        }
        let selection = CanvasSelection(path: Path(CGRect(x: 20, y: 20, width: 24, height: 24)))
        document.contentAwareFill(selection: selection, layerID: layer.id, renderStore: store, undoManager: nil)
        #expect(document.backgroundTaskLabel == "Content-Aware Fill")
        await document.waitForBackgroundTask()
        let baked = try #require(document.model.layer(id: layer.id)?.imageConfig)
        #expect(baked.imageKey != key)
        #expect(document.model.layer(id: layer.id)?.source != nil)
    }
}

@MainActor
struct PaintThroughputTests {
    @Test func bufferSnapshotsOnlyWhenAsked() throws {
        let session = try #require(PaintSession(target: .content(layerID: UUID()), base: nil,
                                                pixelSize: CGSize(width: 64, height: 64)))
        let first = try #require(session.currentImage)
        #expect(session.currentImage === first) // no stroke, no new snapshot
        session.stroke(to: CGPoint(x: 32, y: 32), radius: 6, hardness: 0.8, opacity: 1,
                       color: RGBAColor(hex: "#FF0000"), erase: false)
        let second = try #require(session.currentImage)
        #expect(second !== first)
        #expect(session.currentImage === second)
    }

    @Test func smudgeDragsNeighbouringPixels() throws {
        let context = try #require(ColorSettings.default.makeRGBAContext(width: 64, height: 64))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 32, y: 0, width: 32, height: 64))
        let base = try #require(context.makeImage())
        let session = try #require(PaintSession(target: .content(layerID: UUID()), base: base,
                                                pixelSize: CGSize(width: 64, height: 64)))
        for x in stride(from: 20.0, through: 44.0, by: 2.0) {
            session.retouch(to: CGPoint(x: x, y: 32), source: nil, mode: .smudge,
                            radius: 6, hardness: 0.8, opacity: 1, spacing: 0.2, smoothing: 0)
        }
        let result = try #require(session.currentImage)
        let sampler = try #require(ImageSampler(cgImage: result, maxDimension: 64))
        // Red was dragged into the blue half along the stroke...
        #expect(sampler.color(atUnitX: 38.0 / 64, y: 0.5).r > 0.15)
        // ...but not far away from it.
        #expect(sampler.color(atUnitX: 38.0 / 64, y: 0.05).r < 0.05)
    }
}
