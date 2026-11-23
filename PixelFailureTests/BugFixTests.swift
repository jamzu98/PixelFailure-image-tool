import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import Testing
@testable import PixelFailure

/// Regressions for bugs found in the full-app test pass.
@MainActor
struct BugFixTests {
    private func alphaAndGray(_ image: CGImage, x: Int, y: Int) -> (alpha: UInt8, gray: UInt8) {
        let ctx = ColorSettings.default.makeRGBAContext(width: image.width, height: image.height)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
        // Bitmap rows are top-down.
        let i = (y * image.width + x) * 4
        return (bytes[i + 3], bytes[i])
    }

    /// Left half mid-gray and opaque, right half transparent.
    private func halfGray() -> CGImage {
        let ctx = ColorSettings.default.makeRGBAContext(width: 80, height: 40)!
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        return ctx.makeImage()!
    }

    private func tone(_ mode: PaintSession.RetouchMode) throws -> CGImage {
        let session = try #require(PaintSession(target: .content(layerID: UUID()), base: halfGray(),
                                                pixelSize: CGSize(width: 80, height: 40)))
        for x in stride(from: 5.0, through: 75.0, by: 5.0) {
            session.retouch(to: CGPoint(x: x, y: 20), source: nil, mode: mode,
                            radius: 10, hardness: 0.8, opacity: 1, spacing: 0.2, smoothing: 0)
        }
        return try #require(session.currentImage)
    }

    @Test func burnAndDodgeLeaveTransparentPixelsAlone() throws {
        for mode in [PaintSession.RetouchMode.burn, .dodge] {
            let out = try tone(mode)
            #expect(alphaAndGray(out, x: 70, y: 20).alpha == 0, "\(mode) painted onto transparency")
        }
    }

    @Test func burnDarkensAndDodgeLightens() throws {
        let original = alphaAndGray(halfGray(), x: 20, y: 20).gray
        let burned = alphaAndGray(try tone(.burn), x: 20, y: 20)
        let dodged = alphaAndGray(try tone(.dodge), x: 20, y: 20)
        #expect(burned.gray < original, "burn didn't darken (\(original) → \(burned.gray))")
        #expect(dodged.gray > original, "dodge didn't lighten (\(original) → \(dodged.gray))")
        #expect(burned.alpha == 255 && dodged.alpha == 255)
    }

    @Test func recoveryModelLoadsWithoutImages() throws {
        let document = PixelDocument()
        document.update(nil) { $0.background = .white }
        let url = try RecoveryStore.save(document, identifier: UUID(),
                                         documentURL: URL(fileURLWithPath: "/tmp/pf-x.pixelfailure"))
        defer { try? RecoveryStore.discard(url) }
        #expect(try RecoveryStore.loadModel(url) == document.model)
    }

    /// Recovering an untitled archive used to replace the content of whatever
    /// untitled window showed the prompt (with no undo). It now becomes a
    /// document of its own.
    @Test func untitledRecoveryBecomesItsOwnDocument() throws {
        let crashed = PixelDocument()
        let png = try #require(PNGExporter.pngData(halfGray()))
        _ = try #require(crashed.addImageLayer(data: png, suggestedName: "Photo", undoManager: nil))
        let url = try RecoveryStore.save(crashed, identifier: UUID(), documentURL: nil)
        defer { try? RecoveryStore.discard(url) }
        let archive = try RecoveryStore.load(url)

        let window = PixelDocument()
        let before = window.model
        let recovered = PixelDocument.recovered(from: archive)
        #expect(window.model == before, "the prompting window must keep its content")
        #expect(recovered.model == crashed.model)
        #expect(recovered.isRecovered && !window.isRecovered)
        for key in crashed.model.allLayers.compactMap({ layer -> String? in
            if case .image(let config) = layer.kind { return config.imageKey } else { return nil }
        }) {
            #expect(recovered.images[key] != nil, "image \(key) missing from the recovered document")
        }
        #expect(abs(RecoveryStore.modificationDate(url).timeIntervalSinceNow) < 60)
    }

    @Test func largeWaveTileGridsStayFast() {
        var params = ParamValues(defaults: GeneratorType.waveTiles.generator.specs)
        params.set("columns", 48)
        params.set("tileSet", 2)
        let start = CACurrentMediaTime()
        let out = GeneratorType.waveTiles.generator.generate(
            params: params, seed: 1,
            context: GeneratorContext(size: CGSize(width: 1600, height: 900), palette: BuiltInPalettes.default, sampler: nil))
        let ms = (CACurrentMediaTime() - start) * 1000
        #expect(!out.isEmpty)
        #expect(ms < 1500, "48-column circuit took \(Int(ms)) ms")
    }

    @Test func cpuGlitchesWorkOnSixteenBitImages() {
        let ctx = ColorSettings(workingSpace: .displayP3, bitDepth: .sixteen).makeRGBAContext(width: 120, height: 60)!
        ctx.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 60))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 60, y: 0, width: 60, height: 60))
        let input = ctx.makeImage()!
        for type in [EffectType.pixelSort, .dither] {
            var params = type.defaultParams
            if type == .dither { params.set("method", 3) }
            let out = EffectPipeline.shared.apply(effects: [Effect(type: type, params: params)], to: input,
                                                  palette: BuiltInPalettes.default)
            #expect(out.width == 120 && out.height == 60)
            #expect(out.bitsPerComponent == 16, "\(type) lost 16-bit depth")
        }
    }

    @Test func cloneCopiesFromTheSourceOffset() throws {
        // Red left half, blue right half; clone from the left into the right.
        let ctx = ColorSettings.default.makeRGBAContext(width: 80, height: 40)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 40, y: 0, width: 40, height: 40))
        for (mode, minRed) in [(PaintSession.RetouchMode.clone, UInt8(240)), (.heal, UInt8(60))] {
            let session = try #require(PaintSession(target: .content(layerID: UUID()), base: ctx.makeImage()!,
                                                    pixelSize: CGSize(width: 80, height: 40)))
            session.retouch(to: CGPoint(x: 60, y: 20), source: CGPoint(x: 20, y: 20), mode: mode,
                            radius: 8, hardness: 1, opacity: 1, spacing: 0.2, smoothing: 0)
            let out = try #require(session.currentImage)
            let check = ColorSettings.default.makeRGBAContext(width: 80, height: 40)!
            check.draw(out, in: CGRect(x: 0, y: 0, width: 80, height: 40))
            let bytes = check.data!.assumingMemoryBound(to: UInt8.self)
            let red = bytes[(20 * 80 + 60) * 4]
            #expect(red >= minRed, "\(mode) didn't bring source pixels over (red \(red))")
        }
    }

    /// PSD rows are top-down. The exporter used to flip them, so every layer
    /// and the composite opened upside down in other apps.
    @Test func psdExportIsRightSideUp() throws {
        let document = PixelDocument()
        let store = RenderStore(document: document)
        let ctx = ColorSettings.default.makeRGBAContext(width: 40, height: 40)!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 20, width: 40, height: 20))
        // Core Graphics is y-up, so red is the visual top half.
        let image = ctx.makeImage()!
        let png = try #require(PNGExporter.pngData(image))
        let id = try #require(document.addImageLayer(data: png, suggestedName: "Split", undoManager: nil))
        document.update(nil) { m in
            m.canvasSize = CGSize(width: 40, height: 40)
            m.modifyLayer(id: id) { $0.transform = LayerTransform(position: CGPoint(x: 20, y: 20)) }
        }
        let psd = try #require(PSDExporter.data(model: document.model, renderStore: store))
        func topIsRed(_ image: CGImage) -> Bool {
            let check = ColorSettings.default.makeRGBAContext(width: image.width, height: image.height)!
            check.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = check.data!.assumingMemoryBound(to: UInt8.self) // row 0 = top
            let center = (2 * image.width + image.width / 2) * 4
            return bytes[center] > 200 && bytes[center + 2] < 50
        }
        let decoded = try PSDImporter.decode(psd)
        let layer = try #require(decoded.layers.first)
        #expect(topIsRed(layer.image), "layer pixels are upside down")
        let source = try #require(CGImageSourceCreateWithData(psd as CFData, nil))
        let composite = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(topIsRed(composite), "composite (as other apps read it) is upside down")
    }
}
