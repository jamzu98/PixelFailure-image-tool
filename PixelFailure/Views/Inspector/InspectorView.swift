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
                if let layer = document.model.layer(id: editorState.selectedLayerID) {
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
