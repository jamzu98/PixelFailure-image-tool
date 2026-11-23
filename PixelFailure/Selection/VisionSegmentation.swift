import CoreImage
import CoreVideo
import Foundation
import SwiftUI
import Vision

nonisolated enum VisionSelectionError: LocalizedError {
    case nothingFound(String)
    case notPrepared
    case pointLimit
    case modelUnavailable

    var errorDescription: String? {
        switch self {
        case .nothingFound(let what): "No \(what) found"
        case .notPrepared: "Image not analyzed yet"
        case .pointLimit: "Point limit reached"
        case .modelUnavailable: "Segmentation model unavailable"
        }
    }
}

/// Sendable box for a composite handed to the analysis actor.
nonisolated struct VisionComposite: @unchecked Sendable {
    let image: CGImage
}

/// Instance id per cell on a coarse grid (row 0 = canvas top). 0 = background.
nonisolated struct InstanceLabelMap: Sendable {
    let width: Int
    let height: Int
    let labels: [UInt8]

    func instance(at canvasPoint: CGPoint, canvasSize: CGSize) -> Int? {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let x = Int(canvasPoint.x / canvasSize.width * CGFloat(width))
        let y = Int(canvasPoint.y / canvasSize.height * CGFloat(height))
        guard (0..<width).contains(x), (0..<height).contains(y) else { return nil }
        let label = Int(labels[y * width + x])
        return label == 0 ? nil : label
    }
}

nonisolated enum VisionGeometry {
    /// Canvas (y-down) → Vision normalized (lower-left origin).
    static func normalized(_ p: CGPoint, canvas: CGSize) -> CGPoint {
        CGPoint(x: min(max(p.x / canvas.width, 0), 1), y: min(max(1 - p.y / canvas.height, 0), 1))
    }

    static func canvasPoint(_ n: CGPoint, canvas: CGSize) -> CGPoint {
        CGPoint(x: n.x * canvas.width, y: (1 - n.y) * canvas.height)
    }

    static func normalizedRect(_ r: CGRect, canvas: CGSize) -> CGRect {
        let a = normalized(CGPoint(x: r.minX, y: r.maxY), canvas: canvas)
        let b = normalized(CGPoint(x: r.maxX, y: r.minY), canvas: canvas)
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    static func canvasRect(_ n: CGRect, canvas: CGSize) -> CGRect {
        CGRect(x: n.minX * canvas.width, y: (1 - n.maxY) * canvas.height,
               width: n.width * canvas.width, height: n.height * canvas.height)
    }
}

nonisolated enum RefineSeed: Sendable, Equatable {
    case point(CGPoint)   // canvas space
    case box(CGRect)      // canvas space
}

nonisolated enum InstanceKind: Sendable, Hashable {
    case objects, people
}

nonisolated enum SegmentationQuality: String, CaseIterable, Identifiable, Sendable {
    case fast, balanced, accurate
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

/// All Vision work for smart selection. Caches per composite (document
/// revision), so hover lookups and repeat commands are instant, and owns the
/// non-Sendable iterative segmentation request across refinement clicks.
actor VisionSegmentation {
    struct Key: Hashable, Sendable {
        let modelHash: Int
        let width: Double
        let height: Double
    }

    /// Long side of the analyzed composite.
    static let analysisLongSide = 2048.0

    private var key: Key?
    private var canvasSize: CGSize = .zero
    private var composite: CGImage?
    private var handler: ImageRequestHandler?
    private var instanceObservations: [InstanceKind: InstanceMaskObservation?] = [:]
    private var labelMaps: [InstanceKind: InstanceLabelMap] = [:]
    private var faceCache: [FaceLandmarkPoints]?
    /// Person instances confirmed by the human detector (the instance mask
    /// alone labels e.g. a cat's face as a person).
    private var validPeople: IndexSet?

    private var refineRequest: GenerateIterativeSegmentationRequest?
    private var refineHandler: ImageRequestHandler?
    private var refinePoints = 0
    private var refinePointLimit = 13

    private var ciContext: CIContext { CoreImageContext.shared }

    func isPrepared(_ key: Key) -> Bool { self.key == key }

    func prepare(_ composite: VisionComposite, key: Key, canvasSize: CGSize) {
        guard self.key != key else { return }
        self.key = key
        self.canvasSize = canvasSize
        self.composite = composite.image
        handler = ImageRequestHandler(composite.image)
        instanceObservations = [:]
        labelMaps = [:]
        faceCache = nil
        validPeople = nil
        endRefine()
    }

    // MARK: Instances (subject objects / people)

    private func observation(_ kind: InstanceKind) async throws -> InstanceMaskObservation? {
        if let cached = instanceObservations[kind] { return cached }
        guard let handler else { throw VisionSelectionError.notPrepared }
        let result: InstanceMaskObservation?
        switch kind {
        case .objects: result = try await handler.perform(GenerateForegroundInstanceMaskRequest())
        case .people: result = try await handler.perform(GeneratePersonInstanceMaskRequest())
        }
        instanceObservations[kind] = result
        if kind == .people, let result { validPeople = try await confirmedPeople(result) }
        return result
    }

    /// Person instances worth offering. Vision's person masks also fire on
    /// animals (a cat's face, a dog leaning on someone), so an instance
    /// counts when it holds a detected face, or — for people facing away —
    /// when it sits mostly inside a detected human rectangle with no face.
    private func confirmedPeople(_ obs: InstanceMaskObservation) async throws -> IndexSet {
        guard let handler, let composite, !obs.allInstances.isEmpty else { return [] }
        var request = DetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        let size = CGSize(width: composite.width, height: composite.height)
        let humans = try await handler.perform(request).map {
            let r = $0.boundingBox.toImageCoordinates(size, origin: .upperLeft)
            return CGRect(x: r.minX / size.width, y: r.minY / size.height,
                          width: r.width / size.width, height: r.height / size.height)
                .insetBy(dx: -0.02, dy: -0.02)
        }
        // Face centers, normalized with an upper-left origin (instanceAtPoint's).
        let faceCenters = try await faces().map {
            CGPoint(x: $0.box.midX / canvasSize.width, y: $0.box.midY / canvasSize.height)
        }
        var valid = IndexSet()
        for center in faceCenters {
            if let id = obs.instanceAtPoint(NormalizedPoint(x: center.x, y: center.y)).first, id != 0 {
                valid.insert(id)
            }
        }
        let faceless = humans.filter { rect in !faceCenters.contains { rect.contains($0) } }
        guard !faceless.isEmpty else { return valid }
        var total: [Int: Int] = [:], inside: [Int: Int] = [:]
        let n = 64
        for y in 0..<n {
            for x in 0..<n {
                let p = CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(n), y: (CGFloat(y) + 0.5) / CGFloat(n))
                guard let id = obs.instanceAtPoint(NormalizedPoint(x: p.x, y: p.y)).first, id != 0,
                      !valid.contains(id) else { continue }
                total[id, default: 0] += 1
                if faceless.contains(where: { $0.contains(p) }) { inside[id, default: 0] += 1 }
            }
        }
        for (id, count) in total where Double(inside[id] ?? 0) / Double(count) >= 0.6 {
            valid.insert(id)
        }
        return valid
    }

    private func isValid(_ id: Int, _ kind: InstanceKind) -> Bool {
        kind == .objects || (validPeople?.contains(id) ?? false)
    }

    func instanceLabels(_ kind: InstanceKind) async throws -> InstanceLabelMap? {
        if let map = labelMaps[kind] { return map }
        guard let obs = try await observation(kind) else { return nil }
        let aspect = canvasSize.height / max(canvasSize.width, 1)
        let width = 192, height = max(1, Int((192 * aspect).rounded()))
        var labels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                // instanceAtPoint reads the mask top-down (upper-left origin).
                let n = NormalizedPoint(x: (CGFloat(x) + 0.5) / CGFloat(width),
                                        y: (CGFloat(y) + 0.5) / CGFloat(height))
                let id = obs.instanceAtPoint(n).first ?? 0
                labels[y * width + x] = isValid(id, kind) ? UInt8(clamping: id) : 0
            }
        }
        let map = InstanceLabelMap(width: width, height: height, labels: labels)
        labelMaps[kind] = map
        return map
    }

    func instanceMatte(_ kind: InstanceKind, instances: IndexSet) async throws -> SelectionMatte {
        guard let obs = try await observation(kind), let handler else {
            throw VisionSelectionError.nothingFound(kind == .people ? "people" : "subject")
        }
        let candidates = instances.isEmpty ? obs.allInstances : instances
        let set = IndexSet(candidates.filter { isValid($0, kind) })
        guard !set.isEmpty else { throw VisionSelectionError.nothingFound(kind == .people ? "people" : "subject") }
        let buffer = try obs.generateScaledMask(for: set, scaledToImageFrom: handler)
        return try matte(from: CIImage(cvPixelBuffer: buffer))
    }

    /// Instance index under a canvas point, straight from the observation.
    func instance(at canvasPoint: CGPoint, kind: InstanceKind) async throws -> Int? {
        guard let obs = try await observation(kind) else { return nil }
        // Upper-left origin for mask lookups (verified against real output).
        let n = NormalizedPoint(x: canvasPoint.x / canvasSize.width, y: canvasPoint.y / canvasSize.height)
        return obs.instanceAtPoint(n).first.flatMap { $0 == 0 || !isValid($0, kind) ? nil : $0 }
    }

    /// Single matte of everyone, at the person segmentation quality.
    func peopleMatte(quality: SegmentationQuality) async throws -> SelectionMatte {
        guard let handler else { throw VisionSelectionError.notPrepared }
        let request = GeneratePersonSegmentationRequest()
        request.qualityLevel = switch quality {
        case .fast: .fast
        case .balanced: .balanced
        case .accurate: .accurate
        }
        let observation = try await handler.perform(request)
        let result = try matte(from: CIImage(cgImage: observation.cgImage))
        guard !result.isEmpty else { throw VisionSelectionError.nothingFound("people") }
        return result
    }

    // MARK: Faces

    /// Uses the VN request: on macOS 27 the Swift `DetectFaceLandmarksRequest`
    /// returns garbage landmark points for some photos (e.g. several small
    /// faces) while the VN request is correct on the same image.
    func faces() async throws -> [FaceLandmarkPoints] {
        if let faceCache { return faceCache }
        guard let composite else { throw VisionSelectionError.notPrepared }
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cgImage: composite, options: [:]).perform([request])
        let imageSize = CGSize(width: composite.width, height: composite.height)
        // Vision image space is y-up; canvas is y-down.
        let toCanvas = CGAffineTransform(a: canvasSize.width / imageSize.width, b: 0, c: 0,
                                         d: -canvasSize.height / imageSize.height,
                                         tx: 0, ty: canvasSize.height)
        let result = (request.results ?? []).map { face -> FaceLandmarkPoints in
            let box = VNImageRectForNormalizedRect(face.boundingBox, composite.width, composite.height)
                .applying(toCanvas).standardized
            func pts(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
                guard let region else { return [] }
                return region.pointsInImage(imageSize: imageSize).map { $0.applying(toCanvas) }
            }
            let l = face.landmarks
            return FaceLandmarkPoints(box: box,
                                      contour: pts(l?.faceContour),
                                      leftEye: pts(l?.leftEye), rightEye: pts(l?.rightEye),
                                      leftBrow: pts(l?.leftEyebrow), rightBrow: pts(l?.rightEyebrow),
                                      outerLips: pts(l?.outerLips), innerLips: pts(l?.innerLips),
                                      nose: pts(l?.nose),
                                      leftPupil: pts(l?.leftPupil), rightPupil: pts(l?.rightPupil))
        }
        faceCache = result
        return result
    }

    // MARK: Iterative (click / box) segmentation — macOS 27

    /// One long-lived request for asset bookkeeping: a freshly created
    /// request reports `notReady` even right after another instance loaded
    /// the model, so status must be read from the instance that loaded it.
    private let assetRequest = GenerateIterativeSegmentationRequest(seedPoint: NormalizedPoint(x: 0.5, y: 0.5))

    func iterativeStatus() async -> DownloadableAssetsRequestStatus {
        await assetRequest.assetStatus
    }

    func downloadIterativeModel(progress: consuming Subprogress) async throws {
        try await assetRequest.downloadAssets(progress: progress)
    }

    func beginRefine(_ seed: RefineSeed, quality: SegmentationQuality) async throws -> SelectionMatte {
        guard let composite else { throw VisionSelectionError.notPrepared }
        let request: GenerateIterativeSegmentationRequest
        switch seed {
        case .point(let p):
            let n = VisionGeometry.normalized(p, canvas: canvasSize)
            request = GenerateIterativeSegmentationRequest(seedPoint: NormalizedPoint(x: n.x, y: n.y))
            refinePointLimit = 13
            refinePoints = 1
        case .box(let r):
            let n = VisionGeometry.normalizedRect(r, canvas: canvasSize)
            request = GenerateIterativeSegmentationRequest(
                seedBox: NormalizedRect(x: n.minX, y: n.minY, width: n.width, height: n.height))
            refinePointLimit = 11
            refinePoints = 0
        }
        request.qualityLevel = switch quality {
        case .fast: .fast
        case .balanced: .balanced
        case .accurate: .accurate
        }
        guard await assetRequest.assetStatus == .ready else { throw VisionSelectionError.modelUnavailable }
        // A fresh handler per object; refinement reuses it (cached embedding).
        let handler = ImageRequestHandler(composite)
        refineRequest = request
        refineHandler = handler
        return try await performRefine()
    }

    func refine(_ point: CGPoint, include: Bool) async throws -> SelectionMatte {
        guard let request = refineRequest else { throw VisionSelectionError.notPrepared }
        guard refinePoints < refinePointLimit else { throw VisionSelectionError.pointLimit }
        let n = VisionGeometry.normalized(point, canvas: canvasSize)
        let np = NormalizedPoint(x: n.x, y: n.y)
        if include { try request.addIncludedPoint(np) } else { try request.addExcludedPoint(np) }
        refinePoints += 1
        return try await performRefine()
    }

    /// One-off segmentation at a point for hover previews; leaves any
    /// refinement session untouched.
    func previewObject(at point: CGPoint, quality: SegmentationQuality) async throws -> SelectionMatte {
        guard let composite else { throw VisionSelectionError.notPrepared }
        guard await assetRequest.assetStatus == .ready else { throw VisionSelectionError.modelUnavailable }
        let n = VisionGeometry.normalized(point, canvas: canvasSize)
        let request = GenerateIterativeSegmentationRequest(seedPoint: NormalizedPoint(x: n.x, y: n.y))
        request.qualityLevel = switch quality {
        case .fast: .fast
        case .balanced: .balanced
        case .accurate: .accurate
        }
        guard let observation = try await ImageRequestHandler(composite).perform(request) else {
            throw VisionSelectionError.nothingFound("object")
        }
        let result = try matte(from: CIImage(cgImage: observation.cgImage))
        guard !result.isEmpty else { throw VisionSelectionError.nothingFound("object") }
        return result
    }

    var isRefining: Bool { refineRequest != nil }

    func endRefine() {
        refineRequest = nil
        refineHandler = nil
        refinePoints = 0
    }

    private func performRefine() async throws -> SelectionMatte {
        guard let request = refineRequest, let handler = refineHandler else {
            throw VisionSelectionError.notPrepared
        }
        guard let observation = try await handler.perform(request) else {
            throw VisionSelectionError.nothingFound("object")
        }
        let result = try matte(from: CIImage(cgImage: observation.cgImage))
        guard !result.isEmpty else { throw VisionSelectionError.nothingFound("object") }
        return result
    }

    // MARK: Helpers

    private func matte(from image: CIImage) throws -> SelectionMatte {
        guard let cg = ciContext.createCGImage(image, from: image.extent, format: .L8,
                                               colorSpace: CGColorSpaceCreateDeviceGray()),
              let matte = SelectionMatte(grayImage: cg, canvasSize: canvasSize) else {
            throw VisionSelectionError.nothingFound("mask")
        }
        return matte
    }
}
