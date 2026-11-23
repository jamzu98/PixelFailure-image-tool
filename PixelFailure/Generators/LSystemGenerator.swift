import CoreGraphics
import SwiftUI

/// Lindenmayer systems drawn with turtle graphics and fitted to the canvas.
/// Branch depth drives line width (taper) and color.
nonisolated struct LSystemGenerator: PatternGenerator {
    var displayName: String { "L-System" }

    private struct System {
        var axiom: String
        var rules: [Character: String]
        var angle: Double
        var startHeading: Double
        var maxIterations: Int
    }

    private static let systems: [System] = [
        // Fractal plant
        System(axiom: "X", rules: ["X": "F+[[X]-X]-F[-FX]+X", "F": "FF"], angle: 25, startHeading: -90, maxIterations: 7),
        // Binary tree
        System(axiom: "X", rules: ["X": "F[+X][-X]FX", "F": "FF"], angle: 25.7, startHeading: -90, maxIterations: 7),
        // Dragon curve
        System(axiom: "FX", rules: ["X": "X+YF+", "Y": "-FX-Y"], angle: 90, startHeading: 0, maxIterations: 15),
        // Koch snowflake
        System(axiom: "F++F++F", rules: ["F": "F-F++F-F"], angle: 60, startHeading: 0, maxIterations: 6),
        // Sierpinski arrowhead
        System(axiom: "A", rules: ["A": "B-A-B", "B": "A+B+A"], angle: 60, startHeading: 0, maxIterations: 9),
        // Bush
        System(axiom: "F", rules: ["F": "FF+[+F-F-F]-[-F+F+F]"], angle: 22.5, startHeading: -90, maxIterations: 5),
    ]

    var specs: [ParamSpec] {
        [
            .choice("system", "System", options: ["Plant", "Tree", "Dragon", "Snowflake", "Sierpinski", "Bush"], initial: 0),
            .intSlider("iterations", "Iterations", min: 1, max: 15, initial: 5),
            .slider("angleOffset", "Angle", min: -20, max: 20, initial: 0),
            .slider("angleJitter", "Angle Jitter", min: 0, max: 15, initial: 0),
            .slider("lengthJitter", "Length Jitter", min: 0, max: 0.5, initial: 0),
            .slider("lineWidth", "Line Width", min: 0.0003, max: 0.01, initial: 0.002),
            .slider("taper", "Taper", min: 0, max: 1, initial: 0.6),
            .slider("margin", "Margin", min: 0, max: 0.25, initial: 0.06),
        ] + GenColor.specs
    }

    func generate(params: ParamValues, seed: UInt64, context: GeneratorContext) -> [VectorPrimitive] {
        var rng = SeededRNG(seed: seed)
        let systemIndex = min(max(params.int("system", 0), 0), Self.systems.count - 1)
        let system = Self.systems[systemIndex]
        let iterations = min(params.int("iterations", 5), system.maxIterations)
        let angle = (system.angle + params.double("angleOffset", 0)) * .pi / 180
        let angleJitter = params.double("angleJitter", 0) * .pi / 180
        let lengthJitter = params.double("lengthJitter", 0)
        let taper = params.double("taper", 0.6)
        let margin = params.double("margin", 0.06) * context.minDimension

        // Expand, stopping before the string explodes.
        var string = Array(system.axiom)
        for _ in 0..<iterations {
            var next: [Character] = []
            next.reserveCapacity(string.count * 4)
            for c in string { if let r = system.rules[c] { next.append(contentsOf: r) } else { next.append(c) } }
            if next.count > 400_000 { break }
            string = next
        }

        // Turtle walk in unit steps, collecting segments with their depth.
        struct State { var x: Double; var y: Double; var heading: Double; var depth: Int }
        // The rules are fixed; the seed mirrors and leans upright systems and
        // turns the others by a multiple of their own angle.
        let upright = system.startHeading == -90
        let mirror: Double = upright && rng.chance(0.5) ? -1 : 1
        // Upright systems also lean a little, so every seed reads differently.
        let startTurn = upright ? rng.jitter(10) * .pi / 180 : Double(rng.int(0..<12)) * angle
        var state = State(x: 0, y: 0, heading: system.startHeading * .pi / 180 + startTurn, depth: 0)
        var stack: [State] = []
        var segments: [(CGPoint, CGPoint, Int)] = []
        var maxDepth = 0
        for c in string {
            switch c {
            case "F", "A", "B", "G":
                let length = 1 + rng.jitter(lengthJitter)
                let nx = state.x + cos(state.heading) * length
                let ny = state.y + sin(state.heading) * length
                segments.append((CGPoint(x: state.x, y: state.y), CGPoint(x: nx, y: ny), state.depth))
                state.x = nx; state.y = ny
            case "+": state.heading += mirror * (angle + rng.jitter(angleJitter))
            case "-": state.heading -= mirror * (angle + rng.jitter(angleJitter))
            case "[":
                stack.append(state)
                state.depth += 1
                maxDepth = max(maxDepth, state.depth)
            case "]":
                if let s = stack.popLast() { state = s }
            default: break
            }
        }
        guard !segments.isEmpty else { return [] }

        // Fit to the canvas.
        var bounds = CGRect.null
        for s in segments { bounds = bounds.union(CGRect(origin: s.0, size: .zero)).union(CGRect(origin: s.1, size: .zero)) }
        let area = CGRect(origin: .zero, size: context.size).insetBy(dx: margin, dy: margin)
        let scale = min(area.width / max(bounds.width, 1e-6), area.height / max(bounds.height, 1e-6))
        let offset = CGPoint(x: area.midX - bounds.midX * scale, y: area.midY - bounds.midY * scale)
        func map(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y) }

        // One primitive per depth so taper and color step with branching.
        let baseWidth = max(0.25, params.double("lineWidth", 0.002) * context.minDimension)
        var byDepth = [Path](repeating: Path(), count: maxDepth + 1)
        var lastEnd = [CGPoint?](repeating: nil, count: maxDepth + 1)
        for (a, b, depth) in segments {
            let pa = map(a), pb = map(b)
            if lastEnd[depth] != pa { byDepth[depth].move(to: pa) }
            byDepth[depth].addLine(to: pb)
            lastEnd[depth] = pb
        }
        var out: [VectorPrimitive] = []
        for depth in 0...maxDepth where !byDepth[depth].isEmpty {
            let t = maxDepth == 0 ? 0.5 : Double(depth) / Double(maxDepth)
            let width = baseWidth * (1 - taper * t * 0.85)
            let color = GenColor.pick(params, palette: context.palette, t: t, rng: &rng)
            out.append(VectorPrimitive(path: byDepth[depth], stroke: color, lineWidth: max(0.25, width)))
        }
        return out
    }
}
