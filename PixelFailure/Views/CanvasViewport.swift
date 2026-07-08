import SwiftUI

/// The central canvas: renders the composition, and handles selection,
/// move/scale/rotate, panning, and zooming.
struct CanvasViewport: View {
    @ObservedObject var document: PixelDocument
    @Bindable var editorState: EditorState
    let renderStore: RenderStore
    @Environment(\.undoManager) private var undoManager

    /// nil = fit to window.
    @State private var zoomLevel: CGFloat?
    @State private var pan: CGSize = .zero
    @State private var magnifyStartZoom: CGFloat?
    @State private var dragMode: DragMode?
    @FocusState private var isFocused: Bool

    private enum DragMode {
        case pan(startPan: CGSize)
        case move(layerID: UUID, startPosition: CGPoint)
        case scale(layerID: UUID, startScale: Double, startDistance: CGFloat)
        case rotate(layerID: UUID, startRotation: Double, startAngle: Double)
    }

    var body: some View {
        GeometryReader { geo in
            let viewSize = geo.size
            let scale = effectiveZoom(viewSize: viewSize)
            let canvasTransform = self.canvasTransform(viewSize: viewSize, scale: scale)
            let items = renderStore.renderItems(model: document.model, quality: .preview)

            ZStack {
                Color(nsColor: .underPageBackgroundColor)

                Canvas { context, _ in
                    context.concatenate(canvasTransform)
                    CanvasRenderer.draw(items: items,
                                        background: document.model.background,
                                        canvasSize: document.model.canvasSize,
                                        in: context)
                }
                .allowsHitTesting(false)

                if let layer = document.model.layer(id: editorState.selectedLayerID) {
                    SelectionOverlay(layer: layer,
                                     naturalSize: renderStore.naturalSize(for: layer, model: document.model),
                                     canvasTransform: canvasTransform,
                                     onScaleDrag: { phase in handleScaleDrag(phase, layer: layer, canvasTransform: canvasTransform) },
                                     onRotateDrag: { phase in handleRotateDrag(phase, layer: layer, canvasTransform: canvasTransform) })
                }

                zoomControls(scale: scale)
            }
            .contentShape(Rectangle())
            .gesture(mainDragGesture(canvasTransform: canvasTransform, scale: scale))
            .simultaneousGesture(magnifyGesture(scale: scale))
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: .down) { press in
                nudgeSelection(press)
            }
            .onKeyPress(.delete) {
                guard let id = editorState.selectedLayerID else { return .ignored }
                document.deleteLayer(id: id, undoManager: undoManager)
                editorState.selectedLayerID = nil
                return .handled
            }
            .onTapGesture {
                isFocused = true
            }
        }
        .clipped()
    }

    // MARK: - Transform math

    private func effectiveZoom(viewSize: CGSize) -> CGFloat {
        if let zoomLevel { return zoomLevel }
        let canvas = document.model.canvasSize
        guard canvas.width > 0, canvas.height > 0, viewSize.width > 40, viewSize.height > 40 else { return 0.1 }
        return min((viewSize.width - 48) / canvas.width, (viewSize.height - 48) / canvas.height)
    }

    private func canvasTransform(viewSize: CGSize, scale: CGFloat) -> CGAffineTransform {
        let canvas = document.model.canvasSize
        let tx = (viewSize.width - canvas.width * scale) / 2 + pan.width
        let ty = (viewSize.height - canvas.height * scale) / 2 + pan.height
        return CGAffineTransform(translationX: tx, y: ty).scaledBy(x: scale, y: scale)
    }

    // MARK: - Gestures

    private func mainDragGesture(canvasTransform: CGAffineTransform, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragMode == nil {
                    isFocused = true
                    let canvasPoint = value.startLocation.applying(canvasTransform.inverted())
                    if let hit = hitTest(canvasPoint) {
                        editorState.selectedLayerID = hit.id
                        document.beginGesture()
                        dragMode = .move(layerID: hit.id, startPosition: hit.transform.position)
                    } else {
                        dragMode = .pan(startPan: pan)
                    }
                }
                switch dragMode {
                case .pan(let startPan):
                    pan = CGSize(width: startPan.width + value.translation.width,
                                 height: startPan.height + value.translation.height)
                case .move(let layerID, let startPosition):
                    var newPosition = CGPoint(x: startPosition.x + value.translation.width / scale,
                                              y: startPosition.y + value.translation.height / scale)
                    newPosition = snapped(newPosition, tolerance: 8 / scale)
                    document.updateDuringGesture { model in
                        model.modifyLayer(id: layerID) { $0.transform.position = newPosition }
                    }
                default:
                    break
                }
            }
            .onEnded { value in
                switch dragMode {
                case .move:
                    document.endGesture(undoManager, actionName: "Move Layer")
                case .pan, .none:
                    // A drag that never moved far acts as a click-select.
                    if value.translation.width.magnitude < 3, value.translation.height.magnitude < 3 {
                        selectAt(value.location.applying(canvasTransform.inverted()))
                    }
                default:
                    break
                }
                dragMode = nil
            }
    }

    private func magnifyGesture(scale: CGFloat) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if magnifyStartZoom == nil { magnifyStartZoom = scale }
                if let start = magnifyStartZoom {
                    zoomLevel = min(max(start * value.magnification, 0.02), 12)
                }
            }
            .onEnded { _ in magnifyStartZoom = nil }
    }

    private func handleScaleDrag(_ phase: HandleDragPhase, layer: Layer, canvasTransform: CGAffineTransform) {
        let center = layer.transform.position.applying(canvasTransform)
        switch phase {
        case .changed(let value):
            let startDistance = hypot(value.startLocation.x - center.x, value.startLocation.y - center.y)
            let currentDistance = hypot(value.location.x - center.x, value.location.y - center.y)
            if case .scale(let id, let startScale, _) = dragMode, id == layer.id {
                let factor = startDistance > 1 ? currentDistance / startDistance : 1
                document.updateDuringGesture { model in
                    model.modifyLayer(id: id) {
                        $0.transform.scale = min(max(startScale * Double(factor), 0.02), 60)
                    }
                }
            } else {
                document.beginGesture()
                dragMode = .scale(layerID: layer.id, startScale: layer.transform.scale, startDistance: startDistance)
            }
        case .ended:
            document.endGesture(undoManager, actionName: "Scale Layer")
            dragMode = nil
        }
    }

    private func handleRotateDrag(_ phase: HandleDragPhase, layer: Layer, canvasTransform: CGAffineTransform) {
        let center = layer.transform.position.applying(canvasTransform)
        switch phase {
        case .changed(let value):
            let startAngle = atan2(Double(value.startLocation.y - center.y), Double(value.startLocation.x - center.x))
            let currentAngle = atan2(Double(value.location.y - center.y), Double(value.location.x - center.x))
            if case .rotate(let id, let startRotation, _) = dragMode, id == layer.id {
                var degrees = startRotation + (currentAngle - startAngle) * 180 / .pi
                // Snap to 15° increments when close.
                let nearest = (degrees / 15).rounded() * 15
                if abs(degrees - nearest) < 2.5 { degrees = nearest }
                document.updateDuringGesture { model in
                    model.modifyLayer(id: id) { $0.transform.rotationDegrees = degrees }
                }
            } else {
                document.beginGesture()
                dragMode = .rotate(layerID: layer.id, startRotation: layer.transform.rotationDegrees, startAngle: startAngle)
            }
        case .ended:
            document.endGesture(undoManager, actionName: "Rotate Layer")
            dragMode = nil
        }
    }

    // MARK: - Selection & snapping

    private func hitTest(_ canvasPoint: CGPoint) -> Layer? {
        for layer in document.model.layers.reversed() where layer.isVisible {
            let naturalSize = renderStore.naturalSize(for: layer, model: document.model)
            if layer.transform.contains(canvasPoint, naturalSize: naturalSize) {
                return layer
            }
        }
        return nil
    }

    private func selectAt(_ canvasPoint: CGPoint) {
        editorState.selectedLayerID = hitTest(canvasPoint)?.id
    }

    private func snapped(_ point: CGPoint, tolerance: CGFloat) -> CGPoint {
        var result = point
        let canvas = document.model.canvasSize
        let xTargets: [CGFloat] = [canvas.width / 2, canvas.width / 3, canvas.width * 2 / 3]
        let yTargets: [CGFloat] = [canvas.height / 2, canvas.height / 3, canvas.height * 2 / 3]
        for target in xTargets where abs(point.x - target) < tolerance {
            result.x = target
            break
        }
        for target in yTargets where abs(point.y - target) < tolerance {
            result.y = target
            break
        }
        return result
    }

    private func nudgeSelection(_ press: KeyPress) -> KeyPress.Result {
        guard let id = editorState.selectedLayerID else { return .ignored }
        let step: CGFloat = press.modifiers.contains(.shift)
            ? document.model.canvasSize.width * 0.01
            : document.model.canvasSize.width * 0.001
        var dx: CGFloat = 0, dy: CGFloat = 0
        switch press.key {
        case .leftArrow: dx = -step
        case .rightArrow: dx = step
        case .upArrow: dy = -step
        case .downArrow: dy = step
        default: return .ignored
        }
        document.update(undoManager, actionName: "Nudge") { model in
            model.modifyLayer(id: id) {
                $0.transform.position.x += dx
                $0.transform.position.y += dy
            }
        }
        return .handled
    }

    // MARK: - Zoom controls

    private func zoomControls(scale: CGFloat) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 2) {
                    Button {
                        zoomLevel = max(scale / 1.4, 0.02)
                    } label: { Image(systemName: "minus.magnifyingglass") }
                    Text("\(Int((scale * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 48)
                    Button {
                        zoomLevel = min(scale * 1.4, 12)
                    } label: { Image(systemName: "plus.magnifyingglass") }
                    Button("Fit") {
                        zoomLevel = nil
                        pan = .zero
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(12)
            }
        }
        .allowsHitTesting(true)
    }
}

// MARK: - Selection overlay

enum HandleDragPhase {
    case changed(DragGesture.Value)
    case ended
}

/// Selection rectangle with corner scale handles and a rotation handle.
struct SelectionOverlay: View {
    let layer: Layer
    let naturalSize: CGSize
    let canvasTransform: CGAffineTransform
    let onScaleDrag: (HandleDragPhase) -> Void
    let onRotateDrag: (HandleDragPhase) -> Void

    var body: some View {
        let corners = layer.transform.corners(naturalSize: naturalSize).map { $0.applying(canvasTransform) }
        let topMid = CGPoint(x: (corners[0].x + corners[1].x) / 2, y: (corners[0].y + corners[1].y) / 2)
        let center = layer.transform.position.applying(canvasTransform)
        let up = normalize(CGPoint(x: topMid.x - center.x, y: topMid.y - center.y))
        let rotateHandle = CGPoint(x: topMid.x + up.x * 24, y: topMid.y + up.y * 24)

        ZStack {
            // Outline
            Path { path in
                path.move(to: corners[0])
                for corner in corners.dropFirst() { path.addLine(to: corner) }
                path.closeSubpath()
                path.move(to: topMid)
                path.addLine(to: rotateHandle)
            }
            .stroke(Color.accentColor.opacity(0.9), lineWidth: 1)
            .allowsHitTesting(false)

            ForEach(0..<4, id: \.self) { i in
                handle(at: corners[i], systemName: nil)
                    .gesture(
                        DragGesture(coordinateSpace: .named("viewport-overlay"))
                            .onChanged { onScaleDrag(.changed($0)) }
                            .onEnded { _ in onScaleDrag(.ended) }
                    )
            }

            handle(at: rotateHandle, systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                .gesture(
                    DragGesture(coordinateSpace: .named("viewport-overlay"))
                        .onChanged { onRotateDrag(.changed($0)) }
                        .onEnded { _ in onRotateDrag(.ended) }
                )
        }
        .coordinateSpace(name: "viewport-overlay")
    }

    private func handle(at point: CGPoint, systemName: String?) -> some View {
        Group {
            if let systemName {
                Image(systemName: systemName)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.accentColor))
            } else {
                Circle()
                    .fill(Color.white)
                    .stroke(Color.accentColor, lineWidth: 1.5)
                    .frame(width: 10, height: 10)
            }
        }
        .position(point)
    }

    private func normalize(_ v: CGPoint) -> CGPoint {
        let len = max(hypot(v.x, v.y), 0.001)
        return CGPoint(x: v.x / len, y: v.y / len)
    }
}
