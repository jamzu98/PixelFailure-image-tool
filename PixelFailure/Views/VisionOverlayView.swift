import SwiftUI

/// Smart-selection feedback in the status bar: busy spinner with cancel,
/// model download progress, and transient messages.
struct VisionStatusView: View {
    let vision: VisionSelectionController

    var body: some View {
        HStack(spacing: 6) {
            if let label = vision.busyLabel {
                BarDivider()
                ProgressView().controlSize(.mini)
                Text(label)
                Button { vision.cancelWork() } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(size: 16))
                    .help("Cancel")
            }
            if let progress = vision.downloadProgress {
                BarDivider()
                Text("Downloading model")
                ProgressView(value: progress).frame(width: 70).controlSize(.mini)
            }
            if let message = vision.statusMessage {
                BarDivider()
                Text(message).foregroundStyle(Theme.warning)
            }
        }
    }
}

/// On-canvas tint for the Object Select hover target and pending candidate.
/// Purely visual; drawn under the marching ants.
struct VisionOverlayView: View {
    let vision: VisionSelectionController
    let canvasTransform: CGAffineTransform
    let canvasSize: CGSize
    /// View points per canvas unit (keeps point markers screen-constant).
    let scale: CGFloat

    var body: some View {
        let accent = Theme.accent
        let candidate = vision.candidate
        let hover = vision.hover
        let canvasTransform = canvasTransform, canvasSize = canvasSize, scale = scale
        return Canvas { ctx, _ in
            ctx.concatenate(canvasTransform)
            let rect = CGRect(origin: .zero, size: canvasSize)
            func draw(_ tint: VisionSelectionController.Tint, opacity: Double) {
                if let image = tint.image {
                    ctx.draw(Image(decorative: image, scale: 1), in: rect)
                } else if let path = tint.path {
                    ctx.fill(path, with: .color(accent.opacity(opacity)), style: SwiftUI.FillStyle(eoFill: true))
                }
            }
            if let candidate {
                draw(candidate.tint, opacity: 0.4)
                // Refinement points: filled = include, ring = exclude.
                let radius = 5 / max(scale, 0.0001)
                for (point, include) in candidate.points {
                    let dot = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                     width: radius * 2, height: radius * 2))
                    ctx.fill(dot, with: .color(include ? accent : .white))
                    ctx.stroke(dot, with: .color(include ? .white : .black), lineWidth: radius * 0.35)
                }
            } else if let hover {
                draw(hover, opacity: 0.3)
            }
        }
        .allowsHitTesting(false)
    }
}
