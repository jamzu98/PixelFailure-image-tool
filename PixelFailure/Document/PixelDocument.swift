import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    nonisolated static var pixelFailureProject: UTType { UTType(exportedAs: "com.pixelfailure.project") }
}

/// The document: a package bundle with manifest.json (the model) and an
/// images/ directory holding copies of every imported photo.
///
/// The class itself is nonisolated because ReferenceFileDocument requires
/// Sendable and may serialize on a background queue; all mutation happens on
/// the main actor via the explicitly annotated methods below.
final class PixelDocument: ReferenceFileDocument, @unchecked Sendable {
    nonisolated struct Checkpoint: Identifiable, Codable, Hashable, Sendable {
        var id = UUID()
        var name: String
        var createdAt = Date()
        var model: ProjectModel
    }

    struct Snapshot {
        var model: ProjectModel
        var images: [String: Data]
        var checkpoints: [Checkpoint]
    }

    /// Cap for the in-memory recent-history ring. Each entry stores a full
    /// `ProjectModel` copy (image pixels stay shared via keys). Kept modest
    /// because UndoManager already retains prior models separately, and large
    /// layer/path trees multiply RAM with every edit.
    static let maxHistoryCount = 50

    @Published var model: ProjectModel
    @Published private(set) var history: [Checkpoint] = []
    @Published private(set) var checkpoints: [Checkpoint] = []
    /// Created by Recover; such a window never offers another archive, so
    /// recoveries don't chain from window to window. Not persisted.
    private(set) var isRecovered = false
    @MainActor lazy var actionRecorder = ActionRecorder()
    /// True only while a continuous editor gesture is changing the model.
    /// The viewport uses this transient state to render a lightweight proxy,
    /// then restores native-resolution content after the gesture settles.
    @Published private(set) var isContinuousEditing = false
    /// Name of the pixel operation running in the background, if any. One
    /// runs at a time; the status bar shows it.
    @Published var backgroundTaskLabel: String?
    /// Raw data of imported images, keyed by file name inside images/.
    /// Append-only within a session so undo can always resolve references.
    private(set) var images: [String: Data]
    /// Resident images whose PNG data is still being encoded off the main
    /// actor (fresh blank paint layers). Readers fall back to a synchronous
    /// encode, so a save, copy or export never sees a missing key.
    private var pendingImages: [String: CGImage] = [:]

    /// Pre-gesture model, captured while a slider drag is in flight so the
    /// whole drag collapses into one undo step.
    private var gestureSnapshot: ProjectModel?

    static var readableContentTypes: [UTType] { [.pixelFailureProject] }

    init() {
        model = .starter()
        images = [:]
        history = [Checkpoint(name: "Opened", model: model)]
    }

    /// A fresh document from the New Document dialog (or a prepared model,
    /// e.g. an image opened as a new canvas).
    init(model: ProjectModel) {
        self.model = model
        images = [:]
        history = [Checkpoint(name: "New", model: model)]
    }

    convenience init(configuration: ReadConfiguration) throws {
        try self.init(package: configuration.file)
    }

    /// Reads a project package outside the document system — used for
    /// recent-file thumbnails on the Home screen.
    convenience init(contentsOf url: URL) throws {
        try self.init(package: FileWrapper(url: url, options: .immediate))
    }

    private init(package root: FileWrapper) throws {
        guard let manifest = root.fileWrappers?["manifest.json"]?.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        model = try JSONDecoder().decode(ProjectModel.self, from: manifest)
        var loaded: [String: Data] = [:]
        if let imageWrappers = root.fileWrappers?["images"]?.fileWrappers {
            for (name, wrapper) in imageWrappers {
                if let data = wrapper.regularFileContents { loaded[name] = data }
            }
        }
        images = loaded
        if let data = root.fileWrappers?["snapshots.json"]?.regularFileContents {
            checkpoints = (try? JSONDecoder().decode([Checkpoint].self, from: data)) ?? []
        }
        history = [Checkpoint(name: "Opened", model: model)]
    }

    func snapshot(contentType: UTType) throws -> Snapshot {
        let live = liveImageKeys
        for key in Array(pendingImages.keys) where live.contains(key) { _ = flushPendingImage(key) }
        // The in-memory store stays append-only so undo can always resolve
        // older keys; only images something can still reach are persisted.
        return Snapshot(model: model, images: images.filter { live.contains($0.key) },
                        checkpoints: checkpoints)
    }

    /// Image keys reachable from what a saved package can reopen: the current
    /// model and named snapshots. Undo and the History panel are session-only,
    /// so strokes that were painted over are not written to disk.
    var liveImageKeys: Set<String> {
        var keys = model.referencedImageKeys
        for state in checkpoints { keys.formUnion(state.model.referencedImageKeys) }
        return keys
    }

    func fileWrapper(snapshot: Snapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifest = try encoder.encode(snapshot.model)

        let root = FileWrapper(directoryWithFileWrappers: [:])
        let manifestWrapper = FileWrapper(regularFileWithContents: manifest)
        manifestWrapper.preferredFilename = "manifest.json"
        root.addFileWrapper(manifestWrapper)

        // Keys are immutable UUIDs, so an image already in the saved package
        // never changes. Reusing its wrapper lets the write skip it.
        let existing = configuration.existingFile?.fileWrappers?["images"]?.fileWrappers ?? [:]
        var children: [String: FileWrapper] = [:]
        for (key, data) in snapshot.images {
            if let wrapper = existing[key], wrapper.isRegularFile {
                children[key] = wrapper
            } else {
                children[key] = FileWrapper(regularFileWithContents: data)
            }
        }
        let imagesDir = FileWrapper(directoryWithFileWrappers: children)
        imagesDir.preferredFilename = "images"
        root.addFileWrapper(imagesDir)
        if !snapshot.checkpoints.isEmpty {
            let data = try encoder.encode(snapshot.checkpoints)
            let wrapper = FileWrapper(regularFileWithContents: data)
            wrapper.preferredFilename = "snapshots.json"
            root.addFileWrapper(wrapper)
        }
        return root
    }

    // MARK: - Mutation with undo

    /// Apply a model change as one undoable step.
    @MainActor
    func update(_ undoManager: UndoManager?, actionName: String? = nil, _ mutate: (inout ProjectModel) -> Void) {
        let previous = model
        mutate(&model)
        guard model != previous else { return }
        if let actionName { undoManager?.setActionName(actionName) }
        registerUndo(undoManager, previous: previous)
        recordAutomation(from: previous, to: model)
        recordHistory(actionName ?? "Edit")
    }

    /// Call when a continuous edit (slider drag, canvas drag) starts.
    @MainActor
    func beginGesture() {
        if gestureSnapshot == nil { gestureSnapshot = model }
        isContinuousEditing = true
    }

    /// Mutate freely during a gesture; no undo registration per tick.
    @MainActor
    func updateDuringGesture(_ mutate: (inout ProjectModel) -> Void) {
        mutate(&model)
    }

    /// Call when the continuous edit ends; registers a single undo step.
    @MainActor
    func endGesture(_ undoManager: UndoManager?, actionName: String? = nil) {
        isContinuousEditing = false
        guard let previous = gestureSnapshot else { return }
        gestureSnapshot = nil
        guard model != previous else { return }
        if let actionName { undoManager?.setActionName(actionName) }
        registerUndo(undoManager, previous: previous)
        recordAutomation(from: previous, to: model)
        recordHistory(actionName ?? "Edit")
    }

    @MainActor
    private func registerUndo(_ undoManager: UndoManager?, previous: ProjectModel) {
        undoManager?.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated {
                let current = document.model
                document.model = previous
                document.registerUndo(undoManager, previous: current)
            }
        }
    }

    @MainActor
    private func recordHistory(_ name: String) {
        history.append(Checkpoint(name: name, model: model))
        let overflow = history.count - Self.maxHistoryCount
        if overflow > 0 { history.removeFirst(overflow) }
    }

    @MainActor
    private func recordAutomation(from old: ProjectModel, to new: ProjectModel) {
        guard actionRecorder.isRecording else { return }
        if old.canvasSize != new.canvasSize {
            actionRecorder.capture(.resize(width: new.canvasSize.width, height: new.canvasSize.height))
        }
        if old.background != new.background { actionRecorder.capture(.setBackground(new.background)) }
        if old.printSettings.dpi != new.printSettings.dpi {
            actionRecorder.capture(.setDPI(new.printSettings.dpi))
        }
        if new.canvasEffects.count > old.canvasEffects.count,
           Array(new.canvasEffects.prefix(old.canvasEffects.count)) == old.canvasEffects {
            for effect in new.canvasEffects.dropFirst(old.canvasEffects.count) {
                actionRecorder.capture(.addCanvasEffect(effect))
            }
        }
    }

    @MainActor
    func jumpToHistory(_ id: UUID, undoManager: UndoManager?) {
        guard let state = history.first(where: { $0.id == id }) else { return }
        update(undoManager, actionName: "Jump to \(state.name)") { $0 = state.model }
    }

    @MainActor
    func createCheckpoint(name: String) {
        checkpoints.append(Checkpoint(name: name, model: model))
    }

    @MainActor
    func restoreCheckpoint(_ id: UUID, undoManager: UndoManager?) {
        guard let state = checkpoints.first(where: { $0.id == id }) else { return }
        update(undoManager, actionName: "Restore Snapshot") { $0 = state.model }
    }

    /// A new, untitled document holding an archive's content, so recovering
    /// never replaces what another window shows.
    @MainActor
    static func recovered(from archive: RecoveryArchive) -> PixelDocument {
        let document = PixelDocument(model: archive.model)
        document.restoreRecovery(archive)
        document.isRecovered = true
        return document
    }

    @MainActor
    func restoreRecovery(_ archive: RecoveryArchive) {
        model = archive.model
        for (key, data) in archive.images where images[key] == nil { images[key] = data }
        checkpoints = archive.checkpoints
        history = [Checkpoint(name: "Recovered", model: model)]
    }

    // MARK: - Image store

    /// Store imported image data; returns the key an ImageConfig should reference.
    @MainActor
    func storeImage(data: Data, fileExtension: String) -> String {
        let key = UUID().uuidString + "." + fileExtension
        images[key] = data
        return key
    }

    /// Stores an already-resident image under a new key and encodes its PNG
    /// data in the background. Keeps first-stroke layer creation off the
    /// main actor's encode path.
    @MainActor
    func storeImageDeferringEncode(_ image: CGImage) -> String {
        let key = UUID().uuidString + ".png"
        pendingImages[key] = image
        let sendable = PendingImage(value: image)
        Task { @MainActor [weak self] in
            let data = await Task.detached(priority: .utility) {
                PNGExporter.pngData(sendable.value)
            }.value
            guard let self, let data, self.pendingImages.removeValue(forKey: key) != nil else { return }
            self.images[key] = data
        }
        return key
    }

    /// The in-memory image for a key whose data is still being encoded.
    func residentImage(for key: String) -> CGImage? { pendingImages[key] }

    func imageData(for key: String) -> Data? { images[key] ?? flushPendingImage(key) }

    private func flushPendingImage(_ key: String) -> Data? {
        guard let image = pendingImages[key], let data = PNGExporter.pngData(image) else { return nil }
        pendingImages[key] = nil
        images[key] = data
        return data
    }

    private struct PendingImage: @unchecked Sendable {
        let value: CGImage
    }
}
