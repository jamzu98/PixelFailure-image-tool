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
    struct Snapshot {
        var model: ProjectModel
        var images: [String: Data]
    }

    @Published var model: ProjectModel
    /// Raw data of imported images, keyed by file name inside images/.
    /// Append-only within a session so undo can always resolve references.
    private(set) var images: [String: Data]

    /// Pre-gesture model, captured while a slider drag is in flight so the
    /// whole drag collapses into one undo step.
    private var gestureSnapshot: ProjectModel?

    static var readableContentTypes: [UTType] { [.pixelFailureProject] }

    init() {
        model = .starter()
        images = [:]
    }

    init(configuration: ReadConfiguration) throws {
        let root = configuration.file
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
    }

    func snapshot(contentType: UTType) throws -> Snapshot {
        Snapshot(model: model, images: images)
    }

    func fileWrapper(snapshot: Snapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifest = try encoder.encode(snapshot.model)

        let root = FileWrapper(directoryWithFileWrappers: [:])
        let manifestWrapper = FileWrapper(regularFileWithContents: manifest)
        manifestWrapper.preferredFilename = "manifest.json"
        root.addFileWrapper(manifestWrapper)

        let imagesDir = FileWrapper(directoryWithFileWrappers:
            snapshot.images.mapValues { FileWrapper(regularFileWithContents: $0) })
        imagesDir.preferredFilename = "images"
        root.addFileWrapper(imagesDir)
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
    }

    /// Call when a continuous edit (slider drag, canvas drag) starts.
    @MainActor
    func beginGesture() {
        if gestureSnapshot == nil { gestureSnapshot = model }
    }

    /// Mutate freely during a gesture; no undo registration per tick.
    @MainActor
    func updateDuringGesture(_ mutate: (inout ProjectModel) -> Void) {
        mutate(&model)
    }

    /// Call when the continuous edit ends; registers a single undo step.
    @MainActor
    func endGesture(_ undoManager: UndoManager?, actionName: String? = nil) {
        guard let previous = gestureSnapshot else { return }
        gestureSnapshot = nil
        guard model != previous else { return }
        if let actionName { undoManager?.setActionName(actionName) }
        registerUndo(undoManager, previous: previous)
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

    // MARK: - Image store

    /// Store imported image data; returns the key an ImageConfig should reference.
    @MainActor
    func storeImage(data: Data, fileExtension: String) -> String {
        let key = UUID().uuidString + "." + fileExtension
        images[key] = data
        return key
    }

    func imageData(for key: String) -> Data? { images[key] }
}
