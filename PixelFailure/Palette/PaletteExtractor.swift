import CoreGraphics
import Foundation

/// K-means color clustering over a downsampled image — extracts a palette
/// from a photo. Deterministic (seeded k-means++), sorted by cluster weight.
enum PaletteExtractor {
    static func extract(from cgImage: CGImage, colorCount: Int = 5) -> Palette? {
        guard let sampler = ImageSampler(cgImage: cgImage, maxDimension: 96) else { return nil }
        let points = sampler.allColors
        guard points.count >= colorCount else { return nil }

        var rng = SeededRNG(seed: 0xA11CE)
        let k = max(2, min(colorCount, 8))

        // k-means++ initialization.
        var centers: [RGBAColor] = [points[rng.int(0..<points.count)]]
        while centers.count < k {
            var bestCandidate = points[rng.int(0..<points.count)]
            var bestScore = -1.0
            // Sample a handful of candidates, keep the one farthest from existing centers.
            for _ in 0..<12 {
                let candidate = points[rng.int(0..<points.count)]
                let score = centers.map { distance($0, candidate) }.min() ?? 0
                if score > bestScore {
                    bestScore = score
                    bestCandidate = candidate
                }
            }
            centers.append(bestCandidate)
        }

        var assignments = [Int](repeating: 0, count: points.count)
        for _ in 0..<14 {
            // Assign.
            for (i, point) in points.enumerated() {
                var best = 0
                var bestDist = Double.greatestFiniteMagnitude
                for (c, center) in centers.enumerated() {
                    let d = distance(point, center)
                    if d < bestDist { bestDist = d; best = c }
                }
                assignments[i] = best
            }
            // Update.
            var sums = [(r: Double, g: Double, b: Double, n: Int)](repeating: (0, 0, 0, 0), count: k)
            for (i, point) in points.enumerated() {
                let c = assignments[i]
                sums[c].r += point.r
                sums[c].g += point.g
                sums[c].b += point.b
                sums[c].n += 1
            }
            for c in 0..<k where sums[c].n > 0 {
                let n = Double(sums[c].n)
                centers[c] = RGBAColor(r: sums[c].r / n, g: sums[c].g / n, b: sums[c].b / n)
            }
        }

        // Order clusters by size so the dominant colors come first.
        var counts = [Int](repeating: 0, count: k)
        for a in assignments { counts[a] += 1 }
        let ordered = zip(centers, counts)
            .sorted { $0.1 > $1.1 }
            .map(\.0)

        return Palette(name: "Extracted", colors: ordered)
    }

    private static func distance(_ a: RGBAColor, _ b: RGBAColor) -> Double {
        let dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
        return dr * dr * 0.3 + dg * dg * 0.59 + db * db * 0.11
    }
}
