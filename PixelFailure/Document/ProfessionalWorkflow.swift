import AppKit
import CoreGraphics
import Foundation
import ImageIO

// MARK: - Stage 6: brush libraries

nonisolated enum BrushPresetLibrary {
    struct FileFormat: Codable, Sendable {
        var version = 1
        var presets: [BrushPreset]
    }

    static func export(_ presets: [BrushPreset]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(FileFormat(presets: presets))
    }

    static func `import`(_ data: Data, fileExtension: String) throws -> [BrushPreset] {
        if fileExtension.lowercased() != "abr" {
            return try JSONDecoder().decode(FileFormat.self, from: data).presets
        }
        guard data.count >= 4 else { throw CocoaError(.fileReadCorruptFile) }
        // ABR is a proprietary, versioned container. Preserve useful preset
        // names when present and create deterministic textured tips; unsupported
        // sampled-tip pixels degrade explicitly to an equivalent grain brush.
        let names = abrNames(in: data)
        return (names.isEmpty ? ["Imported ABR Brush"] : names).enumerated().map { index, name in
            BrushPreset(id: "abr-\(data.hashValue)-\(index)", name: name,
                        size: 96, hardness: 0.65, opacity: 0.8,
                        spacing: 0.18, smoothing: 0.3, scatter: 0.08,
                        sizeJitter: 0.08, opacityJitter: 0.08,
                        angleJitter: 0.2, tipAspect: 0.8, grain: 0.35)
        }
    }

    private static func abrNames(in data: Data) -> [String] {
        let bytes = [UInt8](data)
        var names: [String] = []
        var index = 0
        while index + 8 < bytes.count {
            let count = Int(bytes[index]) << 24 | Int(bytes[index + 1]) << 16 |
                        Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            if count > 2, count < 128, index + 4 + count * 2 <= bytes.count {
                let units = stride(from: index + 4, to: index + 4 + count * 2, by: 2).map {
                    UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1])
                }
                let value = String(decoding: units, as: UTF16.self)
                    .trimmingCharacters(in: .controlCharacters)
                if value.count > 2, value.unicodeScalars.allSatisfy({ $0.value >= 32 }) {
                    names.append(value)
                    index += 4 + count * 2
                    continue
                }
            }
            index += 1
        }
        return Array(names.prefix(256))
    }
}

// MARK: - Stage 7: autosave and crash recovery

nonisolated struct RecoveryArchive: Codable, Sendable {
    var savedAt: Date
    var model: ProjectModel
    var images: [String: Data]
    var checkpoints: [PixelDocument.Checkpoint]
}

/// Crash-recovery autosaves. Each editor window writes a `<id>.recovery`
/// directory (`manifest.json` + `images/` + `owner.json`) off the main
/// actor; image files are keyed by immutable UUIDs, so only new images are
/// written each time. `owner.json` records which file the window was
/// editing, so an archive is only ever offered back to that document.
/// Archives from older builds (a single JSON file) still load, and count
/// as untitled.
enum RecoveryStore {
    private nonisolated struct Manifest: Codable, Sendable {
        var savedAt: Date
        var model: ProjectModel
        var checkpoints: [PixelDocument.Checkpoint]
    }

    /// Small sidecar so matching an archive to a document never has to
    /// decode its whole model.
    private nonisolated struct Owner: Codable, Sendable {
        /// Standardized path of the document file; nil for untitled windows.
        var documentPath: String?
    }

    /// Archives that windows in this process are writing right now. They
    /// belong to an open document and are never offered for recovery.
    private static var liveIdentifiers: Set<UUID> = []

    static func markLive(_ identifier: UUID) { liveIdentifiers.insert(identifier) }

    nonisolated static func documentPath(_ url: URL?) -> String? {
        url?.standardizedFileURL.resolvingSymlinksInPath().path
    }

    nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("PixelFailure/Recovery", isDirectory: true)
    }

    /// Writes synchronously. Prefer `saveInBackground` from the editor.
    static func save(_ document: PixelDocument, identifier: UUID, documentURL: URL? = nil) throws -> URL {
        let snapshot = try document.snapshot(contentType: .pixelFailureProject)
        let url = url(identifier: identifier)
        try write(model: snapshot.model, images: snapshot.images,
                  checkpoints: snapshot.checkpoints, documentPath: documentPath(documentURL), to: url)
        return url
    }

    /// Takes a copy-on-write snapshot on the main actor, then encodes and
    /// writes it on a background writer that serializes saves.
    @discardableResult
    static func saveInBackground(_ document: PixelDocument, identifier: UUID,
                                 documentURL: URL? = nil) async throws -> URL {
        let snapshot = try document.snapshot(contentType: .pixelFailureProject)
        let url = url(identifier: identifier)
        try await RecoveryWriter.shared.write(model: snapshot.model, images: snapshot.images,
                                              checkpoints: snapshot.checkpoints,
                                              documentPath: documentPath(documentURL), to: url)
        return url
    }

    /// The newest archive worth offering to a window that just opened
    /// `documentURL` (nil = untitled): one written for that same file, not by
    /// a window that is still open, and holding something different from
    /// what the window already shows.
    static func recoverableArchive(for documentURL: URL?, currentModel: ProjectModel) -> URL? {
        let path = documentPath(documentURL)
        for candidate in available() {
            if let id = identifier(of: candidate), liveIdentifiers.contains(id) { continue }
            guard owner(of: candidate) == path,
                  let model = try? loadModel(candidate) else { continue }
            if model == currentModel {
                // The document already holds this content (saved or
                // autosaved in place), so the archive is spent.
                try? discard(candidate)
                continue
            }
            return candidate
        }
        return nil
    }

    nonisolated static func owner(of archiveURL: URL) -> String? {
        let ownerURL = archiveURL.appendingPathComponent("owner.json")
        guard let data = try? Data(contentsOf: ownerURL),
              let owner = try? JSONDecoder().decode(Owner.self, from: data) else { return nil }
        return owner.documentPath
    }

    nonisolated static func identifier(of archiveURL: URL) -> UUID? {
        UUID(uuidString: archiveURL.deletingPathExtension().lastPathComponent)
    }

    nonisolated static func write(model: ProjectModel, images: [String: Data],
                                  checkpoints: [PixelDocument.Checkpoint],
                                  documentPath: String? = nil, to url: URL) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            try fileManager.removeItem(at: url) // legacy single-file archive
        }
        let imagesURL = url.appendingPathComponent("images", isDirectory: true)
        try fileManager.createDirectory(at: imagesURL, withIntermediateDirectories: true)

        let present = Set((try? fileManager.contentsOfDirectory(atPath: imagesURL.path)) ?? [])
        for (key, data) in images where !present.contains(key) {
            try data.write(to: imagesURL.appendingPathComponent(key), options: .atomic)
        }
        // The manifest goes last, so a crash mid-write leaves the previous
        // manifest pointing at images that are all still on disk.
        try JSONEncoder().encode(Owner(documentPath: documentPath))
            .write(to: url.appendingPathComponent("owner.json"), options: .atomic)
        let manifest = Manifest(savedAt: Date(), model: model, checkpoints: checkpoints)
        try JSONEncoder().encode(manifest)
            .write(to: url.appendingPathComponent("manifest.json"), options: .atomic)
        for stale in present where images[stale] == nil {
            try? fileManager.removeItem(at: imagesURL.appendingPathComponent(stale))
        }
    }

    static func available() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory,
                                                       includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "recovery" }
            .sorted { modificationDate($0) > modificationDate($1) }
    }

    /// When the archive was last written.
    static func modificationDate(_ url: URL) -> Date {
        let manifest = url.appendingPathComponent("manifest.json")
        let target = FileManager.default.fileExists(atPath: manifest.path) ? manifest : url
        return (try? target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    static func load(_ url: URL) throws -> RecoveryArchive {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard isDirectory.boolValue else {
            return try JSONDecoder().decode(RecoveryArchive.self, from: Data(contentsOf: url))
        }
        let manifest = try JSONDecoder().decode(
            Manifest.self, from: Data(contentsOf: url.appendingPathComponent("manifest.json")))
        let imagesURL = url.appendingPathComponent("images", isDirectory: true)
        var images: [String: Data] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: imagesURL.path)) ?? [] {
            images[name] = try Data(contentsOf: imagesURL.appendingPathComponent(name))
        }
        return RecoveryArchive(savedAt: manifest.savedAt, model: manifest.model,
                               images: images, checkpoints: manifest.checkpoints)
    }

    /// Just the archived model, without reading any image files.
    static func loadModel(_ url: URL) throws -> ProjectModel {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard isDirectory.boolValue else { return try load(url).model }
        return try JSONDecoder().decode(Manifest.self,
                                        from: Data(contentsOf: url.appendingPathComponent("manifest.json"))).model
    }

    static func discard(_ url: URL) throws { try FileManager.default.removeItem(at: url) }

    nonisolated static func url(identifier: UUID) -> URL {
        directory.appendingPathComponent(identifier.uuidString).appendingPathExtension("recovery")
    }

    /// Removes a document's archive after any write already queued for it,
    /// so a closing window can't leave a stale archive behind.
    static func discard(identifier: UUID) {
        liveIdentifiers.remove(identifier)
        let url = url(identifier: identifier)
        Task { await RecoveryWriter.shared.remove(url) }
    }
}

/// Serializes recovery writes so two autosaves never interleave on disk.
actor RecoveryWriter {
    static let shared = RecoveryWriter()

    func write(model: ProjectModel, images: [String: Data],
               checkpoints: [PixelDocument.Checkpoint], documentPath: String?, to url: URL) throws {
        try RecoveryStore.write(model: model, images: images, checkpoints: checkpoints,
                                documentPath: documentPath, to: url)
    }

    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Stage 9: slices and scaled assets

nonisolated enum AssetExporter {
    struct Asset: Sendable {
        var name: String
        var scale: Int
        var data: Data
    }

    static func assets(from image: CGImage, slices: [ExportSlice], format: ImageEncoder.Format = .png)
        -> [Asset] {
        slices.flatMap { slice -> [Asset] in
            let source = CGRect(x: slice.rect.minX,
                                y: CGFloat(image.height) - slice.rect.maxY,
                                width: slice.rect.width, height: slice.rect.height).integral
            guard let cropped = image.cropping(to: source) else { return [] }
            return slice.scales.compactMap { scale -> Asset? in
                let target = CGSize(width: cropped.width * scale, height: cropped.height * scale)
                guard let context = CGContext(data: nil, width: Int(target.width), height: Int(target.height),
                                              bitsPerComponent: 8, bytesPerRow: 0,
                                              space: cropped.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                context.interpolationQuality = .high
                context.draw(cropped, in: CGRect(origin: .zero, size: target))
                guard let scaled = context.makeImage(),
                      let data = ImageEncoder.encode(scaled, format: format) else { return nil }
                return Asset(name: "\(slice.name)@\(scale)x.\(format.fileExtension)", scale: scale, data: data)
            }
        }
    }
}

// MARK: - Stage 10: recordable actions and batch application

nonisolated enum AutomationStep: Codable, Hashable, Sendable {
    case resize(width: Double, height: Double)
    case setBackground(RGBAColor)
    case addCanvasEffect(Effect)
    case setDPI(Double)
}

nonisolated struct RecordedAction: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var steps: [AutomationStep]
}

@MainActor
final class ActionRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var steps: [AutomationStep] = []

    func start() { steps = []; isRecording = true }
    func capture(_ step: AutomationStep) { if isRecording { steps.append(step) } }
    func stop(name: String) -> RecordedAction {
        isRecording = false
        return RecordedAction(name: name, steps: steps)
    }
}

nonisolated enum ActionExecutor {
    static func apply(_ action: RecordedAction, to model: inout ProjectModel) {
        for step in action.steps {
            switch step {
            case .resize(let width, let height):
                model.canvasSize = CGSize(width: max(1, width), height: max(1, height))
            case .setBackground(let color): model.background = color
            case .addCanvasEffect(let effect): model.canvasEffects.append(effect)
            case .setDPI(let dpi): model.printSettings.dpi = max(1, dpi)
            }
        }
    }
}

@MainActor
enum BatchProcessor {
    struct Result: Sendable { var input: URL; var output: URL; var error: String? }

    static func process(urls: [URL], action: RecordedAction, outputDirectory: URL,
                        format: ImageEncoder.Format = .png) -> [Result] {
        urls.map { input in
            do {
                let data = try Data(contentsOf: input)
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                var model = ProjectModel(canvasSize: CGSize(width: image.width, height: image.height))
                ActionExecutor.apply(action, to: &model)
                var output = image
                if !model.canvasEffects.isEmpty {
                    output = EffectPipeline.shared.apply(effects: model.canvasEffects, to: image,
                                                         palette: model.palette)
                }
                guard let encoded = ImageEncoder.encode(output, format: format) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let url = outputDirectory.appendingPathComponent(input.deletingPathExtension().lastPathComponent)
                    .appendingPathExtension(format.fileExtension)
                try encoded.write(to: url, options: .atomic)
                return Result(input: input, output: url, error: nil)
            } catch {
                return Result(input: input, output: outputDirectory, error: error.localizedDescription)
            }
        }
    }
}

// MARK: - Scoped plugin contract (marketplace and dynamic code loading deferred)

nonisolated struct PluginManifest: Codable, Hashable, Sendable {
    var identifier: String
    var name: String
    var version: String
    var minimumAPIVersion: Int
}

@MainActor
protocol PixelFailurePlugin: AnyObject {
    var manifest: PluginManifest { get }
    var actions: [RecordedAction] { get }
}

@MainActor
final class PluginRegistry {
    static let apiVersion = 1
    private(set) var plugins: [String: any PixelFailurePlugin] = [:]

    func register(_ plugin: any PixelFailurePlugin) throws {
        guard plugin.manifest.minimumAPIVersion <= Self.apiVersion else {
            throw CocoaError(.featureUnsupported)
        }
        plugins[plugin.manifest.identifier] = plugin
    }

    func unregister(identifier: String) { plugins[identifier] = nil }
}
