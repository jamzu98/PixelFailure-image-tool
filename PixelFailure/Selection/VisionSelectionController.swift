import SwiftUI
import Vision

/// Main-actor front end for smart selection: Select menu commands, the
/// Object Select tool's hover/click/refine flow, status and model download.
/// All analysis runs in `VisionSegmentation`; this only snapshots the
/// composite and publishes results.
@MainActor
@Observable
final class VisionSelectionController {
    enum Mode: String, CaseIterable, Identifiable {
        case object, person, face
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .object: "Object"
            case .person: "Person"
            case .face: "Face"
            }
        }
    }

    enum ModelState: Equatable {
        case unknown, ready, needsDownload, downloading, failed
    }

    /// Something to tint on the canvas: a soft matte image or a vector region.
    struct Tint {
        var image: CGImage?
        var path: Path?
    }

    /// The pending Object Select result, before it merges into the selection.
    struct Candidate {
        var selection: CanvasSelection
        var combine: SelectionCombineMode
        /// The click/box that started it (lets instance picks upgrade to
        /// iterative refinement).
        var seed: RefineSeed
        var isRefining: Bool
        var points: [(point: CGPoint, include: Bool)] = []
        var tint: Tint
    }

    // Tool options
    var mode: Mode = .object
    var quality: SegmentationQuality = .balanced
    var combineMode: SelectionCombineMode = .replace
    var faceFeatures: FaceFeatures = .face

    // Status
    private(set) var busyLabel: String?
    private(set) var statusMessage: String?
    private(set) var downloadProgress: Double?
    private(set) var modelState: ModelState = .unknown

    // Interaction
    private(set) var hover: Tint?
    private(set) var candidate: Candidate?

    @ObservationIgnored private let engine = VisionSegmentation()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private var preparedKey: VisionSegmentation.Key?
    @ObservationIgnored private var labelMaps: [InstanceKind: InstanceLabelMap] = [:]
    @ObservationIgnored private var faces: [FaceLandmarkPoints]?
    @ObservationIgnored private var tintCache: [String: Tint] = [:]
    @ObservationIgnored private var hoverID: String?
    /// The object-mode hover preview, to skip re-segmenting while the
    /// pointer stays on the same object.
    @ObservationIgnored private var hoverMatte: SelectionMatte?
    /// Set when the document changes; hover stays quiet until re-analysis.
    @ObservationIgnored private var isStale = true

    var isBusy: Bool { busyLabel != nil }

    // MARK: - Preparation

    private func key(for document: PixelDocument) -> VisionSegmentation.Key {
        let model = document.model
        return .init(modelHash: model.hashValue, width: model.canvasSize.width, height: model.canvasSize.height)
    }

    /// Renders the composite (once per document revision) and hands it to
    /// the analysis actor. Clears per-revision caches when the art changed.
    private func prepare(_ focus: EditorFocus) async -> Bool {
        let key = key(for: focus.document)
        if key == preparedKey, await engine.isPrepared(key) { return true }
        let model = focus.document.model
        let long = max(model.canvasSize.width, model.canvasSize.height)
        guard long > 0 else { return false }
        let scale = min(1, VisionSegmentation.analysisLongSide / long)
        let target = CGSize(width: max(8, (model.canvasSize.width * scale).rounded()),
                            height: max(8, (model.canvasSize.height * scale).rounded()))
        guard let image = PNGExporter.render(items: focus.renderStore.renderItems(model: model, quality: .preview),
                                             background: model.background,
                                             canvasSize: model.canvasSize,
                                             targetPixelSize: target,
                                             colorSettings: model.colorSettings.previewVariant) else { return false }
        if key != preparedKey {
            labelMaps = [:]
            faces = nil
            tintCache = [:]
            hover = nil
            hoverID = nil
            if candidate != nil { cancel() }
        }
        await engine.prepare(VisionComposite(image: image), key: key, canvasSize: model.canvasSize)
        preparedKey = key
        isStale = false
        return true
    }

    /// Runs `work` as the single in-flight job, with a busy label.
    private func run(_ label: String, _ work: @escaping @MainActor () async throws -> Void) {
        task?.cancel()
        busyLabel = label
        task = Task { @MainActor in
            defer { if !Task.isCancelled { busyLabel = nil } }
            do {
                try await work()
            } catch is CancellationError {
            } catch let error as VisionSelectionError {
                if case .modelUnavailable = error { await refreshModelState() }
                show(error.localizedDescription)
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    func cancelWork() {
        task?.cancel()
        task = nil
        busyLabel = nil
    }

    private func show(_ message: String) {
        statusMessage = message
        messageTask?.cancel()
        messageTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            statusMessage = nil
        }
    }

    // MARK: - Select menu commands

    func selectSubject(inverted: Bool, focus: EditorFocus) {
        run("Selecting subject") { [self] in
            guard await prepare(focus) else { return }
            let matte = try await engine.instanceMatte(.objects, instances: [])
            try Task.checkCancellation()
            guard var selection = CanvasSelection(matte: matte, feather: focus.editorState.featherDefault) else {
                throw VisionSelectionError.nothingFound("subject")
            }
            if inverted { selection = selection.inverted(canvasSize: focus.document.model.canvasSize) }
            focus.editorState.selection = selection.isEmpty ? nil : selection
        }
    }

    func selectPeople(focus: EditorFocus) {
        run("Selecting people") { [self] in
            guard await prepare(focus) else { return }
            let matte = try await engine.peopleMatte(quality: .accurate)
            try Task.checkCancellation()
            guard let selection = CanvasSelection(matte: matte, feather: focus.editorState.featherDefault) else {
                throw VisionSelectionError.nothingFound("people")
            }
            focus.editorState.selection = selection
        }
    }

    func selectFaces(_ features: FaceFeatures, focus: EditorFocus) {
        run("Finding faces") { [self] in
            guard await prepare(focus) else { return }
            let found = try await loadFaces()
            try Task.checkCancellation()
            guard !found.isEmpty else { throw VisionSelectionError.nothingFound("faces") }
            var path = Path()
            for face in found {
                path = path.isEmpty ? FaceRegionBuilder.path(face, features: features)
                    : Path(path.cgPath.union(FaceRegionBuilder.path(face, features: features).cgPath,
                                             using: .evenOdd))
            }
            let selection = CanvasSelection(path: path, feather: focus.editorState.featherDefault)
            guard !selection.isEmpty else { throw VisionSelectionError.nothingFound("face features") }
            focus.editorState.selection = selection
        }
    }

    private func loadFaces() async throws -> [FaceLandmarkPoints] {
        if let faces { return faces }
        let found = try await engine.faces()
        faces = found
        return found
    }

    // MARK: - Object Select tool

    /// Warm caches for the active mode so hover is instant.
    func prefetch(focus: EditorFocus) {
        prefetchTask?.cancel()
        prefetchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, await prepare(focus) else { return }
            switch mode {
            case .object:
                labelMaps[.objects] = try? await engine.instanceLabels(.objects)
                // Load (or first-time download) the click-to-segment model so
                // hover previews and clicks are immediate.
                if modelState != .failed { try? await ensureModel() }
            case .person:
                labelMaps[.people] = try? await engine.instanceLabels(.people)
            case .face:
                _ = try? await loadFaces()
            }
        }
    }

    /// Hover feedback from cached analysis only; never blocks on Vision.
    /// Call on every document change: hover lookups pause until the next
    /// analysis, without hashing the model on each mouse move.
    func documentChanged() {
        isStale = true
        clearHover()
    }

    func hover(at point: CGPoint?, focus: EditorFocus) {
        guard let point, !isStale, candidate == nil || !(candidate?.isRefining ?? false) else {
            clearHover()
            return
        }
        let canvasSize = focus.document.model.canvasSize
        switch mode {
        case .object where modelState == .ready:
            // Preview exactly what a click selects (iterative segmentation),
            // once the pointer rests.
            if let hoverMatte, hoverMatte.coverage(at: point) >= 128 { return }
            hoverTask?.cancel()
            hover = nil
            hoverMatte = nil
            let quality = quality
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled,
                      let matte = try? await engine.previewObject(at: point, quality: quality),
                      !Task.isCancelled else { return }
                hoverMatte = matte
                hover = Tint(image: matte.tinted(Theme.accentCG, alpha: 0.35))
            }
        case .object, .person:
            let kind: InstanceKind = mode == .object ? .objects : .people
            guard let index = labelMaps[kind]?.instance(at: point, canvasSize: canvasSize) else {
                clearHover()
                return
            }
            let id = "\(kind)-\(index)"
            guard id != hoverID else { return }
            hoverID = id
            if let cached = tintCache[id] {
                hover = cached
                return
            }
            hoverTask?.cancel()
            hoverTask = Task { @MainActor in
                guard let matte = try? await engine.instanceMatte(kind, instances: IndexSet(integer: index)),
                      !Task.isCancelled else { return }
                let tint = Tint(image: matte.tinted(Theme.accentCG, alpha: 0.35))
                tintCache[id] = tint
                if hoverID == id { hover = tint }
            }
        case .face:
            guard let face = faces?.first(where: { $0.box.insetBy(dx: -$0.box.width * 0.1,
                                                                  dy: -$0.box.height * 0.2).contains(point) })
            else {
                clearHover()
                return
            }
            let id = "face-\(face.box.minX)-\(face.box.minY)-\(faceFeatures.rawValue)"
            guard id != hoverID else { return }
            hoverID = id
            hover = Tint(path: FaceRegionBuilder.path(face, features: faceFeatures))
        }
    }

    func clearHover() {
        hoverTask?.cancel()
        hover = nil
        hoverID = nil
        hoverMatte = nil
    }

    func click(at point: CGPoint, modifiers: NSEvent.ModifierFlags, focus: EditorFocus) {
        let canvasSize = focus.document.model.canvasSize
        guard CGRect(origin: .zero, size: canvasSize).contains(point) else { return }
        let feather = focus.editorState.featherDefault

        // Refinement of the pending object.
        if let current = candidate, mode == .object,
           modifiers.contains(.shift) || modifiers.contains(.option) {
            let include = !modifiers.contains(.option)
            run("Refining") { [self] in
                guard await prepare(focus) else { return }
                if !current.isRefining {
                    try await ensureModel()
                    _ = try await engine.beginRefine(current.seed, quality: quality)
                }
                let matte = try await engine.refine(point, include: include)
                try Task.checkCancellation()
                setCandidate(matte: matte, feather: feather, combine: current.combine, seed: current.seed,
                             refining: true, points: current.points + [(point, include)])
            }
            return
        }
        if candidate != nil { commit(focus.editorState) }

        let picked = SelectionCombineMode(modifiers: modifiers)
        let combine = picked == .replace ? combineMode : picked
        switch mode {
        case .object:
            run("Selecting object") { [self] in
                guard await prepare(focus) else { return }
                // Click-to-segment selects exactly the clicked object; Vision's
                // subject instances often merge several objects into one, so
                // they are only the fallback when the model can't load.
                do {
                    try await ensureModel()
                    let matte = try await engine.beginRefine(.point(point), quality: quality)
                    try Task.checkCancellation()
                    setCandidate(matte: matte, feather: feather, combine: combine, seed: .point(point),
                                 refining: true)
                } catch VisionSelectionError.modelUnavailable {
                    if labelMaps[.objects] == nil { labelMaps[.objects] = try? await engine.instanceLabels(.objects) }
                    guard let index = labelMaps[.objects]?.instance(at: point, canvasSize: canvasSize) else {
                        throw VisionSelectionError.nothingFound("object")
                    }
                    let matte = try await engine.instanceMatte(.objects, instances: IndexSet(integer: index))
                    try Task.checkCancellation()
                    setCandidate(matte: matte, feather: feather, combine: combine, seed: .point(point),
                                 refining: false)
                }
            }
        case .person:
            run("Selecting person") { [self] in
                guard await prepare(focus) else { return }
                guard let index = try await engine.instance(at: point, kind: .people) else {
                    throw VisionSelectionError.nothingFound("person")
                }
                let matte = try await engine.instanceMatte(.people, instances: IndexSet(integer: index))
                try Task.checkCancellation()
                guard let selection = CanvasSelection(matte: matte, feather: feather) else { return }
                apply(selection, mode: combine, to: focus.editorState)
            }
        case .face:
            run("Selecting face") { [self] in
                guard await prepare(focus) else { return }
                let found = try await loadFaces()
                guard let face = found.first(where: { $0.box.insetBy(dx: -$0.box.width * 0.1,
                                                                     dy: -$0.box.height * 0.2).contains(point) })
                else { throw VisionSelectionError.nothingFound("face") }
                let selection = CanvasSelection(path: FaceRegionBuilder.path(face, features: faceFeatures),
                                                feather: feather)
                apply(selection, mode: combine, to: focus.editorState)
            }
        }
    }

    /// Drag-rectangle seed (object mode).
    func box(_ rect: CGRect, modifiers: NSEvent.ModifierFlags, focus: EditorFocus) {
        guard mode == .object, rect.width > 4, rect.height > 4 else { return }
        if candidate != nil { commit(focus.editorState) }
        let picked = SelectionCombineMode(modifiers: modifiers)
        let combine = picked == .replace ? combineMode : picked
        let feather = focus.editorState.featherDefault
        let clipped = rect.intersection(CGRect(origin: .zero, size: focus.document.model.canvasSize))
        run("Selecting object") { [self] in
            guard await prepare(focus) else { return }
            try await ensureModel()
            let matte = try await engine.beginRefine(.box(clipped), quality: quality)
            try Task.checkCancellation()
            setCandidate(matte: matte, feather: feather, combine: combine, seed: .box(clipped), refining: true)
        }
    }

    private func setCandidate(matte: SelectionMatte, feather: Double, combine: SelectionCombineMode,
                              seed: RefineSeed, refining: Bool,
                              points: [(point: CGPoint, include: Bool)] = []) {
        guard let selection = CanvasSelection(matte: matte, feather: feather) else {
            show(VisionSelectionError.nothingFound("object").localizedDescription)
            return
        }
        clearHover()
        candidate = Candidate(selection: selection, combine: combine, seed: seed, isRefining: refining,
                              points: points, tint: Tint(image: matte.tinted(Theme.accentCG, alpha: 0.4)))
    }

    private func apply(_ selection: CanvasSelection, mode: SelectionCombineMode, to editorState: EditorState) {
        editorState.selection = CanvasSelection.combine(existing: editorState.selection, new: selection, mode: mode)
    }

    func commit(_ editorState: EditorState) {
        guard let candidate else { return }
        apply(candidate.selection, mode: candidate.combine, to: editorState)
        self.candidate = nil
        Task { await engine.endRefine() }
    }

    func cancel() {
        cancelWork()
        candidate = nil
        Task { await engine.endRefine() }
    }

    // MARK: - Model assets

    func refreshModelState() async {
        switch await engine.iterativeStatus() {
        case .ready: modelState = .ready
        case .downloading: modelState = .downloading
        case .notReady: modelState = .needsDownload
        case .error: modelState = .failed
        @unknown default: modelState = .failed
        }
    }

    /// Makes the click-to-segment model usable in this process. Vision
    /// reports `notReady` on every launch until `downloadAssets` runs; when the
    /// files are already installed that call returns immediately, otherwise
    /// it downloads them (progress shows in the status bar).
    private func ensureModel() async throws {
        if modelState == .ready { return }
        await refreshModelState()
        if modelState == .ready { return }
        modelState = .downloading
        downloadProgress = 0
        let manager = ProgressManager(totalCount: 1)
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                downloadProgress = manager.fractionCompleted
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer {
            poll.cancel()
            downloadProgress = nil
        }
        do {
            try await engine.downloadIterativeModel(progress: manager.subprogress(assigningCount: 1))
        } catch {
            modelState = .failed
            throw error
        }
        await refreshModelState()
        guard modelState == .ready else { throw VisionSelectionError.modelUnavailable }
    }

    /// Options-bar retry after a failed load.
    func downloadModel() {
        run("Loading segmentation model") { [self] in try await ensureModel() }
    }
}
