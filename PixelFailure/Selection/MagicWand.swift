import CoreGraphics
import CoreImage
import SwiftUI

/// Magic wand: flood-fills the composited artwork from a seed point by color
/// similarity, then traces the region's boundary into a vector path so the
/// result behaves exactly like a marquee/lasso selection.
@MainActor
enum MagicWand {
    /// `tolerance` 0...1. Returns a canvas-space path, or nil for a miss.
    static func select(at canvasPoint: CGPoint,
                       tolerance: Double,
                       composite: CGImage,
                       canvasSize: CGSize) -> Path? {
        guard let sampler = ImageSampler(cgImage: composite, maxDimension: max(composite.width, composite.height))
        else { return nil }

        let width = sampler.width
        let height = sampler.height
        let sx = Int((canvasPoint.x / canvasSize.width * CGFloat(width)).rounded(.down))
        let sy = Int((canvasPoint.y / canvasSize.height * CGFloat(height)).rounded(.down))
        guard (0..<width).contains(sx), (0..<height).contains(sy) else { return nil }

        let pixels = sampler.pixels
        func channels(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let i = (y * width + x) * 4
            return (Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
        }
        let seed = channels(sx, sy)
        // Weighted RGB distance, normalized so tolerance 1 spans the gamut.
        let maxDistance = tolerance * tolerance * (255.0 * 255.0)
        func matches(_ x: Int, _ y: Int) -> Bool {
            let c = channels(x, y)
            let dr = c.0 - seed.0, dg = c.1 - seed.1, db = c.2 - seed.2
            return dr * dr * 0.3 + dg * dg * 0.59 + db * db * 0.11 <= maxDistance
        }

        // BFS flood fill (4-connected).
        var region = [Bool](repeating: false, count: width * height)
        var queue = [sy * width + sx]
        region[sy * width + sx] = true
        var head = 0
        while head < queue.count {
            let index = queue[head]
            head += 1
            let x = index % width
            let y = index / width
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                guard (0..<width).contains(nx), (0..<height).contains(ny) else { continue }
                let ni = ny * width + nx
                guard !region[ni], matches(nx, ny) else { continue }
                region[ni] = true
                queue.append(ni)
            }
        }

        let scale = CGPoint(x: canvasSize.width / CGFloat(width),
                            y: canvasSize.height / CGFloat(height))
        return ContourTracer.trace(grid: region, width: width, height: height, scale: scale)
    }
}

/// Traces the boundary of a boolean pixel grid into closed polygons
/// (outer contours and holes; even-odd fill renders them correctly).
nonisolated enum ContourTracer {
    /// Directed boundary edge of one selected cell, oriented so chaining
    /// produces closed loops. Points are grid-corner coordinates.
    private struct Edge: Hashable {
        var from: Int  // corner index: y * (width + 1) + x
        var to: Int
    }

    static func trace(grid: [Bool], width: Int, height: Int, scale: CGPoint) -> Path? {
        guard grid.contains(true) else { return nil }
        let cw = width + 1
        func corner(_ x: Int, _ y: Int) -> Int { y * cw + x }

        // Every cell side facing an unselected neighbor becomes a directed
        // edge (clockwise around selected area in a y-down grid).
        var nextByStart: [Int: Int] = [:]
        nextByStart.reserveCapacity(width * height / 4)
        func cell(_ x: Int, _ y: Int) -> Bool {
            guard (0..<width).contains(x), (0..<height).contains(y) else { return false }
            return grid[y * width + x]
        }
        for y in 0..<height {
            for x in 0..<width where cell(x, y) {
                if !cell(x, y - 1) { nextByStart[corner(x, y)] = corner(x + 1, y) }          // top → right
                if !cell(x + 1, y) { nextByStart[corner(x + 1, y)] = corner(x + 1, y + 1) }  // right → down
                if !cell(x, y + 1) { nextByStart[corner(x + 1, y + 1)] = corner(x, y + 1) }  // bottom → left
                if !cell(x - 1, y) { nextByStart[corner(x, y + 1)] = corner(x, y) }          // left → up
            }
        }

        var path = Path()
        var visited = Set<Int>()
        for start in nextByStart.keys {
            guard !visited.contains(start) else { continue }
            var loop: [Int] = []
            var current = start
            while !visited.contains(current), let next = nextByStart[current] {
                visited.insert(current)
                loop.append(current)
                current = next
            }
            guard loop.count >= 4 else { continue }

            // Merge collinear runs (all edges are axis-aligned unit steps).
            var points: [CGPoint] = []
            for cornerIndex in loop {
                let point = CGPoint(x: CGFloat(cornerIndex % cw) * scale.x,
                                    y: CGFloat(cornerIndex / cw) * scale.y)
                if points.count >= 2 {
                    let a = points[points.count - 2]
                    let b = points[points.count - 1]
                    if (a.x == b.x && b.x == point.x) || (a.y == b.y && b.y == point.y) {
                        points[points.count - 1] = point
                        continue
                    }
                }
                points.append(point)
            }
            path.move(to: points[0])
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            path.closeSubpath()
        }
        return path.isEmpty ? nil : path
    }

    /// Threshold a grayscale image back into a boolean grid (used by
    /// expand/contract, which round-trip through Core Image morphology).
    static func grid(from image: CGImage) -> (grid: [Bool], width: Int, height: Int)? {
        guard let sampler = ImageSampler(cgImage: image, maxDimension: max(image.width, image.height))
        else { return nil }
        var grid = [Bool](repeating: false, count: sampler.width * sampler.height)
        for i in 0..<(sampler.width * sampler.height) {
            let p = i * 4
            let luminance = 0.2126 * Double(sampler.pixels[p]) + 0.7152 * Double(sampler.pixels[p + 1])
                + 0.0722 * Double(sampler.pixels[p + 2])
            grid[i] = luminance >= 128
        }
        return (grid, sampler.width, sampler.height)
    }
}
