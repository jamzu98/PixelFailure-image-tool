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
    }
}

/// Vertical tool palette on the left edge of the viewport.
struct ToolStrip: View {
    @ObservedObject var document: PixelDocument
    @Bindable var editorState: EditorState

    var body: some View {
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

            Spacer()
        }
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
        HStack(spacing: 14) {
            switch editorState.activeTool {
            case .brush, .eraser:
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
            default:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
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
            Slider(value: Binding(get: { brush.size }, set: { brush.size = $0 }), in: 4...600)
                .frame(width: 120)
            Text("\(Int(brush.size))")
                .font(.caption.monospacedDigit())
                .frame(width: 30, alignment: .leading)
        }
        HStack(spacing: 4) {
            Text("Hardness")
                .font(.caption)
            Slider(value: Binding(get: { brush.hardness }, set: { brush.hardness = $0 }), in: 0...1)
                .frame(width: 90)
        }
        HStack(spacing: 4) {
            Text("Opacity")
                .font(.caption)
            Slider(value: Binding(get: { brush.opacity }, set: { brush.opacity = $0 }), in: 0.05...1)
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
