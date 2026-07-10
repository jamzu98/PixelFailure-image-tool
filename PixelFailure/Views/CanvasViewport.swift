import SwiftUI

/// The central canvas: renders the composition, and handles selection,
/// move/scale/rotate, panning, and zooming.
struct CanvasViewport: View {
    @ObservedObject var document: PixelDocument
    @Bindable var editorState: EditorState
    @ObservedObject var renderStore: RenderStore
    let animationTime: Double?
    @Environment(\.undoManager) private var undoManager

    /// nil = fit to window.
    @State private var zoomLevel: CGFloat?
    @State private var pan: CGSize = .zero
    @State private var magnifyStartZoom: CGFloat?
    @State private var dragMode: DragMode?
    @State private var hoverLocation: CGPoint = .zero
    @State private var paintSession: PaintSession?
    @State private var isPainting = false
    @State private var paintInvalidation = TransientViewportInvalidation.none
    @State private var isHoveringViewport = false
    @State private var viewportSize: CGSize = .zero
    @State private var viewportQuality: RenderQuality = .full
    @State private var fullResolutionTask: Task<Void, Never>?
    @State private var awaitingTiledHandoff = false
    @FocusState private var isFocused: Bool

    private enum DragMode {
        /// Moves every entry: start position plus the inverse linear part of
        /// each layer's parent transform (canvas delta → parent-local delta).
        case move(entries: [(id: UUID, start: CGPoint, parentInverse: CGAffineTransform)])
        case pan(startPan: CGSize)
        case scale(layerID: UUID, startScale: Double, startDistance: CGFloat)
        case rotate(layerID: UUID, startRotation: Double, startAngle: Double)
        case multiScale(entries: [(id: UUID, world: LayerTransform, parent: CGAffineTransform)],
                        center: CGPoint, startDistance: CGFloat)
        case multiRotate(entries: [(id: UUID, world: LayerTransform, parent: CGAffineTransform)],
                         center: CGPoint, startAngle: Double)
        case paint
        case marquee(startCanvasPoint: CGPoint)
        case lassoFreehand(points: [CGPoint])
    }

    private func moveEntries(for ids: Set<UUID>) -> [(id: UUID, start: CGPoint, parentInverse: CGAffineTransform)] {
        ids.compactMap { id in
            guard let layer = document.model.layer(id: id),
                  !document.model.isEffectivelyLocked(id) else { return nil }
            let parent = document.model.parentAffine(of: id)
            let inverse = parent.isInvertible ? parent.inverted() : .identity
            return (id, layer.transform.position, inverse)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let viewSize = geo.size
            let scale = effectiveZoom(viewSize: viewSize)
            let canvasTransform = self.canvasTransform(viewSize: viewSize, scale: scale)
            let displayModel = animationTime.map { document.model.model(at: $0) } ?? document.model
            let transientInvalidation = animationTime.map {
                TransientViewportInvalidation(revision: $0.bitPattern &+ 1, region: .full)
            } ?? paintInvalidation

            ZStack {
                Color(nsColor: .underPageBackgroundColor)

                PointerEventBridge(onPointer: { sample in
                    editorState.pointerSample = sample
                }, onScroll: { dx, dy, location, modifiers in
                    handlePreciseScroll(dx: dx, dy: dy, location: location,
                                        modifiers: modifiers)
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)

                TiledCanvasView(model: displayModel,
                                renderStore: renderStore,
                                quality: viewportQuality,
                                canvasTransform: canvasTransform,
                                invalidation: renderStore.viewportInvalidation,
                                transientInvalidation: transientInvalidation,
                                suspendsContentUpdates: isDirectlyTransforming,
                                onPresented: { quality in
                                    guard awaitingTiledHandoff,
                                          !isDirectlyTransforming,
                                          quality != .proxy else { return }
                                    awaitingTiledHandoff = false
                                })
                .opacity(usesImmediateTransformPreview ? 0 : 1)
                .allowsHitTesting(false)

                if usesImmediateTransformPreview {
                    immediateTransformPreview(model: displayModel,
                                              canvasTransform: canvasTransform,
                                              quality: isDirectlyTransforming ? .proxy : .preview)
                        .allowsHitTesting(false)
                }

                WorkspaceOverlay(document: document,
                                 editorState: editorState,
                                 canvasTransform: canvasTransform,
                                 scale: scale)

                if editorState.activeTool == .move,
                   let layer = document.model.layer(id: editorState.selectedLayerID) {
                    let parentAffine = document.model.parentAffine(of: layer.id)
                    SelectionOverlay(layer: layer,
                                     naturalSize: renderStore.naturalSize(for: layer, model: document.model),
                                     parentAffine: parentAffine,
                                     canvasTransform: canvasTransform,
                                     onScaleDrag: { phase in handleScaleDrag(phase, layer: layer, parentAffine: parentAffine, canvasTransform: canvasTransform) },
                                     onRotateDrag: { phase in handleRotateDrag(phase, layer: layer, parentAffine: parentAffine, canvasTransform: canvasTransform) })
                        .allowsHitTesting(!document.model.isEffectivelyLocked(layer.id))
                        .opacity(document.model.isEffectivelyLocked(layer.id) ? 0.4 : 1)
                }

                if editorState.activeTool == .node,
                   let layer = document.model.layer(id: editorState.selectedLayerID),
                   let path = layer.pathConfig {
                    PathNodeOverlay(document: document, layer: layer, config: path,
                                    canvasTransform: canvasTransform,
                                    parentAffine: document.model.parentAffine(of: layer.id))
                }

                if editorState.activeTool == .move,
                   editorState.selectedLayerIDs.count > 1,
                   let bounds = multiSelectionBounds {
                    MultiSelectionOverlay(bounds: bounds,
                                          canvasTransform: canvasTransform,
                                          onScaleDrag: { handleMultiScaleDrag($0, bounds: bounds,
                                                                              canvasTransform: canvasTransform) },
                                          onRotateDrag: { handleMultiRotateDrag($0, bounds: bounds,
                                                                                canvasTransform: canvasTransform) })
                }

                SelectionAntsView(editorState: editorState,
                                  canvasTransform: canvasTransform,
                                  scale: scale,
                                  hoverCanvasPoint: hoverLocation.applying(canvasTransform.inverted()))

                if editorState.activeTool == .crop {
                    CropOverlay(document: document,
                                editorState: editorState,
                                renderStore: renderStore,
                                canvasTransform: canvasTransform,
                                onApply: { applyCrop() },
                                onCancel: { cancelCrop() })
                }

                if document.model.workspace.showsNavigator {
                    NavigatorView(document: document, renderStore: renderStore,
                                  canvasTransform: canvasTransform, viewportSize: viewSize,
                                  zoomScale: scale, pan: $pan)
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
                // With a selection over an image layer, delete clears pixels;
                // otherwise it deletes the layer (move tool only).
                if let selection = editorState.selection,
                   let layer = document.model.layer(id: editorState.selectedLayerID),
                   layer.kind.isImage, !layer.isLocked {
                    document.deletePixels(selection: selection, layerID: layer.id,
                                          renderStore: renderStore, undoManager: undoManager)
                    return .handled
                }
                guard editorState.activeTool == .move, !editorState.selectedLayerIDs.isEmpty else { return .ignored }
                document.deleteLayers(ids: editorState.selectedLayerIDs, undoManager: undoManager)
                editorState.selectedLayerIDs = []
                return .handled
            }
            .onKeyPress(.escape) {
                if editorState.lassoVertices != nil {
                    editorState.lassoVertices = nil
                    return .handled
                }
                if editorState.activeTool == .crop {
                    cancelCrop()
                    return .handled
                }
                if editorState.editingMaskLayerID != nil {
                    editorState.editingMaskLayerID = nil
                    editorState.activeTool = .move
                    return .handled
                }
                if editorState.selection != nil {
                    editorState.selection = nil
                    return .handled
                }
                guard !editorState.selectedLayerIDs.isEmpty else { return .ignored }
                editorState.selectedLayerIDs = []
                return .handled
            }
            .onKeyPress(.return) {
                if editorState.lassoVertices != nil {
                    closePolygonalLasso()
                    return .handled
                }
                if editorState.activeTool == .pen,
                   let id = editorState.selectedLayerID,
                   document.model.layer(id: id)?.kind.isPath == true {
                    document.update(undoManager, actionName: "Close Path") {
                        $0.modifyLayer(id: id) { $0.modifyPath { $0.isClosed = true } }
                    }
                    editorState.activeTool = .node
                    return .handled
                }
                guard editorState.activeTool == .crop, editorState.cropDraft != nil else { return .ignored }
                applyCrop()
                return .handled
            }
            .onKeyPress(phases: .down) { press in
                toolShortcut(press)
            }
            .onTapGesture(count: 1) { location in
                isFocused = true
                handleTap(at: location, viewSize: viewSize, scale: scale, canvasTransform: canvasTransform)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverLocation = location
                    isHoveringViewport = true
                    setCursor(cursor(at: location, canvasTransform: canvasTransform, scale: scale))
                case .ended:
                    isHoveringViewport = false
                    setCursor(.arrow)
                }
            }
            .onChange(of: editorState.activeTool) { _, _ in
                // Tool switched by shortcut while hovering: update immediately
                // instead of waiting for the next mouse move.
                setCursor(cursor(at: hoverLocation, canvasTransform: canvasTransform, scale: scale))
            }
            .onModifierKeysChanged(mask: .option) { _, _ in
                // Modifier presses don't produce hover events; refresh so the
                // zoom cursor flips between +/- the moment option changes.
                guard isHoveringViewport else { return }
                setCursor(cursor(at: hoverLocation, canvasTransform: canvasTransform, scale: scale))
            }
            .contextMenu {
                contextMenuContent(canvasTransform: canvasTransform)
            }
            .copyable(copyableItems())
            .cuttable(for: LayerTransfer.self) {
                if let selection = editorState.selection,
                   let id = editorState.selectedLayerID,
                   !document.model.isEffectivelyLocked(id),
                   let payload = document.transferPayload(for: selection, layerID: id,
                                                          renderStore: renderStore) {
                    document.deletePixels(selection: selection, layerID: id,
                                          renderStore: renderStore, undoManager: undoManager)
                    return [payload]
                }
                guard let id = editorState.selectedLayerID,
                      let payload = document.transferPayload(for: id, renderStore: renderStore) else { return [] }
                document.deleteLayer(id: id, undoManager: undoManager)
                editorState.selectedLayerID = nil
                return [payload]
            }
            .onPasteCommand(of: [.pixelFailureLayer, .png, .tiff, .fileURL, .image]) { _ in
                pasteAny()
            }
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { newSize in
                viewportSize = newSize
            }
        }
        .clipped()
        .onChange(of: document.isContinuousEditing) { _, _ in updateViewportQuality() }
        .onChange(of: isPainting) { _, _ in updateViewportQuality() }
        .onChange(of: editorState.isAnimationPlaying) { _, _ in updateViewportQuality() }
        .onChange(of: editorState.isAnimationScrubbing) { _, _ in updateViewportQuality() }
        .onDisappear { fullResolutionTask?.cancel() }
    }

    private func updateViewportQuality() {
        fullResolutionTask?.cancel()
        let active = document.isContinuousEditing || isPainting
            || editorState.isAnimationPlaying || editorState.isAnimationScrubbing
        if active {
            viewportQuality = .proxy
            return
        }
        viewportQuality = .preview
        fullResolutionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            let stillActive = document.isContinuousEditing || isPainting
                || editorState.isAnimationPlaying || editorState.isAnimationScrubbing
            guard !Task.isCancelled, !stillActive else { return }
            viewportQuality = .full
        }
    }

    private var isDirectlyTransforming: Bool {
        switch dragMode {
        case .move, .scale, .rotate, .multiScale, .multiRotate:
            true
        default:
            false
        }
    }

    private var usesImmediateTransformPreview: Bool {
        isDirectlyTransforming || awaitingTiledHandoff
    }

    @ViewBuilder
    private func immediateTransformPreview(model: ProjectModel,
                                           canvasTransform: CGAffineTransform,
                                           quality: RenderQuality) -> some View {
        if let composite = renderStore.composite(model: model, quality: quality) {
            Canvas { context, _ in
                context.concatenate(canvasTransform)
                let canvasRect = CGRect(origin: .zero, size: model.canvasSize)
                var clipped = context
                clipped.clip(to: Path(canvasRect))
                clipped.draw(Image(decorative: composite, scale: 1), in: canvasRect)
            }
        } else {
            let items = renderStore.renderItems(model: model, quality: quality)
            Canvas { context, _ in
                context.concatenate(canvasTransform)
                CanvasRenderer.draw(items: items,
                                    background: model.background,
                                    canvasSize: model.canvasSize,
                                    in: context,
                                    space: model.colorSettings.workingSpace)
            }
        }
    }

    /// Pastes whatever the pasteboard holds: one of our layers, or any
    /// system image (screenshot, browser copy, Finder file).
    private func pasteAny() {
        switch LayerPasteboard.readAny() {
        case .layer(let transfer):
            editorState.selectedLayerID = document.pasteLayer(transfer, undoManager: undoManager)
        case .image(let data, _):
            if let id = document.addImageLayer(data: data, suggestedName: "Pasted Image", undoManager: undoManager) {
                editorState.selectedLayerID = id
            }
        case nil:
            break
        }
    }

    // MARK: - Scroll navigation

    /// AppKit supplies precise deltas and tablet metadata while SwiftUI keeps
    /// ownership of the higher-level tool gestures.
    private func handlePreciseScroll(dx: CGFloat, dy: CGFloat, location: CGPoint,
                                     modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.option) || modifiers.contains(.command) {
            let currentScale = effectiveZoom(viewSize: viewportSize)
            let factor = 1 + dy * 0.01
            let newScale = min(max(currentScale * factor, 0.02), 12)
            let canvas = document.model.canvasSize
            let transform = canvasTransform(viewSize: viewportSize, scale: currentScale)
            guard transform.isInvertible else { return }
            let canvasPoint = location.applying(transform.inverted())
            pan = CGSize(width: (location.x - canvasPoint.x * newScale)
                            - (viewportSize.width - canvas.width * newScale) / 2,
                         height: (location.y - canvasPoint.y * newScale)
                            - (viewportSize.height - canvas.height * newScale) / 2)
            zoomLevel = newScale
        } else {
            pan = CGSize(width: pan.width + dx, height: pan.height + dy)
        }
    }

    // MARK: - Copy / paste / context menu

    private func copyableItems() -> [LayerTransfer] {
        if let selection = editorState.selection,
           let id = editorState.selectedLayerID,
           let payload = document.transferPayload(for: selection, layerID: id,
                                                  renderStore: renderStore) {
            return [payload]
        }
        guard let id = editorState.selectedLayerID,
              let payload = document.transferPayload(for: id, renderStore: renderStore) else { return [] }
        return [payload]
    }

    /// Right-click acts on the layer under the cursor (falling back to the
    /// current selection), matching what design apps do.
    @ViewBuilder
    private func contextMenuContent(canvasTransform: CGAffineTransform) -> some View {
        let hovered = hitTest(hoverLocation.applying(canvasTransform.inverted()))
        let target = hovered ?? document.model.layer(id: editorState.selectedLayerID)

        if let layer = target {
            Section(layer.name) {
                Button("Copy") {
                    editorState.selectedLayerID = layer.id
                    if let selection = editorState.selection, layer.kind.isImage {
                        document.copySelection(selection, layerID: layer.id, renderStore: renderStore)
                    } else {
                        document.copyLayer(id: layer.id, renderStore: renderStore)
                    }
                }
                Button("Cut") {
                    if let selection = editorState.selection, layer.kind.isImage {
                        document.cutSelection(selection, layerID: layer.id,
                                              renderStore: renderStore, undoManager: undoManager)
                    } else {
                        document.cutLayer(id: layer.id, renderStore: renderStore, undoManager: undoManager)
                        if editorState.selectedLayerID == layer.id { editorState.selectedLayerID = nil }
                    }
                }
                Button("Duplicate") {
                    editorState.selectedLayerID = document.duplicateLayer(id: layer.id, undoManager: undoManager)
                }
                Button("Rasterize") {
                    document.rasterizeLayer(id: layer.id, renderStore: renderStore, undoManager: undoManager)
                }
            }
        }

        Button("Paste") {
            pasteAny()
        }
        .disabled(!LayerPasteboard.hasPayload)

        if let layer = target {
            Divider()
            Menu("Arrange") {
                Button("Bring to Front") { document.reorderLayer(id: layer.id, offset: .max, undoManager: undoManager) }
                Button("Bring Forward") { document.reorderLayer(id: layer.id, offset: 1, undoManager: undoManager) }
                Button("Send Backward") { document.reorderLayer(id: layer.id, offset: -1, undoManager: undoManager) }
                Button("Send to Back") { document.reorderLayer(id: layer.id, offset: .min, undoManager: undoManager) }
            }
            Button("Flip Horizontal") {
                document.flipLayer(id: layer.id, horizontally: true, undoManager: undoManager)
            }
            Button("Flip Vertical") {
                document.flipLayer(id: layer.id, horizontally: false, undoManager: undoManager)
            }
            Button(layer.isLocked ? "Unlock" : "Lock") {
                document.toggleLock(id: layer.id, undoManager: undoManager)
            }
            Button(layer.isVisible ? "Hide" : "Show") {
                document.update(undoManager, actionName: layer.isVisible ? "Hide Layer" : "Show Layer") { model in
                    model.modifyLayer(id: layer.id) { $0.isVisible.toggle() }
                }
            }
            Button("Delete", role: .destructive) {
                document.deleteLayer(id: layer.id, undoManager: undoManager)
                if editorState.selectedLayerID == layer.id { editorState.selectedLayerID = nil }
            }
        }

        if editorState.selectedLayerID != nil {
            Divider()
            Button("Deselect") { editorState.selectedLayerID = nil }
        }
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
        let center = CGPoint(x: viewSize.width / 2 + pan.width,
                             y: viewSize.height / 2 + pan.height)
        return CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: editorState.canvasRotationDegrees * .pi / 180)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -canvas.width / 2, y: -canvas.height / 2)
    }

    // MARK: - Gestures

    private func mainDragGesture(canvasTransform: CGAffineTransform, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragMode == nil {
                    isFocused = true
                    switch editorState.activeTool {
                    case .brush, .eraser, .clone, .heal, .smudge, .dodge, .burn:
                        if (editorState.activeTool == .clone || editorState.activeTool == .heal),
                           editorState.cloneSourceCanvas == nil { break }
                        dragMode = .paint
                        startPaintSession()
                    case .hand, .zoom, .eyedropper, .crop, .wand, .pen, .node:
                        dragMode = .pan(startPan: pan)
                    case .marquee:
                        dragMode = .marquee(startCanvasPoint: value.startLocation.applying(canvasTransform.inverted()))
                    case .lasso:
                        if editorState.lassoPolygonal {
                            dragMode = .pan(startPan: pan)
                        } else {
                            dragMode = .lassoFreehand(points: [value.startLocation.applying(canvasTransform.inverted())])
                        }
                    case .move:
                        let canvasPoint = value.startLocation.applying(canvasTransform.inverted())
                        if let hit = hitTest(canvasPoint) {
                            // Dragging a layer that's part of the current
                            // multi-selection moves the whole selection.
                            if !editorState.selectedLayerIDs.contains(hit.id) {
                                editorState.selectedLayerID = hit.id
                            }
                            document.beginGesture()
                            dragMode = .move(entries: moveEntries(for: editorState.selectedLayerIDs))
                        } else {
                            dragMode = .pan(startPan: pan)
                        }
                    }
                }
                switch dragMode {
                case .pan(let startPan):
                    // The crop overlay owns dragging while a draft exists.
                    if editorState.activeTool == .crop && editorState.cropDraft != nil { break }
                    if editorState.activeTool == .hand { setCursor(.closedHand) }
                    pan = CGSize(width: startPan.width + value.translation.width,
                                 height: startPan.height + value.translation.height)
                case .move(let entries):
                    let canvasDelta = CGVector(dx: value.translation.width / scale,
                                               dy: value.translation.height / scale)
                    document.updateDuringGesture { model in
                        for entry in entries {
                            // Map the canvas-space delta into the layer's
                            // parent space (linear part only).
                            let inverse = entry.parentInverse
                            let local = CGVector(dx: canvasDelta.dx * inverse.a + canvasDelta.dy * inverse.c,
                                                 dy: canvasDelta.dx * inverse.b + canvasDelta.dy * inverse.d)
                            var newPosition = CGPoint(x: entry.start.x + local.dx,
                                                      y: entry.start.y + local.dy)
                            if entries.count == 1 {
                                newPosition = snapped(newPosition, layerID: entry.id,
                                                      tolerance: 8 / scale)
                            }
                            model.modifyLayer(id: entry.id) { $0.transform.position = newPosition }
                        }
                    }
                case .paint:
                    extendPaintStroke(to: value.location, canvasTransform: canvasTransform)
                case .marquee(let start):
                    let current = value.location.applying(canvasTransform.inverted())
                    editorState.selectionDraft = marqueePath(from: start, to: current)
                case .lassoFreehand(var points):
                    let current = value.location.applying(canvasTransform.inverted())
                    if let last = points.last, hypot(current.x - last.x, current.y - last.y) > 2 / scale {
                        points.append(current)
                        dragMode = .lassoFreehand(points: points)
                    }
                    var preview = Path()
                    if let first = points.first {
                        preview.move(to: first)
                        for point in points.dropFirst() { preview.addLine(to: point) }
                        preview.closeSubpath()
                    }
                    editorState.selectionDraft = preview
                default:
                    break
                }
            }
            .onEnded { value in
                switch dragMode {
                case .move:
                    awaitingTiledHandoff = true
                    document.endGesture(undoManager, actionName: "Move Layer")
                    editorState.smartGuideX = nil
                    editorState.smartGuideY = nil
                case .paint:
                    commitPaintSession()
                case .marquee(let start):
                    let end = value.location.applying(canvasTransform.inverted())
                    editorState.selectionDraft = nil
                    commitSelectionPath(marqueePath(from: start, to: end))
                case .lassoFreehand(let points):
                    editorState.selectionDraft = nil
                    if points.count >= 3 {
                        var path = Path()
                        path.move(to: points[0])
                        for point in points.dropFirst() { path.addLine(to: point) }
                        path.closeSubpath()
                        commitSelectionPath(path)
                    }
                case .pan, .none:
                    if editorState.activeTool == .hand { setCursor(.openHand) }
                    // A drag that never moved far acts as a click-select.
                    if editorState.activeTool == .move,
                       value.translation.width.magnitude < 3, value.translation.height.magnitude < 3 {
                        selectAt(value.location.applying(canvasTransform.inverted()))
                    }
                default:
                    break
                }
                dragMode = nil
            }
    }

    // MARK: - Selection gestures

    private func marqueePath(from start: CGPoint, to end: CGPoint) -> Path {
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        return editorState.marqueeEllipse ? Path(ellipseIn: rect) : Path(rect)
    }

    private func commitSelectionPath(_ path: Path) {
        editorState.selection = CanvasSelection.combine(existing: editorState.selection,
                                                        new: path,
                                                        modifiers: NSEvent.modifierFlags,
                                                        feather: editorState.featherDefault)
    }

    /// Polygonal lasso: click adds vertices; clicking near the first vertex
    /// or pressing Return closes; Esc cancels.
    private func polygonalLassoClick(at canvasPoint: CGPoint, scale: CGFloat) {
        if var vertices = editorState.lassoVertices {
            if let first = vertices.first, vertices.count >= 3,
               hypot(canvasPoint.x - first.x, canvasPoint.y - first.y) < 8 / scale {
                closePolygonalLasso()
                return
            }
            vertices.append(canvasPoint)
            editorState.lassoVertices = vertices
        } else {
            editorState.lassoVertices = [canvasPoint]
        }
    }

    private func closePolygonalLasso() {
        guard let vertices = editorState.lassoVertices, vertices.count >= 3 else {
            editorState.lassoVertices = nil
            return
        }
        var path = Path()
        path.move(to: vertices[0])
        for point in vertices.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        editorState.lassoVertices = nil
        commitSelectionPath(path)
    }

    private func wandClick(at canvasPoint: CGPoint) {
        let model = document.model
        guard canvasPoint.x >= 0, canvasPoint.y >= 0,
              canvasPoint.x <= model.canvasSize.width, canvasPoint.y <= model.canvasSize.height else { return }
        let items = renderStore.renderItems(model: model, quality: .preview)
        let maxDim = 1024.0
        let sampleScale = min(1, maxDim / Double(max(model.canvasSize.width, model.canvasSize.height)))
        let target = CGSize(width: max(8, model.canvasSize.width * sampleScale),
                            height: max(8, model.canvasSize.height * sampleScale))
        guard let flat = PNGExporter.render(items: items,
                                            background: model.background,
                                            canvasSize: model.canvasSize,
                                            targetPixelSize: target,
                                            colorSettings: model.colorSettings.previewVariant),
              let path = MagicWand.select(at: canvasPoint,
                                          tolerance: editorState.wandTolerance,
                                          composite: flat,
                                          canvasSize: model.canvasSize) else { return }
        commitSelectionPath(path)
    }

    // MARK: - Cursor

    /// Always re-asserts the cursor: AppKit resets it behind our back when
    /// the pointer crosses buttons or other tracking areas, so caching "what
    /// we set last" leads to stale arrows. set() is cheap and idempotent.
    private func setCursor(_ cursor: NSCursor) {
        cursor.set()
    }

    /// The cursor for the current tool and whatever is under the pointer:
    /// selection handles, crop handles, or plain canvas.
    private func cursor(at location: CGPoint, canvasTransform: CGAffineTransform, scale: CGFloat) -> NSCursor {
        switch editorState.activeTool {
        case .hand:
            return dragMode != nil ? .closedHand : .openHand
        case .zoom:
            return NSEvent.modifierFlags.contains(.option) ? .zoomOut : .zoomIn
        case .eyedropper:
            return Cursors.eyedropper
        case .marquee, .lasso, .wand:
            return .crosshair
        case .pen:
            return .crosshair
        case .node:
            return .arrow
        case .brush, .eraser, .clone, .heal, .smudge, .dodge, .burn:
            return Cursors.brush(diameter: editorState.brush.size * scale)
        case .crop:
            return cropCursor(at: location, canvasTransform: canvasTransform)
        case .move:
            return moveCursor(at: location, canvasTransform: canvasTransform)
        }
    }

    private func moveCursor(at location: CGPoint, canvasTransform: CGAffineTransform) -> NSCursor {
        guard let layer = document.model.layer(id: editorState.selectedLayerID),
              !layer.isLocked else { return .arrow }
        let naturalSize = renderStore.naturalSize(for: layer, model: document.model)
        let parentAffine = document.model.parentAffine(of: layer.id)
        let corners = layer.transform.corners(naturalSize: naturalSize)
            .map { $0.applying(parentAffine).applying(canvasTransform) }

        for (index, corner) in corners.enumerated() where hypot(location.x - corner.x, location.y - corner.y) < 9 {
            return Cursors.resizeCorner(index)
        }

        // Rotation handle: 24pt out from the top edge's midpoint.
        let topMid = CGPoint(x: (corners[0].x + corners[1].x) / 2, y: (corners[0].y + corners[1].y) / 2)
        let center = layer.transform.position.applying(parentAffine).applying(canvasTransform)
        let length = max(hypot(topMid.x - center.x, topMid.y - center.y), 0.001)
        let handle = CGPoint(x: topMid.x + (topMid.x - center.x) / length * 24,
                             y: topMid.y + (topMid.y - center.y) / length * 24)
        if hypot(location.x - handle.x, location.y - handle.y) < 10 {
            return Cursors.rotate
        }

        return .arrow
    }

    private func cropCursor(at location: CGPoint, canvasTransform: CGAffineTransform) -> NSCursor {
        guard let draft = editorState.cropDraft else { return .crosshair }
        let rect = draft.applying(canvasTransform)
        let handleUnits: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 0.5),
            CGPoint(x: 1, y: 1), CGPoint(x: 0.5, y: 1), CGPoint(x: 0, y: 1), CGPoint(x: 0, y: 0.5),
        ]
        for unit in handleUnits {
            let point = CGPoint(x: rect.minX + rect.width * unit.x, y: rect.minY + rect.height * unit.y)
            if hypot(location.x - point.x, location.y - point.y) < 9 {
                return Cursors.resizeForCropHandle(unit: unit)
            }
        }
        if rect.insetBy(dx: 4, dy: 4).contains(location) {
            return .openHand
        }
        return .crosshair
    }

    // MARK: - Tool dispatch

    private func handleTap(at location: CGPoint, viewSize: CGSize, scale: CGFloat, canvasTransform: CGAffineTransform) {
        let canvasPoint = location.applying(canvasTransform.inverted())
        if editorState.activeTool == .clone || editorState.activeTool == .heal {
            if NSEvent.modifierFlags.contains(.option) {
                editorState.cloneSourceCanvas = canvasPoint
                return
            }
            guard editorState.cloneSourceCanvas != nil else { return }
        }
        switch editorState.activeTool {
        case .move:
            selectAt(canvasPoint)
        case .zoom:
            let zoomOut = NSEvent.modifierFlags.contains(.option)
            let newScale = min(max(zoomOut ? scale / 1.5 : scale * 1.5, 0.02), 12)
            // Keep the clicked canvas point stationary under the cursor.
            let canvas = document.model.canvasSize
            pan = CGSize(width: (location.x - canvasPoint.x * newScale) - (viewSize.width - canvas.width * newScale) / 2,
                         height: (location.y - canvasPoint.y * newScale) - (viewSize.height - canvas.height * newScale) / 2)
            zoomLevel = newScale
        case .eyedropper:
            pickColor(at: canvasPoint)
        case .brush, .eraser, .clone, .heal, .smudge, .dodge, .burn:
            // A click without a drag is a single dab.
            startPaintSession()
            extendPaintStroke(to: location, canvasTransform: canvasTransform)
            commitPaintSession()
        case .lasso where editorState.lassoPolygonal:
            polygonalLassoClick(at: canvasPoint, scale: scale)
        case .wand:
            wandClick(at: canvasPoint)
        case .pen:
            if let layer = document.model.layer(id: editorState.selectedLayerID), layer.kind.isPath {
                document.addPathNode(to: layer.id, canvasPoint: canvasPoint, undoManager: undoManager)
            } else {
                editorState.selectedLayerID = document.addPathLayer(firstPoint: canvasPoint,
                                                                    undoManager: undoManager)
            }
        case .node:
            selectAt(canvasPoint)
        case .hand, .crop, .marquee, .lasso:
            break
        }
    }

    private func toolShortcut(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isEmpty else { return .ignored }
        for tool in EditorTool.allCases where String(tool.shortcutKey) == press.characters.lowercased() {
            editorState.activeTool = tool
            if tool != .crop { editorState.cropDraft = nil }
            return .handled
        }
        return .ignored
    }

    // MARK: - Painting

    private func startPaintSession() {
        guard paintSession == nil else { return }

        // Mask editing takes priority over content painting.
        if let maskID = editorState.editingMaskLayerID,
           let layer = document.model.layer(id: maskID),
           !document.model.isEffectivelyLocked(maskID),
           let mask = layer.mask {
            let base = renderStore.originalImage(key: mask.imageKey)
            var clip: CGPath?
            if let selection = editorState.selection {
                let naturalSize = renderStore.naturalSize(for: layer, model: document.model)
                if var t = SelectionRasterizer.canvasToLocalBuffer(layer: layer,
                                                                   naturalSize: naturalSize,
                                                                   bufferPixelSize: mask.pixelSize,
                                                                   parentAffine: document.model.parentAffine(of: maskID)) {
                    clip = selection.path.cgPath.copy(using: &t)
                }
            }
            paintSession = PaintSession(target: .mask(layerID: maskID), base: base,
                                        pixelSize: mask.pixelSize, clipPath: clip)
        } else {
            var targetID = editorState.selectedLayerID
            let targetLayer = document.model.layer(id: targetID ?? UUID())
            let paintable = (targetLayer?.kind.isImage ?? false)
                && targetLayer.map { !document.model.isEffectivelyLocked($0.id) } == true
            if !paintable {
                let retouch = [.clone, .heal, .smudge, .dodge, .burn].contains(editorState.activeTool)
                if retouch { return }
                targetID = document.addPaintLayer(undoManager: undoManager)
                editorState.selectedLayerID = targetID
            }
            guard let id = targetID,
                  let layer = document.model.layer(id: id),
                  let config = layer.imageConfig else { return }
            let base = renderStore.originalImage(key: config.imageKey)
            var clip: CGPath?
            if let selection = editorState.selection {
                let naturalSize = renderStore.naturalSize(for: layer, model: document.model)
                if var t = SelectionRasterizer.canvasToContentBuffer(layer: layer,
                                                                     naturalSize: naturalSize,
                                                                     config: config,
                                                                     parentAffine: document.model.parentAffine(of: id)) {
                    clip = selection.path.cgPath.copy(using: &t)
                }
            }
            paintSession = PaintSession(target: .content(layerID: id), base: base,
                                        pixelSize: config.pixelSize, clipPath: clip,
                                        colorSettings: document.model.colorSettings)
        }
        renderStore.activePaintSession = paintSession
        if paintSession != nil {
            isPainting = true
            paintInvalidation = TransientViewportInvalidation(
                revision: paintInvalidation.revision &+ 1, region: .none)
        }
    }

    private func extendPaintStroke(to viewPoint: CGPoint, canvasTransform: CGAffineTransform) {
        guard let session = paintSession,
              let layer = document.model.layer(id: session.targetLayerID) else { return }
        let naturalSize = renderStore.naturalSize(for: layer, model: document.model)
        let affine = layer.transform.affine(naturalSize: naturalSize)
            .concatenating(document.model.parentAffine(of: layer.id))
        guard affine.isInvertible, naturalSize.width > 0 else { return }

        let canvasPoint = viewPoint.applying(canvasTransform.inverted())
        let local = canvasPoint.applying(affine.inverted())
        let brush = editorState.brush
        let erase = editorState.activeTool == .eraser
        let layerScale = max(layer.transform.scale, 0.0001)

        var bufferPoint: CGPoint
        var bufferPerLocal = 1.0
        var color = brush.color

        switch session.target {
        case .content:
            guard let config = layer.imageConfig else { return }
            if let crop = config.crop {
                bufferPoint = CGPoint(x: crop.minX * config.pixelSize.width + local.x,
                                      y: crop.minY * config.pixelSize.height + local.y)
            } else {
                bufferPoint = local
            }
        case .mask:
            guard let mask = layer.mask else { return }
            bufferPerLocal = Double(mask.pixelSize.width) / Double(naturalSize.width)
            bufferPoint = CGPoint(x: local.x * bufferPerLocal, y: local.y * bufferPerLocal)
            // Brush hides or reveals per the options bar; eraser does the opposite.
            let reveals = erase ? !editorState.maskBrushReveals : editorState.maskBrushReveals
            color = reveals ? .white : .black
        }

        let pressure = min(max(editorState.pointerSample.pressure, 0.05), 1)
        let radius = brush.size / 2 / layerScale * bufferPerLocal
            * (brush.pressureControlsSize ? pressure : 1)
        let opacity = brush.opacity * (brush.pressureControlsOpacity ? pressure : 1)
        let isRetouch = [.clone, .heal, .smudge, .dodge, .burn].contains(editorState.activeTool)
        if isRetouch && !session.isMask {
            let sourcePoint: CGPoint? = editorState.cloneSourceCanvas.map { sourceCanvas in
                let sourceLocal = sourceCanvas.applying(affine.inverted())
                if let config = layer.imageConfig, let crop = config.crop {
                    return CGPoint(x: crop.minX * config.pixelSize.width + sourceLocal.x,
                                   y: crop.minY * config.pixelSize.height + sourceLocal.y)
                }
                return sourceLocal
            }
            let mode: PaintSession.RetouchMode
            switch editorState.activeTool {
            case .clone: mode = .clone
            case .heal: mode = .heal
            case .smudge: mode = .smudge
            case .dodge: mode = .dodge
            default: mode = .burn
            }
            session.retouch(to: bufferPoint, source: sourcePoint, mode: mode,
                            radius: radius, hardness: brush.hardness, opacity: opacity,
                            spacing: brush.spacing, smoothing: brush.smoothing)
        } else {
            session.stroke(to: bufferPoint,
                           radius: radius,
                           hardness: brush.hardness,
                           opacity: opacity,
                           color: color,
                           erase: erase && !session.isMask,
                           spacing: brush.spacing,
                           smoothing: brush.smoothing,
                           scatter: brush.scatter,
                           sizeJitter: brush.sizeJitter,
                           opacityJitter: brush.opacityJitter,
                           angleJitter: brush.angleJitter,
                           tipAspect: brush.tipAspect,
                           grain: brush.grain)
        }
        let parent = document.model.parentAffine(of: layer.id)
        let parentScale = max(hypot(parent.a, parent.b), 1)
        let canvasRadius = brush.size / 2 * parentScale + 4
        let stamp = CGRect(x: canvasPoint.x - canvasRadius,
                           y: canvasPoint.y - canvasRadius,
                           width: canvasRadius * 2, height: canvasRadius * 2)
        let accumulated: RenderInvalidationRegion
        switch paintInvalidation.region {
        case .none:
            accumulated = .rect(stamp)
        case .rect(let current):
            accumulated = .rect(current.union(stamp))
        case .full:
            accumulated = .full
        }
        paintInvalidation = TransientViewportInvalidation(
            revision: paintInvalidation.revision &+ 1, region: accumulated)
    }

    private func commitPaintSession() {
        guard let session = paintSession else { return }
        session.endStroke()
        defer {
            paintSession = nil
            renderStore.activePaintSession = nil
            isPainting = false
            paintInvalidation = TransientViewportInvalidation(
                revision: paintInvalidation.revision &+ 1, region: .none)
        }
        guard let image = session.currentImage,
              let data = PNGExporter.pngData(image) else { return }
        let key = document.storeImage(data: data, fileExtension: "png")
        switch session.target {
        case .content(let id):
            document.update(undoManager, actionName: editorState.activeTool.displayName) { model in
                model.modifyLayer(id: id) { layer in
                    layer.recordSourceIfNeeded()
                    layer.modifyImage { $0.imageKey = key }
                }
            }
        case .mask(let id):
            document.update(undoManager, actionName: "Paint Mask") { model in
                model.modifyLayer(id: id) { $0.mask?.imageKey = key }
            }
        }
    }

    // MARK: - Eyedropper

    private func pickColor(at canvasPoint: CGPoint) {
        let model = document.model
        guard canvasPoint.x >= 0, canvasPoint.y >= 0,
              canvasPoint.x <= model.canvasSize.width, canvasPoint.y <= model.canvasSize.height else { return }

        let items = renderStore.renderItems(model: model, quality: .preview)
        let maxDim = 700.0
        let sampleScale = min(1, maxDim / Double(max(model.canvasSize.width, model.canvasSize.height)))
        let target = CGSize(width: max(8, model.canvasSize.width * sampleScale),
                            height: max(8, model.canvasSize.height * sampleScale))
        guard var flat = PNGExporter.render(items: items,
                                            background: model.background,
                                            canvasSize: model.canvasSize,
                                            targetPixelSize: target,
                                            colorSettings: model.colorSettings.previewVariant) else { return }
        if !model.canvasEffects.isEmpty {
            flat = EffectPipeline.shared.apply(effects: model.canvasEffects, to: flat, palette: model.palette)
        }
        guard let sampler = ImageSampler(cgImage: flat, maxDimension: Int(maxDim),
                                         space: model.colorSettings.workingSpace) else { return }
        let picked = sampler.color(atUnitX: canvasPoint.x / model.canvasSize.width,
                                   y: canvasPoint.y / model.canvasSize.height).withAlpha(1)

        // The brush always adopts the picked color, plus a context-aware home.
        editorState.brush.color = picked
        if let layer = model.layer(id: editorState.selectedLayerID), layer.kind.isText {
            document.update(undoManager, actionName: "Pick Text Color") { model in
                model.modifyLayer(id: layer.id) { $0.modifyText { $0.color = picked } }
            }
        } else if editorState.selectedLayerID == nil {
            document.update(undoManager, actionName: "Pick Background") { model in
                model.background = picked
            }
        } else {
            // Replace the targeted swatch (never grow or shrink the palette),
            // then advance the target so successive picks fill the palette.
            let count = model.palette.colors.count
            guard count > 0 else { return }
            let index = min(editorState.eyedropperSwatchIndex, count - 1)
            document.update(undoManager, actionName: "Pick Color") { model in
                guard model.palette.colors.indices.contains(index) else { return }
                model.palette.colors[index] = picked
                model.palette.name = "Custom"
            }
            editorState.eyedropperSwatchIndex = (index + 1) % count
        }
    }

    // MARK: - Crop

    /// The crop target: the selected, unrotated image layer, else the canvas.
    private var cropTargetLayer: Layer? {
        guard let layer = document.model.layer(id: editorState.selectedLayerID),
              layer.kind.isImage,
              abs(layer.transform.rotationDegrees).truncatingRemainder(dividingBy: 360) < 0.01 else { return nil }
        return layer
    }

    private func applyCrop() {
        guard let draft = editorState.cropDraft, draft.width > 4, draft.height > 4 else { return }
        if let layer = cropTargetLayer, let config = layer.imageConfig {
            let naturalSize = config.croppedPixelSize
            let layerScale = max(layer.transform.scale, 0.0001)
            let layerRect = CGRect(x: layer.transform.position.x - naturalSize.width * layerScale / 2,
                                   y: layer.transform.position.y - naturalSize.height * layerScale / 2,
                                   width: naturalSize.width * layerScale,
                                   height: naturalSize.height * layerScale)
            let clamped = draft.intersection(layerRect)
            guard clamped.width > 1, clamped.height > 1 else { return }

            let previous = config.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            // Draft in canvas → fraction of the current (cropped) content →
            // unit rect within the original image.
            let fx = (clamped.minX - layerRect.minX) / layerRect.width
            let fy = (clamped.minY - layerRect.minY) / layerRect.height
            let fw = clamped.width / layerRect.width
            let fh = clamped.height / layerRect.height
            let newCrop = CGRect(x: previous.minX + fx * previous.width,
                                 y: previous.minY + fy * previous.height,
                                 width: fw * previous.width,
                                 height: fh * previous.height)
            let center = CGPoint(x: clamped.midX, y: clamped.midY)
            document.update(undoManager, actionName: "Crop Image") { model in
                model.modifyLayer(id: layer.id) { layer in
                    layer.modifyImage { $0.crop = newCrop }
                    layer.transform.position = center
                }
            }
        } else {
            document.cropCanvas(rect: draft, undoManager: undoManager)
        }
        editorState.cropDraft = nil
        editorState.activeTool = .move
    }

    private func cancelCrop() {
        editorState.cropDraft = nil
        editorState.activeTool = .move
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

    private func handleScaleDrag(_ phase: HandleDragPhase, layer: Layer,
                                 parentAffine: CGAffineTransform, canvasTransform: CGAffineTransform) {
        let center = layer.transform.position.applying(parentAffine).applying(canvasTransform)
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
            awaitingTiledHandoff = true
            document.endGesture(undoManager, actionName: "Scale Layer")
            dragMode = nil
        }
    }

    private func handleRotateDrag(_ phase: HandleDragPhase, layer: Layer,
                                  parentAffine: CGAffineTransform, canvasTransform: CGAffineTransform) {
        let center = layer.transform.position.applying(parentAffine).applying(canvasTransform)
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
            awaitingTiledHandoff = true
            document.endGesture(undoManager, actionName: "Rotate Layer")
            dragMode = nil
        }
    }

    private var topmostSelectedIDs: Set<UUID> {
        Set(editorState.selectedLayerIDs.filter { id in
            !document.model.ancestorGroupIDs(of: id).contains(where: editorState.selectedLayerIDs.contains)
        })
    }

    private var multiSelectionBounds: CGRect? {
        let bounds = topmostSelectedIDs.compactMap { id -> CGRect? in
            guard let layer = document.model.layer(id: id),
                  !document.model.isEffectivelyLocked(id) else { return nil }
            return document.worldBounds(of: layer, renderStore: renderStore)
        }
        guard !bounds.isEmpty else { return nil }
        return bounds.reduce(.null) { $0.union($1) }
    }

    private func multiTransformEntries() -> [(id: UUID, world: LayerTransform, parent: CGAffineTransform)] {
        topmostSelectedIDs.compactMap { id in
            guard !document.model.isEffectivelyLocked(id),
                  let world = document.model.worldTransform(of: id) else { return nil }
            return (id, world, document.model.parentAffine(of: id))
        }
    }

    private func handleMultiScaleDrag(_ phase: HandleDragPhase, bounds: CGRect,
                                      canvasTransform: CGAffineTransform) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let screenCenter = center.applying(canvasTransform)
        switch phase {
        case .changed(let value):
            let distance = hypot(value.location.x - screenCenter.x,
                                 value.location.y - screenCenter.y)
            if case .multiScale(let entries, let startCenter, let startDistance) = dragMode {
                let factor = startDistance > 1 ? max(distance / startDistance, 0.02) : 1
                document.updateDuringGesture { model in
                    for entry in entries {
                        var world = entry.world
                        world.position = CGPoint(
                            x: startCenter.x + (world.position.x - startCenter.x) * factor,
                            y: startCenter.y + (world.position.y - startCenter.y) * factor)
                        world.scale = min(max(world.scale * Double(factor), 0.02), 60)
                        if let local = LayerTransform.rebased(world: world,
                                                             destinationParent: entry.parent) {
                            model.modifyLayer(id: entry.id) { $0.transform = local }
                        }
                    }
                }
            } else {
                let startDistance = hypot(value.startLocation.x - screenCenter.x,
                                          value.startLocation.y - screenCenter.y)
                let entries = multiTransformEntries()
                guard !entries.isEmpty else { return }
                document.beginGesture()
                dragMode = .multiScale(entries: entries, center: center,
                                       startDistance: startDistance)
            }
        case .ended:
            awaitingTiledHandoff = true
            document.endGesture(undoManager, actionName: "Scale Layers")
            dragMode = nil
        }
    }

    private func handleMultiRotateDrag(_ phase: HandleDragPhase, bounds: CGRect,
                                       canvasTransform: CGAffineTransform) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let screenCenter = center.applying(canvasTransform)
        switch phase {
        case .changed(let value):
            let currentAngle = atan2(Double(value.location.y - screenCenter.y),
                                     Double(value.location.x - screenCenter.x))
            if case .multiRotate(let entries, let startCenter, let startAngle) = dragMode {
                var delta = (currentAngle - startAngle) * 180 / .pi
                let snapped = (delta / 15).rounded() * 15
                if abs(delta - snapped) < 2.5 { delta = snapped }
                let radians = CGFloat(delta * .pi / 180)
                let rotation = CGAffineTransform(translationX: startCenter.x, y: startCenter.y)
                    .rotated(by: radians)
                    .translatedBy(x: -startCenter.x, y: -startCenter.y)
                document.updateDuringGesture { model in
                    for entry in entries {
                        var world = entry.world
                        world.position = world.position.applying(rotation)
                        world.rotationDegrees += delta
                        if let local = LayerTransform.rebased(world: world,
                                                             destinationParent: entry.parent) {
                            model.modifyLayer(id: entry.id) { $0.transform = local }
                        }
                    }
                }
            } else {
                let startAngle = atan2(Double(value.startLocation.y - screenCenter.y),
                                       Double(value.startLocation.x - screenCenter.x))
                let entries = multiTransformEntries()
                guard !entries.isEmpty else { return }
                document.beginGesture()
                dragMode = .multiRotate(entries: entries, center: center,
                                        startAngle: startAngle)
            }
        case .ended:
            awaitingTiledHandoff = true
            document.endGesture(undoManager, actionName: "Rotate Layers")
            dragMode = nil
        }
    }

    // MARK: - Selection & snapping

    /// Returns the top-level layer under the point. Groups hit when any of
    /// their (recursively transformed) children do, so dragging a group's
    /// artwork moves the whole group.
    private func hitTest(_ canvasPoint: CGPoint) -> Layer? {
        hitTest(canvasPoint, in: document.model.layers)
    }

    private func hitTest(_ point: CGPoint, in layers: [Layer]) -> Layer? {
        for layer in layers.reversed() where layer.isVisible && !layer.isLocked {
            if case .group(let group) = layer.kind {
                let affine = layer.transform.affine(naturalSize: document.model.canvasSize)
                guard affine.isInvertible else { continue }
                if hitTest(point.applying(affine.inverted()), in: group.children) != nil {
                    return layer
                }
            } else {
                let naturalSize = renderStore.naturalSize(for: layer, model: document.model)
                if layer.transform.contains(point, naturalSize: naturalSize) {
                    return layer
                }
            }
        }
        return nil
    }

    private func selectAt(_ canvasPoint: CGPoint) {
        editorState.selectedLayerID = hitTest(canvasPoint)?.id
    }

    private func snapped(_ point: CGPoint, layerID: UUID, tolerance: CGFloat) -> CGPoint {
        guard let layer = document.model.layer(id: layerID) else { return point }
        let parent = document.model.parentAffine(of: layerID)
        let localDelta = CGVector(dx: point.x - layer.transform.position.x,
                                  dy: point.y - layer.transform.position.y)
        let worldDelta = CGVector(dx: localDelta.dx * parent.a + localDelta.dy * parent.c,
                                  dy: localDelta.dx * parent.b + localDelta.dy * parent.d)
        let currentBounds = document.worldBounds(of: layer, renderStore: renderStore)
        let proposed = currentBounds.offsetBy(dx: worldDelta.dx, dy: worldDelta.dy)
        let movingX = [proposed.minX, proposed.midX, proposed.maxX]
        let movingY = [proposed.minY, proposed.midY, proposed.maxY]
        var xTargets: [CGFloat] = []
        var yTargets: [CGFloat] = []
        let workspace = document.model.workspace

        if workspace.smartGuidesEnabled {
            xTargets += [0, document.model.canvasSize.width / 2, document.model.canvasSize.width]
            yTargets += [0, document.model.canvasSize.height / 2, document.model.canvasSize.height]
            for guide in workspace.guides {
                if guide.orientation == .vertical { xTargets.append(guide.position) }
                else { yTargets.append(guide.position) }
            }
            for other in document.model.allLayers where other.id != layerID
                && other.isVisible && !other.kind.isGroup
                && !editorState.selectedLayerIDs.contains(other.id) {
                let bounds = document.worldBounds(of: other, renderStore: renderStore)
                xTargets += [bounds.minX, bounds.midX, bounds.maxX]
                yTargets += [bounds.minY, bounds.midY, bounds.maxY]
            }
        }
        if workspace.grid.snapsToGrid {
            let spacing = max(workspace.grid.spacing / Double(max(workspace.grid.subdivisions, 1)), 1)
            xTargets += movingX.map { ($0 / spacing).rounded() * spacing }
            yTargets += movingY.map { ($0 / spacing).rounded() * spacing }
        }

        let xSnap = bestSnap(anchors: movingX, targets: xTargets, tolerance: tolerance)
        let ySnap = bestSnap(anchors: movingY, targets: yTargets, tolerance: tolerance)
        editorState.smartGuideX = xSnap.map { Double($0.target) }
        editorState.smartGuideY = ySnap.map { Double($0.target) }
        let correction = CGVector(dx: xSnap?.delta ?? 0, dy: ySnap?.delta ?? 0)
        guard parent.isInvertible else { return point }
        let inverse = parent.inverted()
        return CGPoint(x: point.x + correction.dx * inverse.a + correction.dy * inverse.c,
                       y: point.y + correction.dx * inverse.b + correction.dy * inverse.d)
    }

    private func bestSnap(anchors: [CGFloat], targets: [CGFloat], tolerance: CGFloat)
        -> (delta: CGFloat, target: CGFloat)? {
        var best: (delta: CGFloat, target: CGFloat)?
        for anchor in anchors {
            for target in targets {
                let delta = target - anchor
                guard abs(delta) <= tolerance else { continue }
                if best == nil || abs(delta) < abs(best!.delta) { best = (delta, target) }
            }
        }
        return best
    }

    private func nudgeSelection(_ press: KeyPress) -> KeyPress.Result {
        let entries = moveEntries(for: editorState.selectedLayerIDs)
        guard !entries.isEmpty else { return .ignored }
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
            for entry in entries {
                let inverse = entry.parentInverse
                model.modifyLayer(id: entry.id) {
                    $0.transform.position.x += dx * inverse.a + dy * inverse.c
                    $0.transform.position.y += dx * inverse.b + dy * inverse.d
                }
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
    var parentAffine: CGAffineTransform = .identity
    let canvasTransform: CGAffineTransform
    let onScaleDrag: (HandleDragPhase) -> Void
    let onRotateDrag: (HandleDragPhase) -> Void

    var body: some View {
        let corners = layer.transform.corners(naturalSize: naturalSize)
            .map { $0.applying(parentAffine).applying(canvasTransform) }
        let topMid = CGPoint(x: (corners[0].x + corners[1].x) / 2, y: (corners[0].y + corners[1].y) / 2)
        let center = layer.transform.position.applying(parentAffine).applying(canvasTransform)
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

/// Axis-aligned aggregate transform box for multiple selected layers.
struct MultiSelectionOverlay: View {
    let bounds: CGRect
    let canvasTransform: CGAffineTransform
    let onScaleDrag: (HandleDragPhase) -> Void
    let onRotateDrag: (HandleDragPhase) -> Void

    var body: some View {
        let corners = [
            CGPoint(x: bounds.minX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.maxY),
            CGPoint(x: bounds.minX, y: bounds.maxY),
        ].map { $0.applying(canvasTransform) }
        let topMid = CGPoint(x: (corners[0].x + corners[1].x) / 2,
                             y: (corners[0].y + corners[1].y) / 2)
        let rotateHandle = CGPoint(x: topMid.x, y: topMid.y - 24)

        ZStack {
            Path { path in
                path.move(to: corners[0])
                for corner in corners.dropFirst() { path.addLine(to: corner) }
                path.closeSubpath()
                path.move(to: topMid)
                path.addLine(to: rotateHandle)
            }
            .stroke(Color.accentColor.opacity(0.9), lineWidth: 1)
            .allowsHitTesting(false)

            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(Color.white)
                    .stroke(Color.accentColor, lineWidth: 1.5)
                    .frame(width: 10, height: 10)
                    .position(corners[index])
                    .gesture(DragGesture(coordinateSpace: .named("multi-overlay"))
                        .onChanged { onScaleDrag(.changed($0)) }
                        .onEnded { _ in onScaleDrag(.ended) })
            }

            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.accentColor))
                .position(rotateHandle)
                .gesture(DragGesture(coordinateSpace: .named("multi-overlay"))
                    .onChanged { onRotateDrag(.changed($0)) }
                    .onEnded { _ in onRotateDrag(.ended) })
        }
        .coordinateSpace(name: "multi-overlay")
    }
}

private struct PathNodeOverlay: View {
    @ObservedObject var document: PixelDocument
    let layer: Layer
    let config: PathConfig
    let canvasTransform: CGAffineTransform
    let parentAffine: CGAffineTransform
    @Environment(\.undoManager) private var undoManager

    private var fullTransform: CGAffineTransform {
        layer.transform.affine(naturalSize: config.size)
            .concatenating(parentAffine)
            .concatenating(canvasTransform)
    }

    var body: some View {
        ZStack {
            Canvas { context, _ in
                var handles = Path()
                for node in config.nodes {
                    let anchor = node.anchor.applying(fullTransform)
                    let incoming = node.inControl.applying(fullTransform)
                    let outgoing = node.outControl.applying(fullTransform)
                    handles.move(to: incoming); handles.addLine(to: anchor); handles.addLine(to: outgoing)
                }
                context.stroke(handles, with: .color(.accentColor.opacity(0.65)), lineWidth: 1)
            }
            .allowsHitTesting(false)

            ForEach(config.nodes) { node in
                nodeHandle(node.anchor, size: 11, filled: true)
                    .gesture(nodeGesture(nodeID: node.id, kind: .anchor))
                nodeHandle(node.inControl, size: 8, filled: false)
                    .gesture(nodeGesture(nodeID: node.id, kind: .incoming))
                nodeHandle(node.outControl, size: 8, filled: false)
                    .gesture(nodeGesture(nodeID: node.id, kind: .outgoing))
            }
        }
        .coordinateSpace(name: "path-nodes")
    }

    private enum HandleKind { case anchor, incoming, outgoing }

    private func nodeHandle(_ point: CGPoint, size: CGFloat, filled: Bool) -> some View {
        Circle()
            .fill(filled ? Color.accentColor : Color.white)
            .stroke(Color.accentColor, lineWidth: 1.5)
            .frame(width: size, height: size)
            .position(point.applying(fullTransform))
    }

    private func nodeGesture(nodeID: UUID, kind: HandleKind) -> some Gesture {
        DragGesture(coordinateSpace: .named("path-nodes"))
            .onChanged { value in
                guard fullTransform.isInvertible else { return }
                document.beginGesture()
                let local = value.location.applying(fullTransform.inverted())
                document.updateDuringGesture { model in
                    model.modifyLayer(id: layer.id) { layer in
                        layer.modifyPath { path in
                            guard let index = path.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
                            switch kind {
                            case .anchor:
                                let delta = CGVector(dx: local.x - path.nodes[index].anchor.x,
                                                     dy: local.y - path.nodes[index].anchor.y)
                                path.nodes[index].anchor = local
                                path.nodes[index].inControl.x += delta.dx
                                path.nodes[index].inControl.y += delta.dy
                                path.nodes[index].outControl.x += delta.dx
                                path.nodes[index].outControl.y += delta.dy
                            case .incoming:
                                path.nodes[index].inControl = local
                            case .outgoing:
                                path.nodes[index].outControl = local
                            }
                        }
                    }
                }
            }
            .onEnded { _ in document.endGesture(undoManager, actionName: "Edit Path Node") }
    }
}

/// Non-destructive workspace chrome: grid, persisted guides, transient smart
/// guides, and fixed rulers that can be dragged to create new guides.
private struct WorkspaceOverlay: View {
    @ObservedObject var document: PixelDocument
    @Bindable var editorState: EditorState
    let canvasTransform: CGAffineTransform
    let scale: CGFloat
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                let canvas = document.model.canvasSize
                let rect = CGRect(origin: .zero, size: canvas).applying(canvasTransform)
                if document.model.workspace.grid.isVisible {
                    let grid = document.model.workspace.grid
                    let step = max(grid.spacing / Double(max(grid.subdivisions, 1)), 1)
                    if step * scale >= 4 {
                        var minor = Path()
                        var x = 0.0
                        var count = 0
                        while x <= canvas.width && count < 1000 {
                            let sx = CGPoint(x: x, y: 0).applying(canvasTransform).x
                            minor.move(to: CGPoint(x: sx, y: rect.minY))
                            minor.addLine(to: CGPoint(x: sx, y: rect.maxY))
                            x += step; count += 1
                        }
                        var y = 0.0; count = 0
                        while y <= canvas.height && count < 1000 {
                            let sy = CGPoint(x: 0, y: y).applying(canvasTransform).y
                            minor.move(to: CGPoint(x: rect.minX, y: sy))
                            minor.addLine(to: CGPoint(x: rect.maxX, y: sy))
                            y += step; count += 1
                        }
                        context.stroke(minor, with: .color(.primary.opacity(0.13)), lineWidth: 0.5)
                    }
                }

                var guidePath = Path()
                for guide in document.model.workspace.guides {
                    if guide.orientation == .vertical {
                        let x = CGPoint(x: guide.position, y: 0).applying(canvasTransform).x
                        guidePath.move(to: CGPoint(x: x, y: rect.minY))
                        guidePath.addLine(to: CGPoint(x: x, y: rect.maxY))
                    } else {
                        let y = CGPoint(x: 0, y: guide.position).applying(canvasTransform).y
                        guidePath.move(to: CGPoint(x: rect.minX, y: y))
                        guidePath.addLine(to: CGPoint(x: rect.maxX, y: y))
                    }
                }
                context.stroke(guidePath, with: .color(.blue.opacity(0.8)), lineWidth: 1)

                var smart = Path()
                if let x = editorState.smartGuideX {
                    let sx = CGPoint(x: x, y: 0).applying(canvasTransform).x
                    smart.move(to: CGPoint(x: sx, y: rect.minY))
                    smart.addLine(to: CGPoint(x: sx, y: rect.maxY))
                }
                if let y = editorState.smartGuideY {
                    let sy = CGPoint(x: 0, y: y).applying(canvasTransform).y
                    smart.move(to: CGPoint(x: rect.minX, y: sy))
                    smart.addLine(to: CGPoint(x: rect.maxX, y: sy))
                }
                context.stroke(smart, with: .color(.orange),
                               style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .allowsHitTesting(false)

            if document.model.workspace.showsRulers {
                rulerBars
            }
        }
    }

    private var rulerBars: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: 22)),
                             with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.94)))
                context.fill(Path(CGRect(x: 0, y: 0, width: 22, height: size.height)),
                             with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.94)))
                let step = niceRulerStep
                let inverse = canvasTransform.inverted()
                let minX = CGPoint(x: 22, y: 22).applying(inverse).x
                let maxX = CGPoint(x: size.width, y: 22).applying(inverse).x
                var x = floor(minX / step) * step
                while x <= maxX {
                    let screen = CGPoint(x: x, y: 0).applying(canvasTransform).x
                    var tick = Path()
                    tick.move(to: CGPoint(x: screen, y: 14)); tick.addLine(to: CGPoint(x: screen, y: 22))
                    context.stroke(tick, with: .color(.secondary), lineWidth: 0.5)
                    context.draw(Text("\(Int(x))").font(.system(size: 8)).foregroundStyle(.secondary),
                                 at: CGPoint(x: screen + 3, y: 7), anchor: .leading)
                    x += step
                }
                let minY = CGPoint(x: 22, y: 22).applying(inverse).y
                let maxY = CGPoint(x: 22, y: size.height).applying(inverse).y
                var y = floor(minY / step) * step
                while y <= maxY {
                    let screen = CGPoint(x: 0, y: y).applying(canvasTransform).y
                    var tick = Path()
                    tick.move(to: CGPoint(x: 14, y: screen)); tick.addLine(to: CGPoint(x: 22, y: screen))
                    context.stroke(tick, with: .color(.secondary), lineWidth: 0.5)
                    y += step
                }
            }
            .allowsHitTesting(false)

            Color.clear.frame(height: 22)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2).onEnded { value in
                    let canvasPoint = CGPoint(x: value.location.x, y: 22).applying(canvasTransform.inverted())
                    addGuide(.vertical, position: canvasPoint.x)
                })
            Color.clear.frame(width: 22)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2).onEnded { value in
                    let canvasPoint = CGPoint(x: 22, y: value.location.y).applying(canvasTransform.inverted())
                    addGuide(.horizontal, position: canvasPoint.y)
                })
        }
    }

    private var niceRulerStep: CGFloat {
        let desired = 80 / max(scale, 0.0001)
        let magnitude = pow(10, floor(log10(desired)))
        let normalized = desired / magnitude
        let factor: CGFloat = normalized < 2 ? 2 : (normalized < 5 ? 5 : 10)
        return factor * magnitude
    }

    private func addGuide(_ orientation: GuideOrientation, position: CGFloat) {
        let maximum = orientation == .vertical
            ? document.model.canvasSize.width : document.model.canvasSize.height
        guard position >= 0, position <= maximum else { return }
        document.update(undoManager, actionName: "Add Guide") {
            $0.workspace.guides.append(CanvasGuide(orientation: orientation, position: position))
        }
    }
}

private struct NavigatorView: View {
    @ObservedObject var document: PixelDocument
    @ObservedObject var renderStore: RenderStore
    let canvasTransform: CGAffineTransform
    let viewportSize: CGSize
    let zoomScale: CGFloat
    @Binding var pan: CGSize
    @State private var preview: CGImage?
    @State private var isHovering = false
    @State private var refreshTask: Task<Void, Never>?
    @Environment(\.undoManager) private var undoManager

    private var previewSize: CGSize {
        let canvas = document.model.canvasSize
        let ratio = canvas.width / max(canvas.height, 1)
        return ratio >= 1
            ? CGSize(width: 160, height: max(44, 160 / ratio))
            : CGSize(width: max(44, 160 * ratio), height: 160)
    }

    var body: some View {
        VStack {
            Spacer()
            HStack {
                GeometryReader { geometry in
                    ZStack {
                        if let preview {
                            Image(decorative: preview, scale: 1)
                                .resizable()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                        }
                        Path { path in path.addRect(viewportRect(in: geometry.size)) }
                            .stroke(Color.accentColor, lineWidth: 1.5)

                        VStack {
                            HStack {
                                Spacer()
                                Button {
                                    document.update(undoManager, actionName: "Hide Navigator") {
                                        $0.workspace.showsNavigator = false
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.hierarchical)
                                }
                                .buttonStyle(.plain)
                                .help("Hide navigator")
                            }
                            Spacer()
                        }
                        .padding(5)
                        .opacity(isHovering ? 1 : 0)
                        .allowsHitTesting(isHovering)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        centerViewport(on: value.location, miniSize: geometry.size)
                    })
                }
                .frame(width: previewSize.width, height: previewSize.height)
                .background(Color.black.opacity(0.35))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .onHover { isHovering = $0 }
                .animation(.easeInOut(duration: 0.15), value: isHovering)
                .padding(.leading, document.model.workspace.showsRulers ? 30 : 12)
                .padding(.bottom, 12)
                Spacer()
            }
        }
        .onAppear { refreshPreview() }
        .onChange(of: renderStore.viewportInvalidation.revision) { _, _ in
            refreshTask?.cancel()
            refreshTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                refreshPreview()
            }
        }
        .onDisappear { refreshTask?.cancel() }
    }

    private func refreshPreview() {
        let items = renderStore.renderItems(model: document.model, quality: .proxy)
        preview = PNGExporter.render(items: items, background: document.model.background,
                                     canvasSize: document.model.canvasSize,
                                     targetPixelSize: previewSize,
                                     colorSettings: document.model.colorSettings.previewVariant)
    }

    private func viewportRect(in mini: CGSize) -> CGRect {
        guard canvasTransform.isInvertible else { return .zero }
        let inverse = canvasTransform.inverted()
        let visible = CGRect(x: 0, y: 0, width: viewportSize.width, height: viewportSize.height)
            .applying(inverse)
            .intersection(CGRect(origin: .zero, size: document.model.canvasSize))
        let sx = mini.width / document.model.canvasSize.width
        let sy = mini.height / document.model.canvasSize.height
        return CGRect(x: visible.minX * sx, y: visible.minY * sy,
                      width: visible.width * sx, height: visible.height * sy)
    }

    private func centerViewport(on point: CGPoint, miniSize: CGSize) {
        let canvas = document.model.canvasSize
        let canvasPoint = CGPoint(x: point.x / miniSize.width * canvas.width,
                                  y: point.y / miniSize.height * canvas.height)
        pan = CGSize(width: zoomScale * (canvas.width / 2 - canvasPoint.x),
                     height: zoomScale * (canvas.height / 2 - canvasPoint.y))
    }
}

/// Transparent AppKit event bridge. It does not steal hit testing from the
/// SwiftUI tool overlays; local monitors are filtered to this view's window
/// and bounds and provide pressure, tilt, timestamps, and precise scrolling.
private struct PointerEventBridge: NSViewRepresentable {
    let onPointer: (PointerSample) -> Void
    let onScroll: (CGFloat, CGFloat, CGPoint, NSEvent.ModifierFlags) -> Void

    final class EventView: NSView {
        override var isFlipped: Bool { true }
    }

    final class Coordinator {
        var onPointer: (PointerSample) -> Void
        var onScroll: (CGFloat, CGFloat, CGPoint, NSEvent.ModifierFlags) -> Void
        weak var view: NSView?
        var pointerMonitor: Any?
        var scrollMonitor: Any?

        init(onPointer: @escaping (PointerSample) -> Void,
             onScroll: @escaping (CGFloat, CGFloat, CGPoint, NSEvent.ModifierFlags) -> Void) {
            self.onPointer = onPointer
            self.onScroll = onScroll
        }

        func attach(to view: NSView) {
            self.view = view
            pointerMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged, .tabletPoint, .pressure]) { [weak self] event in
                guard let self, let view = self.view,
                      event.window === view.window else { return event }
                let location = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(location) else { return event }
                let pressure = event.pressure > 0 ? Double(event.pressure) : 1
                let tilt = event.type == .tabletPoint
                    ? CGSize(width: event.tilt.x, height: event.tilt.y) : .zero
                self.onPointer(PointerSample(location: location, pressure: pressure,
                                             tilt: tilt, timestamp: event.timestamp))
                return event
            }
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let view = self.view,
                      event.window === view.window else { return event }
                let location = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(location) else { return event }
                self.onScroll(event.scrollingDeltaX, event.scrollingDeltaY, location,
                              event.modifierFlags.union(NSEvent.modifierFlags))
                return nil
            }
        }

        func detach() {
            if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            pointerMonitor = nil
            scrollMonitor = nil
        }

    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPointer: onPointer, onScroll: onScroll)
    }

    func makeNSView(context: Context) -> NSView {
        let view = EventView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onPointer = onPointer
        context.coordinator.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }
}
