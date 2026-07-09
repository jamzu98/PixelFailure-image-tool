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
    @State private var hoverLocation: CGPoint = .zero
    @State private var paintSession: PaintSession?
    /// Bumped per stamp so the body re-renders during a stroke.
    @State private var paintTick = 0
    @FocusState private var isFocused: Bool

    private enum DragMode {
        case pan(startPan: CGSize)
        case move(layerID: UUID, startPosition: CGPoint)
        case scale(layerID: UUID, startScale: Double, startDistance: CGFloat)
        case rotate(layerID: UUID, startRotation: Double, startAngle: Double)
        case paint
    }

    var body: some View {
        GeometryReader { geo in
            let viewSize = geo.size
            let scale = effectiveZoom(viewSize: viewSize)
            let canvasTransform = self.canvasTransform(viewSize: viewSize, scale: scale)
            let _ = paintTick
            let items = renderStore.renderItems(model: document.model, quality: .preview)
            let composite = renderStore.compositePreview(model: document.model, extraHash: paintTick)

            ZStack {
                Color(nsColor: .underPageBackgroundColor)

                Canvas { context, _ in
                    context.concatenate(canvasTransform)
                    let canvasRect = CGRect(origin: .zero, size: document.model.canvasSize)
                    if let composite {
                        // Global adjustment preview: draw the flattened,
                        // effect-processed composite instead of live vectors.
                        var clipped = context
                        clipped.clip(to: Path(canvasRect))
                        clipped.draw(Image(decorative: composite, scale: 1), in: canvasRect)
                    } else {
                        CanvasRenderer.draw(items: items,
                                            background: document.model.background,
                                            canvasSize: document.model.canvasSize,
                                            in: context)
                    }
                }
                .allowsHitTesting(false)

                if editorState.activeTool == .move,
                   let layer = document.model.layer(id: editorState.selectedLayerID) {
                    SelectionOverlay(layer: layer,
                                     naturalSize: renderStore.naturalSize(for: layer, model: document.model),
                                     canvasTransform: canvasTransform,
                                     onScaleDrag: { phase in handleScaleDrag(phase, layer: layer, canvasTransform: canvasTransform) },
                                     onRotateDrag: { phase in handleRotateDrag(phase, layer: layer, canvasTransform: canvasTransform) })
                }

                if editorState.activeTool == .crop {
                    CropOverlay(document: document,
                                editorState: editorState,
                                renderStore: renderStore,
                                canvasTransform: canvasTransform,
                                onApply: { applyCrop() },
                                onCancel: { cancelCrop() })
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
                guard editorState.activeTool == .move, let id = editorState.selectedLayerID else { return .ignored }
                document.deleteLayer(id: id, undoManager: undoManager)
                editorState.selectedLayerID = nil
                return .handled
            }
            .onKeyPress(.escape) {
                if editorState.activeTool == .crop {
                    cancelCrop()
                    return .handled
                }
                if editorState.editingMaskLayerID != nil {
                    editorState.editingMaskLayerID = nil
                    editorState.activeTool = .move
                    return .handled
                }
                guard editorState.selectedLayerID != nil else { return .ignored }
                editorState.selectedLayerID = nil
                return .handled
            }
            .onKeyPress(.return) {
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
                    setCursor(cursor(at: location, canvasTransform: canvasTransform, scale: scale))
                case .ended:
                    setCursor(.arrow)
                }
            }
            .onChange(of: editorState.activeTool) { _, _ in
                // Tool switched by shortcut while hovering: update immediately
                // instead of waiting for the next mouse move.
                setCursor(cursor(at: hoverLocation, canvasTransform: canvasTransform, scale: scale))
            }
            .contextMenu {
                contextMenuContent(canvasTransform: canvasTransform)
            }
            .copyable(copyableItems())
            .cuttable(for: LayerTransfer.self) {
                guard let id = editorState.selectedLayerID,
                      let payload = document.transferPayload(for: id) else { return [] }
                document.deleteLayer(id: id, undoManager: undoManager)
                editorState.selectedLayerID = nil
                return [payload]
            }
            .pasteDestination(for: LayerTransfer.self) { items in
                for item in items {
                    editorState.selectedLayerID = document.pasteLayer(item, undoManager: undoManager)
                }
            }
        }
        .clipped()
    }

    // MARK: - Copy / paste / context menu

    private func copyableItems() -> [LayerTransfer] {
        guard let id = editorState.selectedLayerID,
              let payload = document.transferPayload(for: id) else { return [] }
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
                    document.copyLayer(id: layer.id)
                }
                Button("Cut") {
                    document.cutLayer(id: layer.id, undoManager: undoManager)
                    if editorState.selectedLayerID == layer.id { editorState.selectedLayerID = nil }
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
            if let transfer = LayerPasteboard.read() {
                editorState.selectedLayerID = document.pasteLayer(transfer, undoManager: undoManager)
            }
        }
        .disabled(!LayerPasteboard.hasLayer)

        if let layer = target {
            Divider()
            Menu("Arrange") {
                Button("Bring to Front") { document.reorderLayer(id: layer.id, offset: .max, undoManager: undoManager) }
                Button("Bring Forward") { document.reorderLayer(id: layer.id, offset: 1, undoManager: undoManager) }
                Button("Send Backward") { document.reorderLayer(id: layer.id, offset: -1, undoManager: undoManager) }
                Button("Send to Back") { document.reorderLayer(id: layer.id, offset: .min, undoManager: undoManager) }
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
                    switch editorState.activeTool {
                    case .brush, .eraser:
                        dragMode = .paint
                        startPaintSession()
                    case .hand, .zoom, .eyedropper, .crop:
                        dragMode = .pan(startPan: pan)
                    case .move:
                        let canvasPoint = value.startLocation.applying(canvasTransform.inverted())
                        if let hit = hitTest(canvasPoint) {
                            editorState.selectedLayerID = hit.id
                            document.beginGesture()
                            dragMode = .move(layerID: hit.id, startPosition: hit.transform.position)
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
                case .move(let layerID, let startPosition):
                    var newPosition = CGPoint(x: startPosition.x + value.translation.width / scale,
                                              y: startPosition.y + value.translation.height / scale)
                    newPosition = snapped(newPosition, tolerance: 8 / scale)
                    document.updateDuringGesture { model in
                        model.modifyLayer(id: layerID) { $0.transform.position = newPosition }
                    }
                case .paint:
                    extendPaintStroke(to: value.location, canvasTransform: canvasTransform)
                default:
                    break
                }
            }
            .onEnded { value in
                switch dragMode {
                case .move:
                    document.endGesture(undoManager, actionName: "Move Layer")
                case .paint:
                    commitPaintSession()
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
        case .brush, .eraser:
            return Cursors.brush(diameter: editorState.brush.size * scale)
        case .crop:
            return cropCursor(at: location, canvasTransform: canvasTransform)
        case .move:
            return moveCursor(at: location, canvasTransform: canvasTransform)
        }
    }

    private func moveCursor(at location: CGPoint, canvasTransform: CGAffineTransform) -> NSCursor {
        guard let layer = document.model.layer(id: editorState.selectedLayerID) else { return .arrow }
        let naturalSize = renderStore.naturalSize(for: layer, model: document.model)
        let corners = layer.transform.corners(naturalSize: naturalSize).map { $0.applying(canvasTransform) }

        for (index, corner) in corners.enumerated() where hypot(location.x - corner.x, location.y - corner.y) < 9 {
            return Cursors.resizeCorner(index)
        }

        // Rotation handle: 24pt out from the top edge's midpoint.
        let topMid = CGPoint(x: (corners[0].x + corners[1].x) / 2, y: (corners[0].y + corners[1].y) / 2)
        let center = layer.transform.position.applying(canvasTransform)
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
        case .brush, .eraser:
            // A click without a drag is a single dab.
            startPaintSession()
            extendPaintStroke(to: location, canvasTransform: canvasTransform)
            commitPaintSession()
        case .hand, .crop:
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
           let mask = layer.mask {
            let base = renderStore.originalImage(key: mask.imageKey)
            paintSession = PaintSession(target: .mask(layerID: maskID), base: base, pixelSize: mask.pixelSize)
        } else {
            var targetID = editorState.selectedLayerID
            let isImage = document.model.layer(id: targetID ?? UUID())?.kind.isImage ?? false
            if !isImage {
                targetID = document.addPaintLayer(undoManager: undoManager)
                editorState.selectedLayerID = targetID
            }
            guard let id = targetID,
                  let layer = document.model.layer(id: id),
                  let config = layer.imageConfig else { return }
            let base = renderStore.originalImage(key: config.imageKey)
            paintSession = PaintSession(target: .content(layerID: id), base: base, pixelSize: config.pixelSize)
        }
        renderStore.activePaintSession = paintSession
    }

    private func extendPaintStroke(to viewPoint: CGPoint, canvasTransform: CGAffineTransform) {
        guard let session = paintSession,
              let layer = document.model.layer(id: session.targetLayerID) else { return }
        let naturalSize = renderStore.naturalSize(for: layer, model: document.model)
        let affine = layer.transform.affine(naturalSize: naturalSize)
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

        let radius = brush.size / 2 / layerScale * bufferPerLocal
        session.stroke(to: bufferPoint,
                       radius: radius,
                       hardness: brush.hardness,
                       opacity: brush.opacity,
                       color: color,
                       erase: erase && !session.isMask)
        paintTick += 1
    }

    private func commitPaintSession() {
        guard let session = paintSession else { return }
        session.endStroke()
        defer {
            paintSession = nil
            renderStore.activePaintSession = nil
            paintTick += 1
        }
        guard let image = session.currentImage,
              let data = PNGExporter.pngData(image) else { return }
        let key = document.storeImage(data: data, fileExtension: "png")
        switch session.target {
        case .content(let id):
            document.update(undoManager, actionName: "Paint") { model in
                model.modifyLayer(id: id) { layer in
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
                                            targetPixelSize: target) else { return }
        if !model.canvasEffects.isEmpty {
            flat = EffectPipeline.shared.apply(effects: model.canvasEffects, to: flat, palette: model.palette)
        }
        guard let sampler = ImageSampler(cgImage: flat, maxDimension: Int(maxDim)) else { return }
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
