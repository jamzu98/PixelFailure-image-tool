import SwiftUI

/// Reusable "add layer" menu items, shared by the sidebar + button, the tool
/// strip, and the Layer app menu.
struct AddLayerMenuItems: View {
    @ObservedObject var document: PixelDocument
    @Bindable var editorState: EditorState
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Menu("Pattern") {
            ForEach(GeneratorType.allCases, id: \.self) { type in
                Button(type.displayName) {
                    editorState.selectedLayerID = document.addPatternLayer(type, undoManager: undoManager)
                }
            }
        }
        Button("Image…") {
            editorState.showImageImporter = true
        }
        Button("Text") {
            editorState.selectedLayerID = document.addTextLayer(undoManager: undoManager)
        }
        Button("Fill / Gradient") {
            editorState.selectedLayerID = document.addFillLayer(undoManager: undoManager)
        }
        Menu("Shape") {
            ForEach(ShapeKind.allCases, id: \.self) { kind in
                Button(kind.displayName) {
                    editorState.selectedLayerID = document.addShapeLayer(kind, undoManager: undoManager)
                }
            }
        }
        Button("Paint Layer") {
            editorState.selectedLayerID = document.addPaintLayer(undoManager: undoManager)
        }
        Button("Adjustment Layer") {
            editorState.selectedLayerID = document.addAdjustmentLayer(undoManager: undoManager)
        }
        Button("Path") {
            editorState.selectedLayerID = document.addPathLayer(undoManager: undoManager)
        }
    }
}

/// Vertical tool palette on the left edge of the viewport.
struct ToolStrip: View {
    @ObservedObject var document: PixelDocument
    @Bindable var editorState: EditorState

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 4) {
                ForEach(EditorTool.allCases) { tool in
                    Button {
                        editorState.activeTool = tool
                        if tool != .crop { editorState.cropDraft = nil }
                    } label: {
                        Image(systemName: tool.systemImage)
                            .font(.system(size: 14))
                            .frame(width: 30, height: 28)
                            .background(editorState.activeTool == tool ? Color.accentColor.opacity(0.28) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(tool.displayName) (\(String(tool.shortcutKey).uppercased()))")
                }

                Divider()
                    .frame(width: 24)
                    .padding(.vertical, 2)

                Menu {
                    AddLayerMenuItems(document: document, editorState: editorState)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14))
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 30)
                .help("Add layer")
            }
        }
        .scrollIndicators(.hidden)
        .padding(.vertical, 8)
        .padding(.horizontal, 5)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Contextual options for the active tool, shown along the viewport's top.
struct ToolOptionsBar: View {
    @ObservedObject var document: PixelDocument
    @Bindable var editorState: EditorState
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(editorState.activeTool.displayName)
                .font(.caption.weight(.semibold))

            HStack(spacing: 14) {
                switch editorState.activeTool {
            case .brush, .eraser, .clone, .heal, .smudge, .dodge, .burn:
                brushOptions
            case .crop:
                Text("Drag the crop rectangle, then Apply — or press Return. Esc cancels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .zoom:
                Text("Click to zoom in, ⌥-click to zoom out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .eyedropper:
                eyedropperOptions
            case .marquee:
                Picker("", selection: Binding(
                    get: { editorState.marqueeEllipse },
                    set: { editorState.marqueeEllipse = $0 }
                )) {
                    Text("Rectangle").tag(false)
                    Text("Ellipse").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                featherControl
                selectionHint
            case .lasso:
                Picker("", selection: Binding(
                    get: { editorState.lassoPolygonal },
                    set: { editorState.lassoPolygonal = $0 }
                )) {
                    Text("Freehand").tag(false)
                    Text("Polygonal").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                featherControl
                if editorState.lassoPolygonal {
                    Text("Click to add points · Return or click the start to close · Esc cancels.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    selectionHint
                }
            case .wand:
                HStack(spacing: 4) {
                    Text("Tolerance")
                        .font(.caption)
                    NumericSlider(value: Binding(
                        get: { editorState.wandTolerance },
                        set: { editorState.wandTolerance = $0 }
                    ), range: 0.02...0.9, defaultValue: 0.25)
                    .frame(width: 110)
                }
                featherControl
                selectionHint
            case .move:
                Text("Click to select · drag to move · handles scale and rotate · Esc deselects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .hand:
                Text("Drag to pan the canvas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .pen:
                Text("Click to create path nodes · Return to close the path.")
                    .font(.caption).foregroundStyle(.secondary)
            case .node:
                Text("Drag anchors and control handles on the selected path.")
                    .font(.caption).foregroundStyle(.secondary)
            }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        // Fixed height: the bar's contents change per tool, but the bar
        // itself never grows, shrinks, or disappears — no layout jumps.
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .clipped()
    }

    /// Feather applies to the current selection immediately and becomes the
    /// default for the next one.
    private var featherControl: some View {
        HStack(spacing: 4) {
            Text("Feather")
                .font(.caption)
            NumericSlider(value: Binding(
                get: { editorState.selection?.feather ?? editorState.featherDefault },
                set: { newValue in
                    editorState.featherDefault = newValue
                    editorState.selection?.feather = newValue
                }
            ), range: 0...80, defaultValue: 0, fractionDigits: 0)
            .frame(width: 100)
            Text("\(Int((editorState.selection?.feather ?? editorState.featherDefault).rounded()))")
                .font(.caption.monospacedDigit())
                .frame(width: 24, alignment: .leading)
        }
    }

    private var selectionHint: some View {
        Text("⇧ adds · ⌥ subtracts · Esc deselects.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var eyedropperOptions: some View {
        Text("Click to pick a color — into text color, background, or the targeted swatch:")
            .font(.caption)
            .foregroundStyle(.secondary)

        // Which swatch the next pick replaces; advances automatically.
        HStack(spacing: 5) {
            ForEach(Array(document.model.palette.colors.enumerated()), id: \.offset) { i, swatch in
                let isTarget = i == min(editorState.eyedropperSwatchIndex,
                                        document.model.palette.colors.count - 1)
                Button {
                    editorState.eyedropperSwatchIndex = i
                } label: {
                    Circle()
                        .fill(swatch.color)
                        .stroke(isTarget ? Color.accentColor : .secondary.opacity(0.4),
                                lineWidth: isTarget ? 2.5 : 1)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help(isTarget ? "Next pick replaces this swatch" : "Target this swatch")
            }
        }
    }

    @ViewBuilder
    private var brushOptions: some View {
        let brush = editorState.brush

        Picker("Preset", selection: Binding(
            get: { brush.selectedPresetID },
            set: { id in
                if let preset = BrushPreset.builtIns.first(where: { $0.id == id }) {
                    brush.apply(preset)
                }
            })) {
            ForEach(BrushPreset.builtIns) { preset in Text(preset.name).tag(preset.id) }
        }
        .frame(width: 130)

        if editorState.editingMaskLayerID != nil {
            Label("Editing Mask", systemImage: "circle.lefthalf.filled")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)

            Picker("", selection: Binding(
                get: { editorState.maskBrushReveals },
                set: { editorState.maskBrushReveals = $0 }
            )) {
                Text("Hide").tag(false)
                Text("Reveal").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 140)

            Button("Done") {
                editorState.editingMaskLayerID = nil
                editorState.activeTool = .move
            }
        }

        HStack(spacing: 4) {
            Text("Size")
                .font(.caption)
            NumericSlider(value: Binding(get: { brush.size }, set: { brush.size = $0 }),
                          range: 4...600, defaultValue: 120, fractionDigits: 0)
                .frame(width: 120)
            Text("\(Int(brush.size))")
                .font(.caption.monospacedDigit())
                .frame(width: 30, alignment: .leading)
        }
        Menu("Dynamics") {
            LabeledContent("Spacing") {
                NumericSlider(value: Binding(get: { brush.spacing }, set: { brush.spacing = $0 }),
                              range: 0.03...1, defaultValue: 0.15)
                    .frame(width: 130)
            }
            LabeledContent("Smoothing") {
                NumericSlider(value: Binding(get: { brush.smoothing }, set: { brush.smoothing = $0 }),
                              range: 0...0.95, defaultValue: 0.25)
                    .frame(width: 130)
            }
            LabeledContent("Scatter") {
                NumericSlider(value: Binding(get: { brush.scatter }, set: { brush.scatter = $0 }),
                              range: 0...2, defaultValue: 0)
                    .frame(width: 130)
            }
            LabeledContent("Size Jitter") {
                NumericSlider(value: Binding(get: { brush.sizeJitter }, set: { brush.sizeJitter = $0 }),
                              range: 0...1, defaultValue: 0)
                    .frame(width: 130)
            }
            LabeledContent("Opacity Jitter") {
                NumericSlider(value: Binding(get: { brush.opacityJitter }, set: { brush.opacityJitter = $0 }),
                              range: 0...1, defaultValue: 0)
                    .frame(width: 130)
            }
            Toggle("Pressure → Size", isOn: Binding(get: { brush.pressureControlsSize },
                                                     set: { brush.pressureControlsSize = $0 }))
            Toggle("Pressure → Opacity", isOn: Binding(get: { brush.pressureControlsOpacity },
                                                        set: { brush.pressureControlsOpacity = $0 }))
        }
        if editorState.activeTool == .clone || editorState.activeTool == .heal {
            Text(editorState.cloneSourceCanvas == nil
                 ? "⌥-click to set source" : "Source set · ⌥-click to replace")
                .font(.caption).foregroundStyle(editorState.cloneSourceCanvas == nil ? .orange : .secondary)
        }
        HStack(spacing: 4) {
            Text("Hardness")
                .font(.caption)
            NumericSlider(value: Binding(get: { brush.hardness }, set: { brush.hardness = $0 }),
                          range: 0...1, defaultValue: 0.6)
                .frame(width: 90)
        }
        HStack(spacing: 4) {
            Text("Opacity")
                .font(.caption)
            NumericSlider(value: Binding(get: { brush.opacity }, set: { brush.opacity = $0 }),
                          range: 0.05...1, defaultValue: 1)
                .frame(width: 90)
        }
        if editorState.activeTool == .brush && editorState.editingMaskLayerID == nil {
            ColorPicker("", selection: Binding(
                get: { brush.color.color },
                set: { brush.color = RGBAColor(colorValue: $0) }
            ))
            .labelsHidden()
            .frame(width: 30)

            // Quick palette swatches for the brush. Enumerated snapshot, not
            // live indices — see PalettePanel for the crash this avoids.
            HStack(spacing: 4) {
                ForEach(Array(document.model.palette.colors.enumerated()), id: \.offset) { _, swatch in
                    Button {
                        brush.color = swatch
                    } label: {
                        Circle()
                            .fill(swatch.color)
                            .stroke(.secondary.opacity(0.4), lineWidth: 1)
                            .frame(width: 13, height: 13)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
