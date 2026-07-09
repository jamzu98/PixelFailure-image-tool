import AppKit
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    nonisolated static var pixelFailureLayer: UTType { UTType(exportedAs: "com.pixelfailure.layer") }
}

/// A layer (possibly a whole group subtree) on the pasteboard: the layer
/// model, every image it references keyed by store key (so pasting across
/// documents works), and a flattened PNG so other apps can paste the pixels.
nonisolated struct LayerTransfer: Codable, Sendable, Transferable {
    var layer: Layer
    /// Image-store bytes for every key referenced in the subtree.
    var images: [String: Data]?
    /// Not persisted in the JSON representation — only offered to other apps.
    var flattenedPNG: Data?

    init(layer: Layer, images: [String: Data]? = nil, flattenedPNG: Data? = nil) {
        self.layer = layer
        self.images = images
        self.flattenedPNG = flattenedPNG
    }

    private enum CodingKeys: String, CodingKey {
        case layer, images, imageData
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layer = try container.decode(Layer.self, forKey: .layer)
        images = try container.decodeIfPresent([String: Data].self, forKey: .images)
        // Payloads from before groups carried a single image's bytes.
        if images == nil,
           let legacy = try container.decodeIfPresent(Data.self, forKey: .imageData),
           let key = layer.imageConfig?.imageKey {
            images = [key: legacy]
        }
        flattenedPNG = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(layer, forKey: .layer)
        try container.encodeIfPresent(images, forKey: .images)
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pixelFailureLayer)
        DataRepresentation(exportedContentType: .png) { $0.flattenedPNG ?? Data() }
    }
}

/// What a paste can produce: one of our layers, or raw image bytes from
/// any other app (screenshot, browser copy, Finder file).
nonisolated enum PastePayload {
    case layer(LayerTransfer)
    case image(data: Data, fileExtension: String)
}

/// Manual pasteboard access for context menus. Uses the same content type and
/// JSON encoding as the Transferable path, so both interoperate.
enum LayerPasteboard {
    static let pasteboardType = NSPasteboard.PasteboardType(UTType.pixelFailureLayer.identifier)

    static func write(_ transfer: LayerTransfer) {
        guard let data = try? JSONEncoder().encode(transfer) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: pasteboardType)
        if let png = transfer.flattenedPNG {
            pasteboard.setData(png, forType: .png)
        }
    }

    /// Our own layer if present, otherwise any pasteboard image.
    static func readAny() -> PastePayload? {
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: pasteboardType),
           let transfer = try? JSONDecoder().decode(LayerTransfer.self, from: data) {
            return .layer(transfer)
        }
        if let data = pasteboard.data(forType: .png) {
            return .image(data: data, fileExtension: "png")
        }
        if let data = pasteboard.data(forType: .tiff) {
            return .image(data: data, fileExtension: "tiff")
        }
        // Image files copied in Finder arrive as file URLs.
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           let url = urls.first,
           let data = try? Data(contentsOf: url) {
            let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
            return .image(data: data, fileExtension: ext)
        }
        return nil
    }

    /// Cheap enablement check for menus (no decoding).
    static var hasPayload: Bool {
        let pasteboard = NSPasteboard.general
        return pasteboard.availableType(from: [pasteboardType, .png, .tiff, .fileURL]) != nil
    }

    static var hasLayer: Bool {
        NSPasteboard.general.data(forType: pasteboardType) != nil
    }
}
