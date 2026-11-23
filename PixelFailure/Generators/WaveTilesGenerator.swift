import CoreGraphics
import SwiftUI

/// Wave-function-collapse tiling. Each tile has a socket on every side (no
/// connection, thin trace, or thick trace); neighbors must agree, so the
/// traces always join up into continuous networks.
nonisolated struct WaveTilesGenerator: PatternGenerator {
    var displayName: String { "Wave Tiles" }

    /// Sockets: north, east, south, west.
    struct Tile { var sockets: [Int]; var weight: Double }

    var specs: [ParamSpec] {
        [
            .intSlider("columns", "Columns", min: 4, max: 48, initial: 16, randomizable: false),
            .choice("tileSet", "Tiles", options: ["Pipes", "Arcs", "Circuit"], initial: 1),
            .slider("density", "Density", min: 0.1, max: 0.95, initial: 0.6),
            .slider("straightness", "Straightness", min: 0, max: 1, initial: 0.4),
            .toggle("closedEdges", "Closed Edges", initial: true),
            .slider("lineWidth", "Line Width", min: 0.05, max: 0.6, initial: 0.22),
            .toggle("nodes", "Junction Dots", initial: true),
        ] + GenColor.specs
    }

    func generate(params: ParamValues, seed: UInt64, context: GeneratorContext) -> [VectorPrimitive] {
        var rng = SeededRNG(seed: seed)
        let size = context.size
        let columns = max(2, params.int("columns", 16))
        let cell = Double(size.width) / Double(columns)
        let rows = max(2, Int((Double(size.height) / cell).rounded(.up)))
        let tileSet = params.int("tileSet", 1)
        let density = params.double("density", 0.6)
        let straightness = params.double("straightness", 0.4)
        let closedEdges = params.bool("closedEdges", true)
        let width = max(0.3, params.double("lineWidth", 0.22) * cell)
        let showNodes = params.bool("nodes", true)

        // Tile catalogue: every socket combination, weighted by how many
        // connections it has (density) and whether it runs straight.
        let socketValues = tileSet == 2 ? [0, 1, 2] : [0, 1]
        var tiles: [Tile] = []
        for n in socketValues { for e in socketValues { for s in socketValues { for w in socketValues {
            let sockets = [n, e, s, w]
            let connections = sockets.filter { $0 > 0 }.count
            var weight = pow(density, Double(connections)) * pow(1 - density, Double(4 - connections))
            if connections == 2, (sockets[0] > 0) == (sockets[2] > 0) { weight *= 0.5 + straightness * 2 }
            if connections == 1 { weight *= 0.35 }
            // Junctions where thin meets thick are allowed (so the collapse
            // can always resolve) but kept rare.
            if Set(sockets.filter { $0 > 0 }).count > 1 { weight *= 0.08 }
            tiles.append(Tile(sockets: sockets, weight: max(weight, 1e-4)))
        } } } }

        guard let grid = Self.collapse(tiles: tiles, columns: columns, rows: rows,
                                       closedEdges: closedEdges, rng: &rng) else { return [] }

        var out: [VectorPrimitive] = []
        var thin = Path(), thick = Path(), dots = Path()
        for row in 0..<rows {
            for column in 0..<columns {
                let tile = tiles[grid[row * columns + column]]
                let origin = CGPoint(x: Double(column) * cell, y: Double(row) * cell)
                let c = CGPoint(x: origin.x + cell / 2, y: origin.y + cell / 2)
                let mids = [CGPoint(x: c.x, y: origin.y), CGPoint(x: origin.x + cell, y: c.y),
                            CGPoint(x: c.x, y: origin.y + cell), CGPoint(x: origin.x, y: c.y)]
                let connected = (0..<4).filter { tile.sockets[$0] > 0 }
                guard !connected.isEmpty else { continue }
                // Each side draws at its own socket's width.
                func target(_ side: Int) -> Bool { tile.sockets[side] == 2 }
                if tileSet == 1, connected.count == 2, (connected[1] - connected[0]) % 2 == 1 {
                    // Elbow: a quarter arc around the shared corner, which a
                    // quadratic through the tile center traces closely.
                    var arc = Path()
                    arc.move(to: mids[connected[0]])
                    arc.addQuadCurve(to: mids[connected[1]], control: c)
                    if target(connected[0]) { thick.addPath(arc) } else { thin.addPath(arc) }
                } else {
                    for side in connected {
                        var stub = Path()
                        stub.move(to: c)
                        stub.addLine(to: mids[side])
                        if target(side) { thick.addPath(stub) } else { thin.addPath(stub) }
                    }
                }
                if showNodes, connected.count != 2 {
                    dots.addPath(GenShape.circle(center: c, radius: width * (connected.count == 1 ? 1.1 : 0.9)))
                }
            }
        }
        let colorA = GenColor.pick(params, palette: context.palette, t: 0.2, rng: &rng)
        let colorB = GenColor.pick(params, palette: context.palette, t: 0.8, rng: &rng)
        if !thin.isEmpty { out.append(VectorPrimitive(path: thin, stroke: colorA, lineWidth: width)) }
        if !thick.isEmpty { out.append(VectorPrimitive(path: thick, stroke: colorB, lineWidth: width * 1.9)) }
        if !dots.isEmpty { out.append(VectorPrimitive(path: dots, fill: tileSet == 2 ? colorB : colorA)) }
        return out
    }

    /// Lowest-entropy-first collapse with constraint propagation. Restarts
    /// with the same RNG stream on contradiction, so output stays seeded.
    static func collapse(tiles: [Tile], columns: Int, rows: Int, closedEdges: Bool,
                                 rng: inout SeededRNG) -> [Int]? {
        let count = columns * rows
        let opposite = [2, 3, 0, 1]
        for _ in 0..<12 {
            var options = [[Bool]](repeating: [Bool](repeating: true, count: tiles.count), count: count)
            if closedEdges {
                for row in 0..<rows {
                    for column in 0..<columns {
                        let index = row * columns + column
                        for t in tiles.indices {
                            let s = tiles[t].sockets
                            if (row == 0 && s[0] > 0) || (column == columns - 1 && s[1] > 0)
                                || (row == rows - 1 && s[2] > 0) || (column == 0 && s[3] > 0) {
                                options[index][t] = false
                            }
                        }
                    }
                }
            }
            var result = [Int](repeating: -1, count: count)
            // Live option counts, so picking the most constrained cell is a
            // scan of integers rather than a recount of every cell's options.
            var remaining = options.map { $0.lazy.filter { $0 }.count }
            var failed = false
            for _ in 0..<count {
                // Pick the undecided cell with the fewest options.
                var best = -1, bestCount = Int.max
                for index in 0..<count where result[index] < 0 && remaining[index] < bestCount {
                    bestCount = remaining[index]; best = index
                }
                guard best >= 0 else { break }
                guard bestCount > 0 else { failed = true; break }
                let candidates = tiles.indices.filter { options[best][$0] }
                let total = candidates.reduce(0) { $0 + tiles[$1].weight }
                var pick = rng.unit() * total
                var chosen = candidates.last!
                for t in candidates { pick -= tiles[t].weight; if pick <= 0 { chosen = t; break } }
                result[best] = chosen
                options[best] = options[best].indices.map { $0 == chosen }
                remaining[best] = 1
                // Propagate to the four neighbors.
                let row = best / columns, column = best % columns
                let neighbors = [(row - 1, column), (row, column + 1), (row + 1, column), (row, column - 1)]
                for side in 0..<4 {
                    let (r, c) = neighbors[side]
                    guard r >= 0, r < rows, c >= 0, c < columns else { continue }
                    let n = r * columns + c
                    guard result[n] < 0 else { continue }
                    let socket = tiles[chosen].sockets[side]
                    for t in tiles.indices where options[n][t] && tiles[t].sockets[opposite[side]] != socket {
                        options[n][t] = false
                        remaining[n] -= 1
                    }
                }
            }
            if !failed { return result }
        }
        return nil
    }
}
