import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
@testable import PixelFailure

/// Builds a matte whose coverage ramps 0→255 left to right.
private func gradientMatte(canvas: CGSize, width: Int = 100, height: Int = 100) -> SelectionMatte? {
    var pixels = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            pixels[y * width + x] = UInt8(x * 255 / (width - 1))
        }
    }
    return SelectionMatte(width: width, height: height, canvasSize: canvas, pixels: pixels)
}

@MainActor
private func imageLayerDocument(pixel: Int = 100, canvas: CGFloat = 1000,
                                transform: LayerTransform? = nil) throws -> (PixelDocument, RenderStore, Layer) {
    let document = PixelDocument()
    let store = RenderStore(document: document)
    let ctx = try #require(CGContext(data: nil, width: pixel, height: pixel,
                                     bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: pixel, height: pixel))
    let red = try #require(ctx.makeImage())
    let png = try #require(PNGExporter.pngData(red))
    let key = document.storeImage(data: png, fileExtension: "png")
    let layer = Layer(name: "Red",
                      transform: transform ?? LayerTransform(position: CGPoint(x: canvas / 2, y: canvas / 2),
                                                             scale: canvas / CGFloat(pixel)),
                      kind: .image(ImageConfig(imageKey: key,
                                               pixelSize: CGSize(width: pixel, height: pixel))))
    document.update(nil) { model in
        model.canvasSize = CGSize(width: canvas, height: canvas)
        model.layers = [layer]
    }
    return (document, store, layer)
}

@MainActor
private func layerSampler(_ document: PixelDocument, _ id: UUID) throws -> ImageSampler {
    let key = try #require(document.model.layer(id: id)?.imageConfig?.imageKey)
    let data = try #require(document.imageData(for: key))
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    return try #require(ImageSampler(cgImage: image, maxDimension: max(image.width, image.height)))
}

@MainActor
struct SelectionMatteTests {
    let canvas = CGSize(width: 1000, height: 1000)

    @Test func rasterizedPathMatchesPathTopDown() throws {
        // Top-left quadrant: asymmetric, so any vertical flip shows up.
        let path = Path(CGRect(x: 0, y: 0, width: 500, height: 500))
        let matte = try #require(SelectionMatte.rasterize(path, canvasSize: canvas, width: 100, height: 100))
        #expect(matte.pixels[10 * 100 + 10] == 255)      // top-left row/col
        #expect(matte.pixels[90 * 100 + 10] == 0)        // bottom-left
        #expect(matte.pixels[10 * 100 + 90] == 0)        // top-right
        let contour = try #require(matte.contourPath())
        #expect(contour.contains(CGPoint(x: 250, y: 250), eoFill: true))
        #expect(!contour.contains(CGPoint(x: 250, y: 750), eoFill: true))
    }

    @Test func matteDeleteMatchesPathDeleteOrientation() throws {
        let path = Path(CGRect(x: 0, y: 0, width: 500, height: 500))
        let matte = try #require(SelectionMatte.rasterize(path, canvasSize: canvas, width: 200, height: 200))
        let soft = try #require(CanvasSelection(matte: matte))
        #expect(soft.matte != nil)

        let (document, store, layer) = try imageLayerDocument()
        document.deletePixels(selection: soft, layerID: layer.id, renderStore: store, undoManager: nil)
        let sampler = try layerSampler(document, layer.id)
        #expect(sampler.color(atUnitX: 0.25, y: 0.25).a < 0.1, "top-left should be cleared")
        #expect(sampler.color(atUnitX: 0.25, y: 0.75).a > 0.9, "bottom-left should stay")
        #expect(sampler.color(atUnitX: 0.75, y: 0.25).a > 0.9, "top-right should stay")
    }

    @Test func matteRespectsFlippedLayers() throws {
        var transform = LayerTransform(position: CGPoint(x: 500, y: 500), scale: 10)
        transform.flippedVertically = true
        let (document, store, layer) = try imageLayerDocument(transform: transform)
        let matte = try #require(SelectionMatte.rasterize(Path(CGRect(x: 0, y: 0, width: 1000, height: 500)),
                                                          canvasSize: canvas, width: 100, height: 100))
        let selection = try #require(CanvasSelection(matte: matte))
        document.deletePixels(selection: selection,
                              layerID: layer.id, renderStore: store, undoManager: nil)
        let sampler = try layerSampler(document, layer.id)
        // Canvas top half = buffer bottom half on a vertically flipped layer.
        #expect(sampler.color(atUnitX: 0.5, y: 0.75).a < 0.1)
        #expect(sampler.color(atUnitX: 0.5, y: 0.25).a > 0.9)
    }

    @Test func softMatteProducesPartialAlpha() throws {
        let matte = try #require(gradientMatte(canvas: canvas))
        let selection = try #require(CanvasSelection(matte: matte))
        let mask = try #require(SelectionRasterizer.colorMask(selection: selection,
                                                              transform: CGAffineTransform(scaleX: 0.1, y: 0.1),
                                                              pixelSize: CGSize(width: 100, height: 100)))
        let sampler = try #require(ImageSampler(cgImage: mask, maxDimension: 100))
        let mid = sampler.color(atUnitX: 0.5, y: 0.5).a
        #expect(mid > 0.3 && mid < 0.7, "mid alpha \(mid)")
        #expect(sampler.color(atUnitX: 0.02, y: 0.5).a < 0.1)
        #expect(sampler.color(atUnitX: 0.98, y: 0.5).a > 0.9)
    }

    @Test func booleansKeepSoftValuesAndPathOnlyStaysVector() throws {
        let gradient = try #require(gradientMatte(canvas: canvas))
        let soft = try #require(CanvasSelection(matte: gradient))
        let union = try #require(soft.combined(with: CanvasSelection(path: Path(CGRect(x: 0, y: 0, width: 200, height: 1000))), .add))
        let um = try #require(union.matte)
        #expect(um.pixels[50 * um.width + um.width / 20] == 255)          // inside the rect
        let midValue = um.pixels[50 * um.width + um.width / 2]
        #expect(midValue > 90 && midValue < 170, "gradient kept: \(midValue)")

        let inverted = soft.inverted(canvasSize: canvas)
        let im = try #require(inverted.matte)
        #expect(im.pixels[50 * im.width] > 250)

        let a = CanvasSelection(path: Path(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let pathUnion = try #require(CanvasSelection.combine(existing: a,
                                                             new: CanvasSelection(path: Path(CGRect(x: 50, y: 0, width: 100, height: 100))),
                                                             mode: .add))
        #expect(pathUnion.matte == nil)
        #expect(abs(pathUnion.bounds.width - 150) < 1)
    }

    @Test func intersectAndSubtractModes() throws {
        let left = CanvasSelection(path: Path(CGRect(x: 0, y: 0, width: 600, height: 1000)))
        let rightMatte = try #require(SelectionMatte.rasterize(Path(CGRect(x: 400, y: 0, width: 600, height: 1000)),
                                                               canvasSize: canvas, width: 100, height: 100))
        let right = try #require(CanvasSelection(matte: rightMatte))
        let both = try #require(CanvasSelection.combine(existing: left, new: right, mode: .intersect))
        #expect(both.contains(CGPoint(x: 500, y: 500)))
        #expect(!both.contains(CGPoint(x: 200, y: 500)))
        let minus = try #require(CanvasSelection.combine(existing: left, new: right, mode: .subtract))
        #expect(minus.contains(CGPoint(x: 200, y: 500)))
        #expect(!minus.contains(CGPoint(x: 500, y: 500)))
    }

    @Test func offsetGrowsMatte() throws {
        let matte = try #require(SelectionMatte.rasterize(Path(CGRect(x: 400, y: 400, width: 200, height: 200)),
                                                          canvasSize: canvas, width: 500, height: 500))
        let selection = try #require(CanvasSelection(matte: matte))
        let grown = try #require(SelectionTransforms.offset(selection, by: 50, canvasSize: canvas))
        #expect(grown.matte != nil)
        #expect(grown.bounds.width > 260)
        let shrunk = try #require(SelectionTransforms.offset(selection, by: -50, canvasSize: canvas))
        #expect(shrunk.bounds.width < 140)
    }

    @Test func combineModeFromModifiers() {
        #expect(SelectionCombineMode(modifiers: []) == .replace)
        #expect(SelectionCombineMode(modifiers: .shift) == .add)
        #expect(SelectionCombineMode(modifiers: .option) == .subtract)
        #expect(SelectionCombineMode(modifiers: [.shift, .option]) == .intersect)
    }

    @Test func paintClipMaskBlocksOutside() throws {
        // White = paintable on the left half only.
        let mask = try #require(SelectionRasterizer.grayMask(
            selection: CanvasSelection(path: Path(CGRect(x: 0, y: 0, width: 50, height: 100))),
            transform: .identity, pixelSize: CGSize(width: 100, height: 100)))
        let session = try #require(PaintSession(target: .content(layerID: UUID()), base: nil,
                                                pixelSize: CGSize(width: 100, height: 100), clipMask: mask))
        session.stroke(to: CGPoint(x: 5, y: 50), radius: 60, hardness: 1, opacity: 1,
                       color: .white, erase: false)
        let image = try #require(session.currentImage)
        let sampler = try #require(ImageSampler(cgImage: image, maxDimension: 100))
        #expect(sampler.color(atUnitX: 0.25, y: 0.5).a > 0.9)
        #expect(sampler.color(atUnitX: 0.75, y: 0.5).a < 0.1)
    }
}

// MARK: - Faces, geometry, Vision

/// A synthetic upright face in a 200×240 box at (100, 100), canvas y-down.
private func syntheticFace() -> FaceLandmarkPoints {
    func ellipse(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat, _ n: Int = 8) -> [CGPoint] {
        (0..<n).map { i in
            let a = CGFloat(i) / CGFloat(n) * 2 * .pi
            return CGPoint(x: c.x + cos(a) * rx, y: c.y + sin(a) * ry)
        }
    }
    // Jaw: half-ellipse below the eye line, left ear → chin → right ear.
    let jaw = (0...10).map { i -> CGPoint in
        let a = CGFloat.pi - CGFloat(i) / 10 * .pi
        return CGPoint(x: 200 + cos(a) * 100, y: 200 + sin(a) * 130)
    }
    return FaceLandmarkPoints(
        box: CGRect(x: 100, y: 100, width: 200, height: 240),
        contour: jaw,
        leftEye: ellipse(CGPoint(x: 160, y: 190), 20, 8),
        rightEye: ellipse(CGPoint(x: 240, y: 190), 20, 8),
        leftBrow: [CGPoint(x: 135, y: 165), CGPoint(x: 160, y: 158), CGPoint(x: 185, y: 165)],
        rightBrow: [CGPoint(x: 215, y: 165), CGPoint(x: 240, y: 158), CGPoint(x: 265, y: 165)],
        outerLips: ellipse(CGPoint(x: 200, y: 290), 40, 15),
        innerLips: ellipse(CGPoint(x: 200, y: 290), 25, 4),
        nose: [CGPoint(x: 200, y: 200), CGPoint(x: 185, y: 250), CGPoint(x: 215, y: 250)],
        leftPupil: [CGPoint(x: 160, y: 190)],
        rightPupil: [CGPoint(x: 240, y: 190)])
}

struct FaceRegionBuilderTests {
    @Test func faceContainsFeaturesAndForehead() {
        let face = FaceRegionBuilder.path(syntheticFace(), features: .face)
        #expect(face.contains(CGPoint(x: 200, y: 230), eoFill: true))   // nose
        #expect(face.contains(CGPoint(x: 200, y: 290), eoFill: true))   // mouth
        #expect(face.contains(CGPoint(x: 200, y: 130), eoFill: true))   // forehead
        #expect(!face.contains(CGPoint(x: 200, y: 20), eoFill: true))   // far above
        #expect(!face.contains(CGPoint(x: 40, y: 250), eoFill: true))   // beside
    }

    @Test func lipsExcludeMouthOpeningAndSkinExcludesEyes() {
        let lips = FaceRegionBuilder.path(syntheticFace(), features: .lips)
        #expect(!lips.contains(CGPoint(x: 200, y: 290), eoFill: true))
        #expect(lips.contains(CGPoint(x: 200, y: 280), eoFill: true))
        let skin = FaceRegionBuilder.path(syntheticFace(), features: .skin)
        #expect(!skin.contains(CGPoint(x: 160, y: 190), eoFill: true))
        #expect(skin.contains(CGPoint(x: 200, y: 240), eoFill: true))
    }

    @Test func pupilsAreSmallCircles() {
        let pupils = FaceRegionBuilder.path(syntheticFace(), features: .pupils)
        #expect(pupils.contains(CGPoint(x: 160, y: 190), eoFill: true))
        #expect(!pupils.contains(CGPoint(x: 175, y: 190), eoFill: true))
        #expect(pupils.boundingRect.width < 100)
    }

    @Test func ellipseFallbackWithoutLandmarks() {
        let face = FaceLandmarkPoints(box: CGRect(x: 0, y: 100, width: 100, height: 100))
        let path = FaceRegionBuilder.path(face, features: .face)
        #expect(path.contains(CGPoint(x: 50, y: 150), eoFill: true))
        #expect(path.boundingRect.minY < 100)
    }
}

struct VisionGeometryTests {
    @Test func normalizedRoundTrips() {
        let canvas = CGSize(width: 800, height: 600)
        let p = CGPoint(x: 200, y: 150)
        let n = VisionGeometry.normalized(p, canvas: canvas)
        #expect(abs(n.x - 0.25) < 1e-9 && abs(n.y - 0.75) < 1e-9)   // lower-left origin
        let back = VisionGeometry.canvasPoint(n, canvas: canvas)
        #expect(abs(back.x - p.x) < 1e-9 && abs(back.y - p.y) < 1e-9)

        let r = CGRect(x: 100, y: 0, width: 200, height: 300)
        let nr = VisionGeometry.normalizedRect(r, canvas: canvas)
        #expect(abs(nr.minY - 0.5) < 1e-9 && abs(nr.height - 0.5) < 1e-9)
        let rr = VisionGeometry.canvasRect(nr, canvas: canvas)
        #expect(abs(rr.minY) < 1e-9 && abs(rr.minX - 100) < 1e-9)
    }

    @Test func labelMapLookup() {
        var labels = [UInt8](repeating: 0, count: 4 * 4)
        labels[0] = 2   // top-left cell
        let map = InstanceLabelMap(width: 4, height: 4, labels: labels)
        let canvas = CGSize(width: 400, height: 400)
        #expect(map.instance(at: CGPoint(x: 10, y: 10), canvasSize: canvas) == 2)
        #expect(map.instance(at: CGPoint(x: 10, y: 390), canvasSize: canvas) == nil)
    }
}

/// Live Vision on a synthetic image. Vision may be unavailable in some test
/// environments; failures to run are not test failures, wrong answers are.
struct VisionSmokeTests {
    @Test func subjectMatteCoversAnOffCenterDisc() async throws {
        let size = 512
        let ctx = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        // Disc in the image's top-left quadrant (CG y-up: high y = top).
        ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 60, y: 300, width: 170, height: 170))
        let image = try #require(ctx.makeImage())

        let engine = VisionSegmentation()
        let canvas = CGSize(width: 1024, height: 1024)
        await engine.prepare(VisionComposite(image: image),
                             key: .init(modelHash: 1, width: 1024, height: 1024), canvasSize: canvas)
        let matte: SelectionMatte
        do {
            matte = try await engine.instanceMatte(.objects, instances: [])
        } catch {
            print("Vision unavailable, skipping: \(error)")
            return
        }
        let selection = try #require(CanvasSelection(matte: matte))
        // Disc centre in canvas space (y-down): x ≈ 145/512, y ≈ 1 - 385/512.
        let center = CGPoint(x: 145.0 / 512 * 1024, y: (1 - 385.0 / 512) * 1024)
        #expect(selection.contains(center), "subject should cover the disc, bounds \(selection.bounds)")
        #expect(!selection.contains(CGPoint(x: 900, y: 900)))

        let clock = ContinuousClock.now
        let labels = try await engine.instanceLabels(.objects)
        print("label map took \(ContinuousClock.now - clock)")
        #expect(labels?.instance(at: center, canvasSize: canvas) != nil)
        #expect(labels?.instance(at: CGPoint(x: 900, y: 900), canvasSize: canvas) == nil)
    }
}

/// Click-to-segment on the same disc; runs only when Apple's model is installed.
struct IterativeSegmentationSmokeTests {
    @Test func pointSeedSelectsTheDisc() async throws {
        let size = 512
        let ctx = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.3, blue: 0.85, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 60, y: 300, width: 170, height: 170))      // top-left
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.7, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 320, y: 40, width: 150, height: 150))                // bottom-right
        let image = try #require(ctx.makeImage())

        let engine = VisionSegmentation()
        let canvas = CGSize(width: 1024, height: 1024)
        await engine.prepare(VisionComposite(image: image),
                             key: .init(modelHash: 2, width: 1024, height: 1024), canvasSize: canvas)
        // Vision reports notReady per process until downloadAssets runs; it
        // returns immediately when the model is already installed.
        if await engine.iterativeStatus() != .ready {
            let manager = ProgressManager(totalCount: 1)
            do {
                try await engine.downloadIterativeModel(progress: manager.subprogress(assigningCount: 1))
                print("iterative model load fraction: \(manager.fractionCompleted)")
            } catch {
                print("iterative model load error: \(error)")
            }
        }
        let status = await engine.iterativeStatus()
        print("iterative model status: \(status)")
        guard status == .ready else { return }
        let disc = CGPoint(x: 145.0 / 512 * 1024, y: (1 - 385.0 / 512) * 1024)
        let square = CGPoint(x: 395.0 / 512 * 1024, y: (1 - 115.0 / 512) * 1024)
        let matte = try await engine.beginRefine(.point(disc), quality: .balanced)
        let selection = try #require(CanvasSelection(matte: matte))
        #expect(selection.contains(disc), "bounds \(selection.bounds)")
        #expect(!selection.contains(square))
        // Refinement reuses the same request/handler (cached embedding).
        let clock = ContinuousClock.now
        let refined = try await engine.refine(square, include: true)
        print("refine took \(ContinuousClock.now - clock)")
        let refinedSelection = try #require(CanvasSelection(matte: refined))
        #expect(refinedSelection.contains(square), "include point should pull in the square")
        await engine.endRefine()

        // Box both shapes, then exclude the disc.
        _ = try await engine.beginRefine(.box(CGRect(x: 40, y: 40, width: 950, height: 950)), quality: .balanced)
        let excluded = try await engine.refine(disc, include: false)
        #expect(!(CanvasSelection(matte: excluded)?.contains(disc) ?? false), "exclude point should drop the disc")
        await engine.endRefine()

        let boxed = try await engine.beginRefine(.box(CGRect(x: 600, y: 600, width: 360, height: 360)),
                                                 quality: .balanced)
        let boxSelection = try #require(CanvasSelection(matte: boxed))
        #expect(boxSelection.contains(square), "box bounds \(boxSelection.bounds)")
        #expect(!boxSelection.contains(disc))
    }
}

struct ContourTracerPinchTests {
    /// Cells touching only at a corner used to drop an edge, cut the loop
    /// short, and close it with a stray diagonal across the selection.
    @Test func diagonalNeighborsTraceWithoutDiagonals() throws {
        // Checkerboard-ish pinch pattern: (1,1), (2,2), (3,1), (2,0) and a block.
        let w = 8, h = 6
        var grid = [Bool](repeating: false, count: w * h)
        for (x, y) in [(1, 1), (2, 2), (3, 1), (2, 0), (5, 3), (6, 4), (5, 4)] { grid[y * w + x] = true }
        let path = try #require(ContourTracer.trace(grid: grid, width: w, height: h, scale: CGPoint(x: 10, y: 10)))
        var last: CGPoint?, start: CGPoint?
        var diagonal = false
        path.forEach { element in
            switch element {
            case .move(let p): last = p; start = p
            case .line(let p):
                if let l = last, l.x != p.x, l.y != p.y { diagonal = true }
                last = p
            case .closeSubpath:
                if let l = last, let s = start, l.x != s.x, l.y != s.y { diagonal = true }
            default: diagonal = true
            }
        }
        #expect(!diagonal, "traced contour must stay axis-aligned")
        for (x, y) in [(1, 1), (2, 2), (3, 1), (2, 0), (5, 3), (6, 4), (5, 4)] {
            #expect(path.contains(CGPoint(x: x * 10 + 5, y: y * 10 + 5), eoFill: true), "cell \(x),\(y)")
        }
        #expect(!path.contains(CGPoint(x: 25, y: 15), eoFill: true))   // hole in the pinch ring
        #expect(!path.contains(CGPoint(x: 65, y: 35), eoFill: true))
    }
}
