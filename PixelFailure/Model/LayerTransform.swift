import CoreGraphics

/// Position/scale/rotation of a layer. Content is generated in its own local
/// space (origin at top-left, extent = natural size); this maps the local
/// space into canvas coordinates with the content centered at `position`.
nonisolated struct LayerTransform: Codable, Hashable, Sendable {
    /// Center of the content, in canvas coordinates.
    var position: CGPoint
    var scale: Double
    var rotationDegrees: Double
    var flippedHorizontally: Bool
    var flippedVertically: Bool

    init(position: CGPoint, scale: Double = 1, rotationDegrees: Double = 0,
         flippedHorizontally: Bool = false, flippedVertically: Bool = false) {
        self.position = position
        self.scale = scale
        self.rotationDegrees = rotationDegrees
        self.flippedHorizontally = flippedHorizontally
        self.flippedVertically = flippedVertically
    }

    // Custom decoding so documents saved before flips existed still open.
    private enum CodingKeys: String, CodingKey {
        case position, scale, rotationDegrees, flippedHorizontally, flippedVertically
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        position = try container.decode(CGPoint.self, forKey: .position)
        scale = try container.decode(Double.self, forKey: .scale)
        rotationDegrees = try container.decode(Double.self, forKey: .rotationDegrees)
        flippedHorizontally = try container.decodeIfPresent(Bool.self, forKey: .flippedHorizontally) ?? false
        flippedVertically = try container.decodeIfPresent(Bool.self, forKey: .flippedVertically) ?? false
    }

    var rotationRadians: Double { rotationDegrees * .pi / 180 }

    /// Local (0..naturalSize) → canvas coordinates.
    func affine(naturalSize: CGSize) -> CGAffineTransform {
        CGAffineTransform.identity
            .translatedBy(x: position.x, y: position.y)
            .rotated(by: CGFloat(rotationRadians))
            .scaledBy(x: CGFloat(scale), y: CGFloat(scale))
            // Mirror within the content box (applied around its center
            // because the centering translation comes after).
            .scaledBy(x: flippedHorizontally ? -1 : 1, y: flippedVertically ? -1 : 1)
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

    /// Composes this (child) transform with a parent group's transform so
    /// the layer looks identical after being pulled out of the group.
    /// Both are similarity transforms (uniform scale · rotation · flips), so
    /// the composition stays representable.
    func composed(withParent parent: LayerTransform, parentNaturalSize: CGSize) -> LayerTransform {
        let parentAffine = parent.affine(naturalSize: parentNaturalSize)
        // A single mirror in the parent reverses the child's rotation sense.
        let parentMirrors = parent.flippedHorizontally != parent.flippedVertically
        return LayerTransform(
            position: position.applying(parentAffine),
            scale: parent.scale * scale,
            rotationDegrees: parent.rotationDegrees + (parentMirrors ? -rotationDegrees : rotationDegrees),
            flippedHorizontally: parent.flippedHorizontally != flippedHorizontally,
            flippedVertically: parent.flippedVertically != flippedVertically)
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
