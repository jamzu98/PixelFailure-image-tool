import SwiftUI

/// Right sidebar: settings for the selected layer (or the canvas when nothing
/// is selected) plus the palette panel.
struct InspectorView: View {
    @ObservedObject var document: PixelDocument
    @Bindable var editorState: EditorState
    let renderStore: RenderStore
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let layer = document.model.layer(id: editorState.selectedLayerID) {
                    commonSection(layer)
                    switch layer.kind {
                    case .pattern(let config):
                        PatternInspector(document: document, layerID: layer.id, config: config)
                    case .image(let config):
                        ImageInspector(document: document, layerID: layer.id, config: config)
                    case .text(let config):
                        TextInspector(document: document, layerID: layer.id, config: config)
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
            }
        }
    }

    // MARK: - Canvas (no selection)

    @ViewBuilder
    private var canvasSection: some View {
        Section("Canvas") {
            LabeledContent("Size") {
                Text("\(Int(document.model.canvasSize.width)) × \(Int(document.model.canvasSize.height)) px")
                    .foregroundStyle(.secondary)
            }
            ColorPicker("Background", selection: Binding(
                get: { document.model.background.color },
                set: { newValue in
                    document.update(undoManager, actionName: "Background Color") { model in
                        model.background = RGBAColor(colorValue: newValue)
                    }
                }
            ))
            Text("Select a layer to edit its settings. Use the toolbar to change canvas size.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
