import AppKit
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    nonisolated static var pixelFailureLayer: UTType { UTType(exportedAs: "com.pixelfailure.layer") }
}

/// A layer on the pasteboard: the layer itself plus, for image layers, the
/// image bytes so pasting works across documents.
nonisolated struct LayerTransfer: Codable, Sendable, Transferable {
    var layer: Layer
    var imageData: Data?

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pixelFailureLayer)
    }
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
    }

    static func read() -> LayerTransfer? {
        guard let data = NSPasteboard.general.data(forType: pasteboardType) else { return nil }
        return try? JSONDecoder().decode(LayerTransfer.self, from: data)
    }

    static var hasLayer: Bool {
        NSPasteboard.general.data(forType: pasteboardType) != nil
    }
}
