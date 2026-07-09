import SwiftUI

/// Right sidebar: settings for the selected layer (or the canvas when nothing
/// is selected) plus the palette panel.
struct InspectorView: View {
    @ObservedObject var document: PixelDocument
    @Bindable var editorState: EditorState
    let renderStore: RenderStore
    @Environment(\.undoManager) private var undoManager
    @State private var draftWidth: Int = 0
    @State private var draftHeight: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if editorState.selectedLayerIDs.count > 1 {
                    multiSelectionSection
                } else if let layer = document.model.layer(id: editorState.selectedLayerID) {
                    commonSection(layer)
                    maskSection(layer)
                    switch layer.kind {
                    case .pattern(let config):
                        PatternInspector(document: document, layerID: layer.id, config: config)
                    case .image(let config):
                        ImageInspector(document: document, layerID: layer.id, config: config)
                    case .text(let config):
                        TextInspector(document: document, layerID: layer.id, config: config)
                    case .fill(let config):
                        FillInspector(document: document, layerID: layer.id, config: config)
                    case .shape(let config):
                        ShapeInspector(document: document, layerID: layer.id, config: config)
                    case .group(let config):
                        Section("Group") {
                            Text("\(config.children.count) layer\(config.children.count == 1 ? "" : "s") inside")
                                .foregroundStyle(.secondary)
                            Text("Opacity, blend mode, transform, and mask apply to the whole group. Ungroup with ⇧⌘G.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    canvasSection
                }
            }
            .formStyle(.grouped)

            Divider()

            PalettePanel(document: document, editorState: editorState, renderStore: renderStore)
        }
    }

    // MARK: - Common layer controls

    @ViewBuilder
    private func commonSection(_ layer: Layer) -> some View {
        Section("Layer") {
            LabeledContent("Opacity") {
                Slider(value: Binding(
                    get: { document.model.layer(id: layer.id)?.opacity ?? 1 },
                    set: { newValue in
                        document.updateDuringGesture { model in
                            model.modifyLayer(id: layer.id) { $0.opacity = newValue }
                        }
                    }
                ), in: 0...1) { editing in
                    if editing { document.beginGesture() } else { document.endGesture(undoManager, actionName: "Opacity") }
                }
            }

            Picker("Blend Mode", selection: Binding(
                get: { document.model.layer(id: layer.id)?.blendMode ?? .normal },
                set: { newValue in
                    document.update(undoManager, actionName: "Blend Mode") { model in
                        model.modifyLayer(id: layer.id) { $0.blendMode = newValue }
                    }
                }
            )) {
                ForEach(LayerBlendMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            if layer.isLocked {
                Label("Layer is locked — transform and painting are disabled.", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Numeric transform: position and on-canvas size (size edits scale).
            LabeledContent("Position") {
                HStack(spacing: 4) {
                    numericField("X", value: Binding(
                        get: { Double(document.model.layer(id: layer.id)?.transform.position.x ?? 0) },
                        set: { newValue in
                            document.update(undoManager, actionName: "Position") { model in
                                model.modifyLayer(id: layer.id) { $0.transform.position.x = newValue }
                            }
                        }))
                    numericField("Y", value: Binding(
                        get: { Double(document.model.layer(id: layer.id)?.transform.position.y ?? 0) },
                        set: { newValue in
                            document.update(undoManager, actionName: "Position") { model in
                                model.modifyLayer(id: layer.id) { $0.transform.position.y = newValue }
                            }
                        }))
                }
            }

            LabeledContent("Size") {
                let naturalSize = renderStore.naturalSize(for: layer, model: document.model)
                HStack(spacing: 4) {
                    numericField("W", value: Binding(
                        get: {
                            let current = document.model.layer(id: layer.id) ?? layer
                            return Double(naturalSize.width) * current.transform.scale
                        },
                        set: { newValue in
                            guard naturalSize.width > 0, newValue > 1 else { return }
                            document.update(undoManager, actionName: "Resize") { model in
                                model.modifyLayer(id: layer.id) {
                                    $0.transform.scale = newValue / Double(naturalSize.width)
                                }
                            }
                        }))
                    numericField("H", value: Binding(
                        get: {
                            let current = document.model.layer(id: layer.id) ?? layer
                            return Double(naturalSize.height) * current.transform.scale
                        },
                        set: { newValue in
                            guard naturalSize.height > 0, newValue > 1 else { return }
                            document.update(undoManager, actionName: "Resize") { model in
                                model.modifyLayer(id: layer.id) {
                                    $0.transform.scale = newValue / Double(naturalSize.height)
                                }
                            }
                        }))
                }
            }

            LabeledContent("Scale") {
                Slider(value: Binding(
                    get: { log2(document.model.layer(id: layer.id)?.transform.scale ?? 1) },
                    set: { newValue in
                        document.updateDuringGesture { model in
                            model.modifyLayer(id: layer.id) { $0.transform.scale = pow(2, newValue) }
                        }
                    }
                ), in: -4...4) { editing in
                    if editing { document.beginGesture() } else { document.endGesture(undoManager, actionName: "Scale") }
                }
            }

            LabeledContent("Rotation") {
                Slider(value: Binding(
                    get: { document.model.layer(id: layer.id)?.transform.rotationDegrees ?? 0 },
                    set: { newValue in
                        document.updateDuringGesture { model in
                            model.modifyLayer(id: layer.id) { $0.transform.rotationDegrees = newValue }
                        }
                    }
                ), in: -180...180) { editing in
                    if editing { document.beginGesture() } else { document.endGesture(undoManager, actionName: "Rotation") }
                }
            }

            HStack {
                Button("Center") {
                    document.update(undoManager, actionName: "Center Layer") { model in
                        let center = model.canvasCenter
                        model.modifyLayer(id: layer.id) { $0.transform.position = center }
                    }
                }
                Button("Reset") {
                    document.update(undoManager, actionName: "Reset Transform") { model in
                        let center = model.canvasCenter
                        model.modifyLayer(id: layer.id) {
                            $0.transform = LayerTransform(position: center)
                        }
                    }
                }
                Button("Flip H") {
                    document.flipLayer(id: layer.id, horizontally: true, undoManager: undoManager)
                }
                Button("Flip V") {
                    document.flipLayer(id: layer.id, horizontally: false, undoManager: undoManager)
                }
            }
        }
        .disabled(layer.isLocked)
    }

    // MARK: - Multiple selection

    @ViewBuilder
    private var multiSelectionSection: some View {
        Section("\(editorState.selectedLayerIDs.count) Layers Selected") {
            Button("Group Layers  ⌘G") {
                if let id = document.groupLayers(ids: editorState.selectedLayerIDs, undoManager: undoManager) {
                    editorState.selectedLayerID = id
                }
            }
        }

        Section("Align") {
            HStack {
                ForEach([PixelDocument.AlignEdge.left, .centerH, .right], id: \.self) { edge in
                    alignButton(edge)
                }
            }
            HStack {
                ForEach([PixelDocument.AlignEdge.top, .centerV, .bottom], id: \.self) { edge in
                    alignButton(edge)
                }
            }
        }

        Section("Distribute") {
            HStack {
                Button("Horizontally") {
                    document.distributeLayers(ids: editorState.selectedLayerIDs, horizontally: true,
                                              renderStore: renderStore, undoManager: undoManager)
                }
                Button("Vertically") {
                    document.distributeLayers(ids: editorState.selectedLayerIDs, horizontally: false,
                                              renderStore: renderStore, undoManager: undoManager)
                }
            }
            .disabled(editorState.selectedLayerIDs.count < 3)
            if editorState.selectedLayerIDs.count < 3 {
                Text("Select three or more layers to distribute.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func numericField(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField(label, value: value, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 62)
        }
    }

    private func alignButton(_ edge: PixelDocument.AlignEdge) -> some View {
        Button(edge.displayName) {
            document.alignLayers(ids: editorState.selectedLayerIDs, edge: edge,
                                 renderStore: renderStore, undoManager: undoManager)
        }
    }

    // MARK: - Mask

    @ViewBuilder
    private func maskSection(_ layer: Layer) -> some View {
        Section("Mask") {
            if let mask = layer.mask {
                Toggle("Enabled", isOn: Binding(
                    get: { mask.isEnabled },
                    set: { newValue in
                        document.update(undoManager, actionName: "Toggle Mask") { model in
                            model.modifyLayer(id: layer.id) { $0.mask?.isEnabled = newValue }
                        }
                    }
                ))
                Toggle("Invert", isOn: Binding(
                    get: { mask.inverted },
                    set: { newValue in
                        document.update(undoManager, actionName: "Invert Mask") { model in
                            model.modifyLayer(id: layer.id) { $0.mask?.inverted = newValue }
                        }
                    }
                ))
                let isEditing = editorState.editingMaskLayerID == layer.id
                Button(isEditing ? "Done Editing Mask" : "Edit Mask (Paint)") {
                    if isEditing {
                        editorState.editingMaskLayerID = nil
                        editorState.activeTool = .move
                    } else {
                        editorState.editingMaskLayerID = layer.id
                        editorState.activeTool = .brush
                    }
                }
                Button("Delete Mask", role: .destructive) {
                    if editorState.editingMaskLayerID == layer.id {
                        editorState.editingMaskLayerID = nil
                    }
                    document.deleteMask(from: layer.id, undoManager: undoManager)
                }
            } else {
                HStack {
                    Button("Add Mask") {
                        document.addMask(to: layer.id, hideAll: false, renderStore: renderStore, undoManager: undoManager)
                    }
                    Button("Add Hiding Mask") {
                        document.addMask(to: layer.id, hideAll: true, renderStore: renderStore, undoManager: undoManager)
                    }
                }
                Text("Masks hide parts of the layer: paint black to hide, white to reveal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Canvas (no selection)

    @ViewBuilder
    private var canvasSection: some View {
        Section("Canvas") {
            LabeledContent("Size") {
                HStack(spacing: 4) {
                    TextField("W", value: $draftWidth, format: .number.grouping(.never))
                        .frame(width: 64)
                        .multilineTextAlignment(.trailing)
                    Text("×")
                    TextField("H", value: $draftHeight, format: .number.grouping(.never))
                        .frame(width: 64)
                        .multilineTextAlignment(.trailing)
                    Text("px")
                        .foregroundStyle(.secondary)
                }
                .textFieldStyle(.roundedBorder)
            }

            if draftSizeDiffers {
                Button("Apply Size") { applyDraftSize() }
                    .keyboardShortcut(.defaultAction)
            }

            ColorPicker("Background", selection: Binding(
                get: { document.model.background.color },
                set: { newValue in
                    document.update(undoManager, actionName: "Background Color") { model in
                        model.background = RGBAColor(colorValue: newValue)
                    }
                }
            ))
            Text("Type any resolution above, or pick a preset from the toolbar. Select a layer to edit its settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { syncDraftSize() }
        .onChange(of: document.model.canvasSize) { _, _ in syncDraftSize() }

        EffectStackSection(document: document,
                           title: "Canvas Effects",
                           target: .canvas,
                           effects: document.model.canvasEffects,
                           footnote: "Applied to the whole composite. Affects PNG export and the preview; SVG export skips them.")
    }

    private var draftSizeDiffers: Bool {
        draftWidth != Int(document.model.canvasSize.width) || draftHeight != Int(document.model.canvasSize.height)
    }

    private func syncDraftSize() {
        draftWidth = Int(document.model.canvasSize.width)
        draftHeight = Int(document.model.canvasSize.height)
    }

    private func applyDraftSize() {
        let width = min(max(draftWidth, 16), 20000)
        let height = min(max(draftHeight, 16), 20000)
        draftWidth = width
        draftHeight = height
        document.setCanvasSize(CGSize(width: width, height: height), undoManager: undoManager)
    }
}
