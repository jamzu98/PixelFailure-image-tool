import CoreGraphics
import SwiftUI

/// Settings shared by every generator, stored in the pattern's `params`
/// under reserved `stage.` keys (never a generator's own), so undo,
/// animation keyframes and presets cover them for free. Every default is "off": with all of them off the pipeline
/// returns the generator's output untouched, so older documents render
/// exactly as before.
nonisolated enum GenStages {
    enum Symmetry: Int, CaseIterable {
        case none, mirrorX, mirrorY, mirrorXY, radial, kaleidoscope

        var displayName: String {
            switch self {
            case .none: "None"
            case .mirrorX: "Mirror Horizontal"
            case .mirrorY: "Mirror Vertical"
            case .mirrorXY: "Mirror Both"
            case .radial: "Radial"
            case .kaleidoscope: "Kaleidoscope"
            }
        }

        var usesSegments: Bool { self == .radial || self == .kaleidoscope }
    }

    enum RegionMode: Int { case off, inside, outside }
    enum ColorSource: Int { case palette, image }

    static var symmetrySpecs: [ParamSpec] {
        [
            .choice("stage.symmetry", "Symmetry", options: Symmetry.allCases.map(\.displayName),
                    initial: 0, randomizable: false),
            .intSlider("stage.segments", "Segments", min: 2, max: 24, initial: 6, randomizable: false),
            .slider("stage.centerX", "Center X", min: 0, max: 1, initial: 0.5, randomizable: false),
            .slider("stage.centerY", "Center Y", min: 0, max: 1, initial: 0.5, randomizable: false),
        ]
    }

    static var repeatSpecs: [ParamSpec] {
        [
            .choice("stage.repeat", "Repeat", options: ["None", "2 × 2", "3 × 3", "4 × 4"],
                    initial: 0, randomizable: false),
            .toggle("stage.brick", "Brick Offset", initial: false, randomizable: false),
        ]
    }

    static var regionSpecs: [ParamSpec] {
        [.choice("stage.region", "Region", options: ["Off", "Inside Layer", "Outside Layer"],
                 initial: 0, randomizable: false)]
    }

    static var colorSpecs: [ParamSpec] {
        [.choice("stage.color", "Color Source", options: ["Palette", "Image"],
                 initial: 0, randomizable: false)]
    }

    static var allSpecs: [ParamSpec] { symmetrySpecs + repeatSpecs + regionSpecs + colorSpecs }
    static var keys: Set<String> { Set(allSpecs.map(\.key)) }

    static func symmetry(_ p: ParamValues) -> Symmetry { Symmetry(rawValue: p.int("stage.symmetry", 0)) ?? .none }
    static func repeatCount(_ p: ParamValues) -> Int { min(max(p.int("stage.repeat", 0) + 1, 1), 4) }
    static func regionMode(_ p: ParamValues) -> RegionMode { RegionMode(rawValue: p.int("stage.region", 0)) ?? .off }
    static func colorSource(_ p: ParamValues) -> ColorSource { ColorSource(rawValue: p.int("stage.color", 0)) ?? .palette }

    static func isActive(_ p: ParamValues) -> Bool {
        symmetry(p) != .none || repeatCount(p) > 1 || regionMode(p) != .off || colorSource(p) != .palette
    }
}

extension PatternConfig {
    /// Whether this pattern reads pixels from an image layer: the generator
    /// samples one, or its colors come from one.
    nonisolated var usesSourceImage: Bool {
        generator.generator.wantsSourceImage(params) || GenStages.colorSource(params) == .image
    }

    /// The one way to turn a pattern into primitives: the generator, then
    /// symmetry, repeat, the region clip and image colors.
    nonisolated func generate(context: GeneratorContext) -> [VectorPrimitive] {
        let base = generator.generator.generate(params: params, seed: seed, context: context)
        guard GenStages.isActive(params) else { return base }
        return GeneratorPipeline.apply(base, params: params, context: context)
    }
}

nonisolated enum GeneratorPipeline {
    static func apply(_ input: [VectorPrimitive], params: ParamValues,
                      context: GeneratorContext) -> [VectorPrimitive] {
        var out = input
        let size = context.size
        let symmetry = GenStages.symmetry(params)
        if symmetry != .none {
            let center = CGPoint(x: params.double("stage.centerX", 0.5) * size.width,
                                 y: params.double("stage.centerY", 0.5) * size.height)
            out = applySymmetry(out, mode: symmetry, segments: params.int("stage.segments", 6),
                                center: center, size: size)
        }
        let count = GenStages.repeatCount(params)
        if count > 1 {
            out = applyRepeat(out, count: count, brick: params.bool("stage.brick", false), size: size)
        }
        let region = GenStages.regionMode(params)
        if region != .off, let path = context.region {
            out = clip(out, to: path.cgPath, inside: region == .inside)
        }
        if GenStages.colorSource(params) == .image, let sampler = context.sampler {
            out = recolor(out, sampler: sampler, size: size)
        }
        return out
    }

    // MARK: Symmetry

    static func applySymmetry(_ input: [VectorPrimitive], mode: GenStages.Symmetry,
                              segments: Int, center: CGPoint, size: CGSize) -> [VectorPrimitive] {
        let reach = hypot(size.width, size.height) * 2
        func about(_ t: CGAffineTransform) -> CGAffineTransform {
            CGAffineTransform(translationX: -center.x, y: -center.y)
                .concatenating(t)
                .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        }
        func copies(of base: [VectorPrimitive], _ transforms: [CGAffineTransform]) -> [VectorPrimitive] {
            transforms.flatMap { t in base.map { $0.applying(t) } }
        }
        switch mode {
        case .none:
            return input
        case .mirrorX:
            let half = CGPath(rect: CGRect(x: center.x - reach, y: center.y - reach,
                                           width: reach, height: reach * 2), transform: nil)
            let base = clip(input, to: half, inside: true)
            return copies(of: base, [.identity, about(CGAffineTransform(scaleX: -1, y: 1))])
        case .mirrorY:
            let half = CGPath(rect: CGRect(x: center.x - reach, y: center.y - reach,
                                           width: reach * 2, height: reach), transform: nil)
            let base = clip(input, to: half, inside: true)
            return copies(of: base, [.identity, about(CGAffineTransform(scaleX: 1, y: -1))])
        case .mirrorXY:
            let quarter = CGPath(rect: CGRect(x: center.x - reach, y: center.y - reach,
                                              width: reach, height: reach), transform: nil)
            let base = clip(input, to: quarter, inside: true)
            return copies(of: base, [.identity,
                                     about(CGAffineTransform(scaleX: -1, y: 1)),
                                     about(CGAffineTransform(scaleX: 1, y: -1)),
                                     about(CGAffineTransform(scaleX: -1, y: -1))])
        case .radial:
            let n = max(2, segments)
            let wedge = wedgePath(center: center, angle: 2 * .pi / Double(n), reach: reach)
            let base = clip(input, to: wedge, inside: true)
            return copies(of: base, (0..<n).map { k in
                about(CGAffineTransform(rotationAngle: CGFloat(Double(k) * 2 * .pi / Double(n))))
            })
        case .kaleidoscope:
            // N mirror axes: a wedge of π/N, reflected across its edge and
            // rotated around the circle.
            let n = max(2, segments)
            let angle = Double.pi / Double(n)
            let wedge = wedgePath(center: center, angle: angle, reach: reach)
            let base = clip(input, to: wedge, inside: true)
            var transforms: [CGAffineTransform] = []
            for k in 0..<n {
                let rotation = CGAffineTransform(rotationAngle: CGFloat(2 * angle * Double(k)))
                transforms.append(about(rotation))
                transforms.append(about(CGAffineTransform(scaleX: 1, y: -1).concatenating(rotation)))
            }
            return copies(of: base, transforms)
        }
    }

    /// A pie slice from `center`, starting at angle 0 (pointing +x).
    static func wedgePath(center: CGPoint, angle: Double, reach: Double) -> CGPath {
        let path = CGMutablePath()
        path.move(to: center)
        let steps = max(2, Int(angle / (.pi / 16)) + 1)
        for i in 0...steps {
            let a = angle * Double(i) / Double(steps)
            path.addLine(to: CGPoint(x: center.x + cos(a) * reach, y: center.y + sin(a) * reach))
        }
        path.closeSubpath()
        return path
    }

    // MARK: Repeat

    static func applyRepeat(_ input: [VectorPrimitive], count: Int, brick: Bool,
                            size: CGSize) -> [VectorPrimitive] {
        let scale = 1 / CGFloat(count)
        let cell = CGSize(width: size.width * scale, height: size.height * scale)
        var out: [VectorPrimitive] = []
        out.reserveCapacity(input.count * count * (count + 1))
        for row in 0..<count {
            let shift: CGFloat = brick && row % 2 == 1 ? cell.width / 2 : 0
            let columns = shift > 0 ? Array(-1..<count) : Array(0..<count)
            for column in columns {
                let t = CGAffineTransform(scaleX: scale, y: scale)
                    .concatenating(CGAffineTransform(translationX: CGFloat(column) * cell.width + shift,
                                                     y: CGFloat(row) * cell.height))
                out += input.map { $0.applying(t, widthScale: Double(scale)) }
            }
        }
        return out
    }

    // MARK: Region clipping

    /// Keeps the parts of each primitive inside (or outside) `region`.
    /// Filled shapes clip as areas, strokes as lines, so the result stays
    /// vector in SVG exports.
    static func clip(_ input: [VectorPrimitive], to region: CGPath, inside: Bool) -> [VectorPrimitive] {
        let regionBounds = region.boundingBoxOfPath
        // Built lazily: many inputs never touch the region at all.
        var clipper: RegionClipper?
        return input.compactMap { primitive in
            let path = primitive.path.cgPath
            let outset = primitive.stroke != nil ? CGFloat(primitive.lineWidth) : 0
            let bounds = path.boundingBoxOfPath.insetBy(dx: -outset, dy: -outset)
            // Cheap rejects before any geometry work.
            if !bounds.intersects(regionBounds) { return inside ? nil : primitive }
            let clipped: CGPath
            if primitive.fill != nil {
                clipped = inside ? path.intersection(region, using: .winding)
                                 : path.subtracting(region, using: .winding)
            } else {
                // CGPath.lineIntersection occasionally emits a stray segment
                // to a far-away point, so strokes use our own clipper.
                if clipper == nil { clipper = RegionClipper(region: region) }
                clipped = clipper!.clip(path, keepInside: inside)
            }
            // Clipping can leave a lone move-to with no drawable extent.
            let clippedBounds = clipped.boundingBoxOfPath
            guard !clipped.isEmpty, !clippedBounds.isNull, !clippedBounds.isInfinite else { return nil }
            var result = primitive
            result.path = Path(clipped)
            return result
        }
    }

    // MARK: Image colors

    static func recolor(_ input: [VectorPrimitive], sampler: ImageSampler,
                        size: CGSize) -> [VectorPrimitive] {
        input.map { primitive in
            let box = primitive.path.boundingRect
            guard !box.isNull else { return primitive }
            let x = min(max(box.midX / max(size.width, 1), 0), 1)
            let y = min(max(box.midY / max(size.height, 1), 0), 1)
            let sampled = sampler.color(atUnitX: Double(x), y: Double(y))
            var result = primitive
            if let fill = primitive.fill { result.fill = sampled.withAlpha(fill.a) }
            if let stroke = primitive.stroke { result.stroke = sampled.withAlpha(stroke.a) }
            return result
        }
    }
}

extension VectorPrimitive {
    /// The same primitive moved by `transform`; stroke width scales by
    /// `widthScale` so repeated tiles keep their proportions.
    nonisolated func applying(_ transform: CGAffineTransform, widthScale: Double = 1) -> VectorPrimitive {
        var copy = self
        copy.path = path.applying(transform)
        copy.lineWidth = lineWidth * widthScale
        copy.dash = dash.map { $0 * CGFloat(widthScale) }
        return copy
    }
}

/// Clips open or closed polylines (curves are flattened) against an area,
/// keeping the parts inside or outside it under the nonzero winding rule.
/// Region edges sit in a uniform grid so each segment only tests nearby
/// edges, and containment is only evaluated where a segment crosses the
/// boundary: between crossings it cannot change.
nonisolated struct RegionClipper {
    private let region: CGPath
    private let bounds: CGRect
    private var edges: [(CGPoint, CGPoint)] = []
    private var cells: [Int: [Int]] = [:]
    private let columns: Int
    private let rows: Int
    private let cellSize: CGFloat

    init(region: CGPath) {
        self.region = region
        bounds = region.boundingBoxOfPath
        let longest = max(bounds.width, bounds.height, 1)
        cellSize = longest / 64
        columns = max(1, Int((bounds.width / cellSize).rounded(.up)))
        rows = max(1, Int((bounds.height / cellSize).rounded(.up)))
        for polyline in Self.flatten(region, closeSubpaths: true) {
            for k in 1..<max(polyline.count, 1) where polyline.count > 1 {
                edges.append((polyline[k - 1], polyline[k]))
            }
        }
        for (index, edge) in edges.enumerated() {
            forEachCell(touching: CGRect(x: min(edge.0.x, edge.1.x), y: min(edge.0.y, edge.1.y),
                                         width: abs(edge.1.x - edge.0.x), height: abs(edge.1.y - edge.0.y))) {
                cells[$0, default: []].append(index)
            }
        }
    }

    private func forEachCell(touching rect: CGRect, _ body: (Int) -> Void) {
        guard rect.insetBy(dx: -0.5, dy: -0.5).intersects(bounds) else { return }
        let c0 = max(0, min(columns - 1, Int((rect.minX - bounds.minX) / cellSize)))
        let c1 = max(0, min(columns - 1, Int((rect.maxX - bounds.minX) / cellSize)))
        let r0 = max(0, min(rows - 1, Int((rect.minY - bounds.minY) / cellSize)))
        let r1 = max(0, min(rows - 1, Int((rect.maxY - bounds.minY) / cellSize)))
        for r in r0...r1 { for c in c0...c1 { body(r * columns + c) } }
    }

    private func contains(_ p: CGPoint) -> Bool { region.contains(p, using: .winding) }

    /// Parameters in (0, 1) where segment a→b crosses a region edge.
    private func crossings(_ a: CGPoint, _ b: CGPoint) -> [CGFloat] {
        var seen = Set<Int>()
        var ts: [CGFloat] = []
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        forEachCell(touching: rect) { cell in
            for index in cells[cell] ?? [] where seen.insert(index).inserted {
                let (p, q) = edges[index]
                let r = CGPoint(x: b.x - a.x, y: b.y - a.y), s = CGPoint(x: q.x - p.x, y: q.y - p.y)
                let denom = r.x * s.y - r.y * s.x
                guard abs(denom) > 1e-12 else { continue }
                let w = CGPoint(x: p.x - a.x, y: p.y - a.y)
                let t = (w.x * s.y - w.y * s.x) / denom
                let u = (w.x * r.y - w.y * r.x) / denom
                if t > 0, t < 1, u >= 0, u <= 1 { ts.append(t) }
            }
        }
        return ts.sorted()
    }

    func clip(_ path: CGPath, keepInside: Bool) -> CGPath {
        let out = CGMutablePath()
        for polyline in Self.flatten(path, closeSubpaths: false) where polyline.count > 1 {
            var inside = contains(polyline[0])
            var drawing = false
            func emit(_ from: CGPoint, _ to: CGPoint, keep: Bool) {
                if keep {
                    if !drawing { out.move(to: from); drawing = true }
                    out.addLine(to: to)
                } else {
                    drawing = false
                }
            }
            for k in 1..<polyline.count {
                let a = polyline[k - 1], b = polyline[k]
                let ts = crossings(a, b)
                if ts.isEmpty {
                    emit(a, b, keep: inside == keepInside)
                    continue
                }
                var start = a
                var previous: CGFloat = 0
                for t in ts + [1] where t - previous > 1e-9 {
                    let end = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                    let midT = (previous + t) / 2
                    inside = contains(CGPoint(x: a.x + (b.x - a.x) * midT, y: a.y + (b.y - a.y) * midT))
                    emit(start, end, keep: inside == keepInside)
                    start = end
                    previous = t
                }
            }
        }
        return out
    }

    /// Every subpath as a polyline; curves become short line runs.
    static func flatten(_ path: CGPath, closeSubpaths: Bool) -> [[CGPoint]] {
        var result: [[CGPoint]] = []
        var current: [CGPoint] = []
        var start = CGPoint.zero
        func finish(closing: Bool) {
            if closing, let first = current.first, current.last != first { current.append(first) }
            if current.count > 1 { result.append(current) }
            current = []
        }
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let points = element.points
            switch element.type {
            case .moveToPoint:
                finish(closing: closeSubpaths)
                start = points[0]
                current = [start]
            case .addLineToPoint:
                current.append(points[0])
            case .addQuadCurveToPoint:
                let p0 = current.last ?? start, c = points[0], p1 = points[1]
                let steps = max(4, min(32, Int(hypot(p1.x - p0.x, p1.y - p0.y) / 4)))
                for i in 1...steps {
                    let t = CGFloat(i) / CGFloat(steps), u = 1 - t
                    current.append(CGPoint(x: u * u * p0.x + 2 * u * t * c.x + t * t * p1.x,
                                           y: u * u * p0.y + 2 * u * t * c.y + t * t * p1.y))
                }
            case .addCurveToPoint:
                let p0 = current.last ?? start, c1 = points[0], c2 = points[1], p1 = points[2]
                let steps = max(6, min(48, Int(hypot(p1.x - p0.x, p1.y - p0.y) / 4)))
                for i in 1...steps {
                    let t = CGFloat(i) / CGFloat(steps), u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    current.append(CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p1.x,
                                           y: a * p0.y + b * c1.y + c * c2.y + d * p1.y))
                }
            case .closeSubpath:
                if let first = current.first { current.append(first) }
                finish(closing: false)
                current = []
            @unknown default:
                break
            }
        }
        finish(closing: closeSubpaths)
        return result
    }
}
