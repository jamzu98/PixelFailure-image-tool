import CoreGraphics

/// Position/scale/rotation of a layer. Content is generated in its own local
/// space (origin at top-left, extent = natural size); this maps the local
/// space into canvas coordinates with the content centered at `position`.
nonisolated struct LayerTransform: Codable, Hashable, Sendable {
    /// Center of the content, in canvas coordinates.
    var position: CGPoint
    var scale: Double
    var rotationDegrees: Double

    init(position: CGPoint, scale: Double = 1, rotationDegrees: Double = 0) {
        self.position = position
        self.scale = scale
        self.rotationDegrees = rotationDegrees
    }

    var rotationRadians: Double { rotationDegrees * .pi / 180 }

    /// Local (0..naturalSize) → canvas coordinates.
    func affine(naturalSize: CGSize) -> CGAffineTransform {
        CGAffineTransform.identity
            .translatedBy(x: position.x, y: position.y)
            .rotated(by: CGFloat(rotationRadians))
            .scaledBy(x: CGFloat(scale), y: CGFloat(scale))
            .translatedBy(x: -naturalSize.width / 2, y: -naturalSize.height / 2)
    }

    /// The four corners of the content rect, in canvas coordinates.
    func corners(naturalSize: CGSize) -> [CGPoint] {
        let t = affine(naturalSize: naturalSize)
        return [
            CGPoint(x: 0, y: 0),
            CGPoint(x: naturalSize.width, y: 0),
            CGPoint(x: naturalSize.width, y: naturalSize.height),
            CGPoint(x: 0, y: naturalSize.height),
        ].map { $0.applying(t) }
    }

    /// Whether a canvas-space point falls inside the transformed content rect.
    func contains(_ point: CGPoint, naturalSize: CGSize) -> Bool {
        let t = affine(naturalSize: naturalSize)
        guard t.isInvertible else { return false }
        let local = point.applying(t.inverted())
        return (0...naturalSize.width).contains(local.x) && (0...naturalSize.height).contains(local.y)
    }
}

extension CGAffineTransform {
    nonisolated var isInvertible: Bool {
        let det = a * d - b * c
        return det.isFinite && abs(det) > 1e-12
    }
}
