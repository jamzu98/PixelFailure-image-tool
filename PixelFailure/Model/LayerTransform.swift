import CoreGraphics

/// Position/scale/rotation of a layer. Content is generated in its own local
/// space (origin at top-left, extent = natural size); this maps the local
/// space into canvas coordinates with the content centered at `position`.
nonisolated struct LayerTransform: Codable, Hashable, Sendable {
    /// Center of the content, in canvas coordinates.
    var position: CGPoint
    var scale: Double
    var rotationDegrees: Double
    /// Affine skew in degrees. Kept separate from rotation so inspectors can
    /// edit it without decomposing a matrix.
    var skewXDegrees: Double
    var skewYDegrees: Double
    var flippedHorizontally: Bool
    var flippedVertically: Bool
    /// Optional non-affine transform evaluated after the affine transform.
    var deformation: LayerDeformation?

    init(position: CGPoint, scale: Double = 1, rotationDegrees: Double = 0,
         skewXDegrees: Double = 0, skewYDegrees: Double = 0,
         flippedHorizontally: Bool = false, flippedVertically: Bool = false,
         deformation: LayerDeformation? = nil) {
        self.position = position
        self.scale = scale
        self.rotationDegrees = rotationDegrees
        self.skewXDegrees = skewXDegrees
        self.skewYDegrees = skewYDegrees
        self.flippedHorizontally = flippedHorizontally
        self.flippedVertically = flippedVertically
        self.deformation = deformation
    }

    // Custom decoding so documents saved before flips existed still open.
    private enum CodingKeys: String, CodingKey {
        case position, scale, rotationDegrees, skewXDegrees, skewYDegrees,
             flippedHorizontally, flippedVertically, deformation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        position = try container.decode(CGPoint.self, forKey: .position)
        scale = try container.decode(Double.self, forKey: .scale)
        rotationDegrees = try container.decode(Double.self, forKey: .rotationDegrees)
        skewXDegrees = try container.decodeIfPresent(Double.self, forKey: .skewXDegrees) ?? 0
        skewYDegrees = try container.decodeIfPresent(Double.self, forKey: .skewYDegrees) ?? 0
        flippedHorizontally = try container.decodeIfPresent(Bool.self, forKey: .flippedHorizontally) ?? false
        flippedVertically = try container.decodeIfPresent(Bool.self, forKey: .flippedVertically) ?? false
        deformation = try container.decodeIfPresent(LayerDeformation.self, forKey: .deformation)
    }

    var rotationRadians: Double { rotationDegrees * .pi / 180 }

    /// Local (0..naturalSize) → canvas coordinates.
    func affine(naturalSize: CGSize) -> CGAffineTransform {
        CGAffineTransform.identity
            .translatedBy(x: position.x, y: position.y)
            .rotated(by: CGFloat(rotationRadians))
            .concatenating(CGAffineTransform(a: 1,
                                             b: tan(CGFloat(skewYDegrees * .pi / 180)),
                                             c: tan(CGFloat(skewXDegrees * .pi / 180)),
                                             d: 1, tx: 0, ty: 0))
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
            skewXDegrees: skewXDegrees + parent.skewXDegrees,
            skewYDegrees: skewYDegrees + parent.skewYDegrees,
            flippedHorizontally: parent.flippedHorizontally != flippedHorizontally,
            flippedVertically: parent.flippedVertically != flippedVertically,
            deformation: deformation)
    }

    /// Re-expresses a canvas-space transform in a destination parent's local
    /// coordinate space. The model only permits similarity transforms, so the
    /// affine can be decomposed without skew loss.
    static func rebased(world: LayerTransform, destinationParent: CGAffineTransform) -> LayerTransform? {
        guard destinationParent.isInvertible else { return nil }
        let local = world.affine(naturalSize: .zero)
            .concatenating(destinationParent.inverted())
        let determinant = local.a * local.d - local.b * local.c
        let horizontalFlip = determinant < 0
        let xA = horizontalFlip ? -local.a : local.a
        let xB = horizontalFlip ? -local.b : local.b
        let xScale = hypot(local.a, local.b)
        let yScale = hypot(local.c, local.d)
        let scale = (xScale + yScale) / 2
        guard scale.isFinite, scale > 1e-12 else { return nil }
        return LayerTransform(
            position: CGPoint(x: local.tx, y: local.ty),
            scale: scale,
            rotationDegrees: atan2(xB, xA) * 180 / .pi,
            flippedHorizontally: horizontalFlip,
            flippedVertically: false)
    }

    /// Whether a canvas-space point falls inside the transformed content rect.
    func contains(_ point: CGPoint, naturalSize: CGSize) -> Bool {
        if let deformation {
            return deformation.triangles(size: naturalSize).contains { triangle in
                triangleContains(triangle.destination,
                                 point.applying(affine(naturalSize: naturalSize).inverted()))
            }
        }
        let t = affine(naturalSize: naturalSize)
        guard t.isInvertible else { return false }
        let local = point.applying(t.inverted())
        return (0...naturalSize.width).contains(local.x) && (0...naturalSize.height).contains(local.y)
    }
}

/// Non-affine layer geometry. Control points are unit coordinates so a smart
/// object can change resolution without changing its distortion.
nonisolated enum LayerDeformation: Codable, Hashable, Sendable {
    /// Destination corners in TL, TR, BR, BL order.
    case cornerPin([CGPoint])
    /// Row-major destination points for a regular source grid.
    case warpMesh(columns: Int, rows: Int, points: [CGPoint])

    static let identityCornerPin: LayerDeformation = .cornerPin([
        CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
        CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1),
    ])

    struct Triangle: Hashable, Sendable {
        var source: (CGPoint, CGPoint, CGPoint)
        var destination: (CGPoint, CGPoint, CGPoint)

        static func == (lhs: Triangle, rhs: Triangle) -> Bool {
            [lhs.source.0, lhs.source.1, lhs.source.2, lhs.destination.0,
             lhs.destination.1, lhs.destination.2] ==
            [rhs.source.0, rhs.source.1, rhs.source.2, rhs.destination.0,
             rhs.destination.1, rhs.destination.2]
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(source.0); hasher.combine(source.1); hasher.combine(source.2)
            hasher.combine(destination.0); hasher.combine(destination.1); hasher.combine(destination.2)
        }
    }

    func triangles(size: CGSize) -> [Triangle] {
        let columns: Int, rows: Int, points: [CGPoint]
        switch self {
        case .cornerPin(let corners):
            guard corners.count == 4 else { return [] }
            columns = 2; rows = 2
            // Grid order is TL, TR, BL, BR.
            points = [corners[0], corners[1], corners[3], corners[2]]
        case .warpMesh(let c, let r, let p):
            guard c >= 2, r >= 2, p.count == c * r else { return [] }
            columns = c; rows = r; points = p
        }
        func scaled(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * size.width, y: p.y * size.height)
        }
        var output: [Triangle] = []
        for row in 0..<(rows - 1) {
            for column in 0..<(columns - 1) {
                let u0 = CGFloat(column) / CGFloat(columns - 1)
                let u1 = CGFloat(column + 1) / CGFloat(columns - 1)
                let v0 = CGFloat(row) / CGFloat(rows - 1)
                let v1 = CGFloat(row + 1) / CGFloat(rows - 1)
                let s00 = scaled(CGPoint(x: u0, y: v0)), s10 = scaled(CGPoint(x: u1, y: v0))
                let s01 = scaled(CGPoint(x: u0, y: v1)), s11 = scaled(CGPoint(x: u1, y: v1))
                let d00 = scaled(points[row * columns + column])
                let d10 = scaled(points[row * columns + column + 1])
                let d01 = scaled(points[(row + 1) * columns + column])
                let d11 = scaled(points[(row + 1) * columns + column + 1])
                output.append(Triangle(source: (s00, s10, s11), destination: (d00, d10, d11)))
                output.append(Triangle(source: (s00, s11, s01), destination: (d00, d11, d01)))
            }
        }
        return output
    }
}

extension LayerDeformation.Triangle {
    /// Affine map from this source triangle to its destination triangle.
    nonisolated var affine: CGAffineTransform? {
        let s0 = source.0, s1 = source.1, s2 = source.2
        let d0 = destination.0, d1 = destination.1, d2 = destination.2
        let sourceMatrix = CGAffineTransform(a: s1.x - s0.x, b: s1.y - s0.y,
                                             c: s2.x - s0.x, d: s2.y - s0.y,
                                             tx: s0.x, ty: s0.y)
        guard sourceMatrix.isInvertible else { return nil }
        let destinationMatrix = CGAffineTransform(a: d1.x - d0.x, b: d1.y - d0.y,
                                                  c: d2.x - d0.x, d: d2.y - d0.y,
                                                  tx: d0.x, ty: d0.y)
        return sourceMatrix.inverted().concatenating(destinationMatrix)
    }
}

private nonisolated func triangleContains(_ triangle: (CGPoint, CGPoint, CGPoint),
                                          _ point: CGPoint) -> Bool {
    let a = triangle.0, b = triangle.1, c = triangle.2
    let d1 = (point.x - b.x) * (a.y - b.y) - (a.x - b.x) * (point.y - b.y)
    let d2 = (point.x - c.x) * (b.y - c.y) - (b.x - c.x) * (point.y - c.y)
    let d3 = (point.x - a.x) * (c.y - a.y) - (c.x - a.x) * (point.y - a.y)
    return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0))
}

extension CGAffineTransform {
    nonisolated var isInvertible: Bool {
        let det = a * d - b * c
        return det.isFinite && abs(det) > 1e-12
    }
}
