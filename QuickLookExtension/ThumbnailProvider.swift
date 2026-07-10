import AppKit
import QuickLookThumbnailing

final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let metadata = Self.metadata(at: request.fileURL)
        let requested = request.maximumSize
        let aspect = metadata.width / max(metadata.height, 1)
        let size: CGSize
        if aspect >= 1 {
            size = CGSize(width: requested.width, height: requested.width / aspect)
        } else {
            size = CGSize(width: requested.height * aspect, height: requested.height)
        }
        let reply = QLThumbnailReply(contextSize: size) { context in
            let rect = CGRect(origin: .zero, size: size)
            context.setFillColor(NSColor(calibratedRed: 0.13, green: 0.12, blue: 0.11, alpha: 1).cgColor)
            context.fill(rect)

            context.saveGState()
            let cell = max(8, min(size.width, size.height) / 12)
            for row in 0..<Int(ceil(size.height / cell)) {
                for column in 0..<Int(ceil(size.width / cell)) where (row + column).isMultiple(of: 2) {
                    context.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.035).cgColor)
                    context.fill(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell,
                                        width: cell, height: cell))
                }
            }
            context.restoreGState()

            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let title = "PIXEL\nFAILURE"
            title.draw(in: rect.insetBy(dx: size.width * 0.08, dy: size.height * 0.26),
                       withAttributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: max(12, size.width * 0.105),
                                                          weight: .black),
                        .foregroundColor: NSColor(calibratedRed: 0.77, green: 0.46, blue: 0.31, alpha: 1),
                        .paragraphStyle: paragraph,
                       ])
            let detail = "\(metadata.layers) layers  ·  \(Int(metadata.width)) × \(Int(metadata.height))"
            detail.draw(in: CGRect(x: 8, y: 10, width: size.width - 16, height: 24),
                        withAttributes: [
                            .font: NSFont.monospacedSystemFont(ofSize: max(8, size.width * 0.035),
                                                              weight: .medium),
                            .foregroundColor: NSColor(calibratedWhite: 0.86, alpha: 0.8),
                            .paragraphStyle: paragraph,
                        ])
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        handler(reply, nil)
    }

    private static func metadata(at packageURL: URL) -> (width: CGFloat, height: CGFloat, layers: Int) {
        guard let data = try? Data(contentsOf: packageURL.appendingPathComponent("manifest.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (1200, 1200, 0)
        }
        let canvas = json["canvasSize"] as? [Double]
        let layers = json["layers"] as? [[String: Any]]
        return (CGFloat(canvas?.first ?? 1200), CGFloat(canvas?.dropFirst().first ?? 1200),
                layers?.count ?? 0)
    }
}
