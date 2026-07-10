import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

/// Encodes rendered bitmaps into the raster export formats.
nonisolated enum ImageEncoder {
    enum Format: String, CaseIterable, Sendable {
        case png = "PNG"
        case jpeg = "JPEG"
        case tiff = "TIFF"
        case heic = "HEIC"
        case webp = "WebP"

        var utType: UTType {
            switch self {
            case .png: .png
            case .jpeg: .jpeg
            case .tiff: .tiff
            case .heic: .heic
            case .webp: .webP
            }
        }

        var fileExtension: String {
            switch self {
            case .png: "png"
            case .jpeg: "jpg"
            case .tiff: "tiff"
            case .heic: "heic"
            case .webp: "webp"
            }
        }

        var isLossy: Bool {
            self == .jpeg || self == .heic || self == .webp
        }

        var isAvailable: Bool {
            let destinations = CGImageDestinationCopyTypeIdentifiers() as! [String]
            return destinations.contains(utType.identifier)
        }

        static var allCases: [Format] {
            let standard: [Format] = [.png, .jpeg, .tiff, .heic]
            return Format.webp.isAvailable ? standard + [.webp] : standard
        }
    }

    static func encode(_ image: CGImage, format: Format, quality: Double = 0.9,
                       background: RGBAColor = .white) -> Data? {
        // JPEG has no alpha channel — flatten onto the given background first.
        let source = format == .jpeg ? flattened(image, over: background) ?? image : image

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, format.utType.identifier as CFString, 1, nil) else { return nil }

        var options: [CFString: Any] = [:]
        if format.isLossy {
            options[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0.05), 1)
        }
        CGImageDestinationAddImage(destination, source, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func flattened(_ image: CGImage, over background: RGBAColor) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(background.cgColor)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }
}

/// A deliberately explicit PDF degradation path: the complete composited
/// result is embedded as one page, preserving appearance when the document
/// contains effects that PDF cannot represent as editable objects.
nonisolated enum PDFExporter {
    static func data(image: CGImage, pageSize: CGSize) -> Data? {
        let result = NSMutableData()
        guard let consumer = CGDataConsumer(data: result as CFMutableData) else { return nil }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        context.beginPDFPage(nil)
        context.draw(image, in: mediaBox)
        context.endPDFPage()
        context.closePDF()
        return result as Data
    }
}
