import SwiftUI

/// Interactive crop rectangle: drag corners/edges to size, drag inside to
/// move, with a dimmed surround and an Apply/Cancel HUD. The draft lives in
/// EditorState (canvas coordinates); the viewport owns apply/cancel logic.
struct CropOverlay: View {
    @ObservedObject var document: PixelDocument
    @Bindable var editorState: EditorState
    let renderStore: RenderStore
    let canvasTransform: CGAffineTransform
    let onApply: () -> Void
    let onCancel: () -> Void

    @State private var dragStartRect: CGRect?

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var unit: CGPoint {
            switch self {
            case .topLeft: CGPoint(x: 0, y: 0)
            case .top: CGPoint(x: 0.5, y: 0)
            case .topRight: CGPoint(x: 1, y: 0)
            case .right: CGPoint(x: 1, y: 0.5)
            case .bottomRight: CGPoint(x: 1, y: 1)
            case .bottom: CGPoint(x: 0.5, y: 1)
            case .bottomLeft: CGPoint(x: 0, y: 1)
            case .left: CGPoint(x: 0, y: 0.5)
            }
        }
    }

    var body: some View {
        let draft = editorState.cropDraft ?? initialDraft()
        let viewRect = draft.applying(canvasTransform)

        ZStack {
            // Dim everything outside the crop rect.
            DimOutside(rect: viewRect)
                .allowsHitTesting(false)

            // Border + thirds guides.
            Path { path in
                path.addRect(viewRect)
                for i in 1...2 {
                    let x = viewRect.minX + viewRect.width * CGFloat(i) / 3
                    let y = viewRect.minY + viewRect.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: viewRect.minY))
                    path.addLine(to: CGPoint(x: x, y: viewRect.maxY))
                    path.move(to: CGPoint(x: viewRect.minX, y: y))
                    path.addLine(to: CGPoint(x: viewRect.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.85), lineWidth: 1)
            .allowsHitTesting(false)

            // Interior drag: move the rect.
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: max(viewRect.width, 1), height: max(viewRect.height, 1))
                .position(x: viewRect.midX, y: viewRect.midY)
                .gesture(moveGesture(draft: draft))

            // Handles.
            ForEach(Array(Handle.allCases.enumerated()), id: \.offset) { _, handle in
                let point = CGPoint(x: viewRect.minX + viewRect.width * handle.unit.x,
                                    y: viewRect.minY + viewRect.height * handle.unit.y)
                Rectangle()
                    .fill(Color.white)
                    .stroke(Color.black.opacity(0.5), lineWidth: 1)
                    .frame(width: 9, height: 9)
                    .position(point)
                    .gesture(handleGesture(handle, draft: draft))
            }

            // HUD.
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Text("\(Int(draft.width)) × \(Int(draft.height))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("Cancel", action: onCancel)
                    Button("Apply", action: onApply)
                        .buttonStyle(.borderedProminent)
                }
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(.bottom, 48)
            }
            .allowsHitTesting(true)
        }
        .coordinateSpace(name: "crop-overlay")
        .onAppear {
            if editorState.cropDraft == nil {
                editorState.cropDraft = initialDraft()
            }
        }
    }

    /// Start from the target layer's bounds, or the full canvas.
    private func initialDraft() -> CGRect {
        if let layer = document.model.layer(id: editorState.selectedLayerID),
           layer.kind.isImage,
           abs(layer.transform.rotationDegrees).truncatingRemainder(dividingBy: 360) < 0.01 {
            let naturalSize = renderStore.naturalSize(for: layer, model: document.model)
            let scale = layer.transform.scale
            return CGRect(x: layer.transform.position.x - naturalSize.width * scale / 2,
                          y: layer.transform.position.y - naturalSize.height * scale / 2,
                          width: naturalSize.width * scale,
                          height: naturalSize.height * scale)
        }
        return CGRect(origin: .zero, size: document.model.canvasSize)
    }

    private func moveGesture(draft: CGRect) -> some Gesture {
        DragGesture(coordinateSpace: .named("crop-overlay"))
            .onChanged { value in
                if dragStartRect == nil { dragStartRect = draft }
                guard let start = dragStartRect else { return }
                let scale = canvasScale
                editorState.cropDraft = start.offsetBy(dx: value.translation.width / scale,
                                                       dy: value.translation.height / scale)
            }
            .onEnded { _ in dragStartRect = nil }
    }

    private func handleGesture(_ handle: Handle, draft: CGRect) -> some Gesture {
        DragGesture(coordinateSpace: .named("crop-overlay"))
            .onChanged { value in
                if dragStartRect == nil { dragStartRect = draft }
                guard let start = dragStartRect else { return }
                let scale = canvasScale
                let dx = value.translation.width / scale
                let dy = value.translation.height / scale

                var rect = start
                let unit = handle.unit
                if unit.x == 0 {
                    rect.origin.x = min(start.minX + dx, start.maxX - 8)
                    rect.size.width = start.maxX - rect.origin.x
                } else if unit.x == 1 {
                    rect.size.width = max(8, start.width + dx)
                }
                if unit.y == 0 {
                    rect.origin.y = min(start.minY + dy, start.maxY - 8)
                    rect.size.height = start.maxY - rect.origin.y
                } else if unit.y == 1 {
                    rect.size.height = max(8, start.height + dy)
                }
                editorState.cropDraft = rect
            }
            .onEnded { _ in dragStartRect = nil }
    }

    private var canvasScale: CGFloat {
        // Uniform scale: a is cos*scale but the viewport never rotates.
        max(canvasTransform.a, 0.0001)
    }
}

/// Four rectangles dimming everything outside `rect`.
private struct DimOutside: View {
    let rect: CGRect

    var body: some View {
        GeometryReader { geo in
            let full = CGRect(origin: .zero, size: geo.size)
            Path { path in
                path.addRect(full)
                path.addRect(rect.intersection(full))
            }
            .fill(Color.black.opacity(0.45), style: SwiftUI.FillStyle(eoFill: true))
        }
    }
}
