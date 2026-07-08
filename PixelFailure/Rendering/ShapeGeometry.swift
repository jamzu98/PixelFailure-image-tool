import SwiftUI

/// Builds the vector path + primitives for a shape layer, in local space
/// (origin top-left, extent = config.size).
nonisolated enum ShapeGeometry {
    static func path(for config: ShapeConfig) -> Path {
        let rect = CGRect(origin: .zero, size: config.size)
        let minDim = min(rect.width, rect.height)
        switch config.kind {
        case .rectangle:
            return Path(rect)
        case .roundedRectangle:
            return Path(roundedRect: rect, cornerRadius: minDim * CGFloat(min(max(config.cornerRadius, 0), 0.5)))
        case .ellipse:
            return Path(ellipseIn: rect)
        case .line:
            var path = Path()
            path.move(to: CGPoint(x: 0, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        case .polygon:
            return GenShape.polygon(center: CGPoint(x: rect.midX, y: rect.midY),
                                    radius: Double(minDim) / 2,
                                    sides: max(3, config.sides),
                                    rotation: -.pi / 2)
        case .star:
            return star(center: CGPoint(x: rect.midX, y: rect.midY),
                        outerRadius: Double(minDim) / 2,
                        innerRatio: min(max(config.starInnerRatio, 0.1), 0.95),
                        points: max(3, config.sides))
        }
    }

    static func primitives(for config: ShapeConfig) -> [VectorPrimitive] {
        let shapePath = path(for: config)
        // A line has no fillable area; promote fill to stroke so it stays visible.
        let isLine = config.kind == .line
        let stroke = config.stroke ?? (isLine ? config.fill : nil)
        return [VectorPrimitive(path: shapePath,
                                fill: isLine ? nil : config.fill,
                                stroke: stroke,
                                lineWidth: max(0.5, config.strokeWidth),
                                lineCap: .round,
                                lineJoin: .round)]
    }

    private static func star(center: CGPoint, outerRadius: Double, innerRatio: Double, points: Int) -> Path {
        var path = Path()
        let inner = outerRadius * innerRatio
        for i in 0..<(points * 2) {
            let radius = i.isMultiple(of: 2) ? outerRadius : inner
            let angle = -Double.pi / 2 + Double(i) * .pi / Double(points)
            let point = CGPoint(x: center.x + CGFloat(cos(angle) * radius),
                                y: center.y + CGFloat(sin(angle) * radius))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// Endpoints for a linear gradient across a rect at `angleDegrees`
    /// (0 = left→right, 90 = top→bottom).
    static func linearGradientPoints(angleDegrees: Double, in size: CGSize) -> (start: CGPoint, end: CGPoint) {
        let angle = angleDegrees * .pi / 180
        let dir = CGPoint(x: cos(angle), y: sin(angle))
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let half = (abs(Double(size.width) * Double(dir.x)) + abs(Double(size.height) * Double(dir.y))) / 2
        return (CGPoint(x: center.x - dir.x * CGFloat(half), y: center.y - dir.y * CGFloat(half)),
                CGPoint(x: center.x + dir.x * CGFloat(half), y: center.y + dir.y * CGFloat(half)))
    }
}
