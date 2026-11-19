import SwiftUI

/// Marching ants for the active selection, plus live previews of in-flight
/// marquee/lasso gestures. Purely visual — never intercepts events.
struct SelectionAntsView: View {
    @Bindable var editorState: EditorState
    let canvasTransform: CGAffineTransform
    /// Canvas-units-per-view-point, to keep dash geometry screen-constant.
    let scale: CGFloat
    /// Current pointer position (canvas space) for the polygonal lasso preview.
    let hoverCanvasPoint: CGPoint

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0,
                                paused: !Preferences.shared.animatesSelectionEdges
                                    || editorState.selection == nil
                                    && editorState.selectionDraft == nil
                                    && editorState.lassoVertices == nil)) { context in
            let phase = CGFloat(context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1)) * 12
            Canvas { ctx, _ in
                ctx.concatenate(canvasTransform)
                let dash: CGFloat = 5 / scale
                let width: CGFloat = 1 / scale

                func ants(_ path: Path) {
                    ctx.stroke(path, with: .color(.black.opacity(0.85)),
                               style: StrokeStyle(lineWidth: width, dash: [dash, dash],
                                                  dashPhase: phase / scale))
                    ctx.stroke(path, with: .color(.white),
                               style: StrokeStyle(lineWidth: width, dash: [dash, dash],
                                                  dashPhase: (phase + 5) / scale))
                }

                if let selection = editorState.selection {
                    ants(selection.path)
                }
                if let draft = editorState.selectionDraft {
                    ants(draft)
                }
                if let vertices = editorState.lassoVertices, let first = vertices.first {
                    var preview = Path()
                    preview.move(to: first)
                    for point in vertices.dropFirst() {
                        preview.addLine(to: point)
                    }
                    preview.addLine(to: hoverCanvasPoint)
                    ants(preview)
                    // Close-target marker on the first vertex.
                    let radius = 4 / scale
                    ctx.stroke(Path(ellipseIn: CGRect(x: first.x - radius, y: first.y - radius,
                                                      width: radius * 2, height: radius * 2)),
                               with: .color(.white), lineWidth: width)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
