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

enum RecoveryStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("PixelFailure/Recovery", isDirectory: true)
    }

    static func save(_ document: PixelDocument, identifier: UUID) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot = try document.snapshot(contentType: .pixelFailureProject)
        let archive = RecoveryArchive(savedAt: Date(), model: snapshot.model,
                                      images: snapshot.images,
                                      checkpoints: snapshot.checkpoints)
        let url = url(identifier: identifier)
        try JSONEncoder().encode(archive).write(to: url, options: .atomic)
        return url
    }

    static func available() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory,
                                                       includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "recovery" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
                      ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
    }

    static func load(_ url: URL) throws -> RecoveryArchive {
        try JSONDecoder().decode(RecoveryArchive.self, from: Data(contentsOf: url))
    }

    static func discard(_ url: URL) throws { try FileManager.default.removeItem(at: url) }

    static func url(identifier: UUID) -> URL {
        directory.appendingPathComponent(identifier.uuidString).appendingPathExtension("recovery")
    }

    static func discard(identifier: UUID) {
        try? FileManager.default.removeItem(at: url(identifier: identifier))
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
