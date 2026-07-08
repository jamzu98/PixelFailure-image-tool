import SwiftUI

/// One drawable vector element. Pattern generators and the text outliner emit
/// these; the viewport renderer, PNG exporter, and SVG writer all consume them.
nonisolated struct VectorPrimitive: Sendable {
    var path: Path
    var fill: RGBAColor?
    var stroke: RGBAColor?
    var lineWidth: Double
    var lineCap: CGLineCap
    var lineJoin: CGLineJoin
    var dash: [CGFloat]

    init(path: Path,
         fill: RGBAColor? = nil,
         stroke: RGBAColor? = nil,
         lineWidth: Double = 1,
         lineCap: CGLineCap = .round,
         lineJoin: CGLineJoin = .round,
         dash: [CGFloat] = []) {
        self.path = path
        self.fill = fill
        self.stroke = stroke
        self.lineWidth = lineWidth
        self.lineCap = lineCap
        self.lineJoin = lineJoin
        self.dash = dash
    }

    var strokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: CGFloat(lineWidth), lineCap: lineCap, lineJoin: lineJoin, dash: dash)
    }
}
