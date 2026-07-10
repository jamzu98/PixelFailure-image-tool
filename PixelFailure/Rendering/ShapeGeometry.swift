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

nonisolated enum PathGeometry {
    static func path(for config: PathConfig) -> Path {
        var path = Path()
        if let commands = config.commands {
            for command in commands {
                switch command {
                case .move(let point): path.move(to: point)
                case .line(let point): path.addLine(to: point)
                case .quad(let control, let point): path.addQuadCurve(to: point, control: control)
                case .cubic(let c1, let c2, let point): path.addCurve(to: point, control1: c1, control2: c2)
                case .close: path.closeSubpath()
                }
            }
            return path
        }
        guard let first = config.nodes.first else { return path }
        path.move(to: first.anchor)
        for index in 1..<config.nodes.count {
            let previous = config.nodes[index - 1]
            let current = config.nodes[index]
            path.addCurve(to: current.anchor,
                          control1: previous.outControl,
                          control2: current.inControl)
        }
        if config.isClosed, let last = config.nodes.last {
            path.addCurve(to: first.anchor, control1: last.outControl, control2: first.inControl)
            path.closeSubpath()
        }
        return path
    }

    static func primitives(for config: PathConfig) -> [VectorPrimitive] {
        [VectorPrimitive(path: path(for: config), fill: config.fill,
                         stroke: config.stroke, lineWidth: config.strokeWidth,
                         lineCap: .round, lineJoin: .round)]
    }

    static func commands(from path: CGPath) -> [PathCommand] {
        var commands: [PathCommand] = []
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint: commands.append(.move(element.points[0]))
            case .addLineToPoint: commands.append(.line(element.points[0]))
            case .addQuadCurveToPoint: commands.append(.quad(element.points[0], element.points[1]))
            case .addCurveToPoint: commands.append(.cubic(element.points[0], element.points[1], element.points[2]))
            case .closeSubpath: commands.append(.close)
            @unknown default: break
            }
        }
        return commands
    }
}
