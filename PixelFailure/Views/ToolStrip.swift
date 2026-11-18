import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

/// Vertical tool column on the left edge of the viewport, grouped like
/// Photoshop's: move, select, crop/sample, retouch, vector, navigate.
struct ToolStrip: View {
    @ObservedObject var document: PixelDocument
    @Bindable var editorState: EditorState
    @Environment(\.undoManager) private var undoManager

    private static let groups: [[EditorTool]] = [
        [.move],
        [.marquee, .lasso, .wand, .objectSelect],
        [.crop, .eyedropper],
        [.brush, .eraser, .clone, .heal, .smudge, .dodge, .burn],
        [.pen, .node],
        [.hand, .zoom],
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(spacing: 2) {
                    ForEach(Self.groups.indices, id: \.self) { index in
                        if index > 0 {
                            Rectangle()
                                .fill(Theme.separator)
                                .frame(width: 20, height: 1)
                                .padding(.vertical, 4)
                        }
                        ForEach(Self.groups[index]) { tool in
                            toolButton(tool)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.never)

            // Foreground (brush) over background (canvas), Photoshop-style.
            ZStack(alignment: .topLeading) {
                SwatchWell(color: document.model.background.color(in: document.model.colorSettings.workingSpace),
                           size: CGSize(width: 18, height: 18), help: "Canvas Background") { newValue in
                    document.update(undoManager, actionName: "Background Color") { model in
                        model.background = RGBAColor(colorValue: newValue, in: model.colorSettings.workingSpace)
                    }
                }
                .offset(x: 9, y: 9)
                SwatchWell(color: editorState.brush.color.color(in: document.model.colorSettings.workingSpace),
                           size: CGSize(width: 18, height: 18), help: "Brush Color") { newValue in
                    editorState.brush.color = RGBAColor(colorValue: newValue,
                                                        in: document.model.colorSettings.workingSpace)
                }
            }
            .frame(width: 27, height: 27, alignment: .topLeading)
            .padding(.bottom, 12)
        }
        .frame(width: 40)
        .background(Theme.chrome)
        .hairline(.trailing)
    }

    private func toolButton(_ tool: EditorTool) -> some View {
        Button {
            editorState.activeTool = tool
            if tool != .crop { editorState.cropDraft = nil }
        } label: {
            Image(systemName: tool.systemImage)
                .font(.system(size: 13))
        }
        .buttonStyle(IconButtonStyle(size: 30, isActive: editorState.activeTool == tool))
        .accessibilityLabel(tool.displayName)
        .help("\(tool.displayName) (\(String(tool.shortcutKey).uppercased()))")
    }
}

/// Contextual options for the active tool, in a slim bar across the top.
struct ToolOptionsBar: View {
    @ObservedObject var document: PixelDocument
    @Bindable var editorState: EditorState
    let renderStore: RenderStore
    @Environment(\.undoManager) private var undoManager
    @State private var showsDynamics = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: editorState.activeTool.systemImage)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .frame(width: 28, height: 24)
                .background(Theme.toolActive, in: RoundedRectangle(cornerRadius: 4))
                .help(editorState.activeTool.displayName)
            BarDivider()

            switch editorState.activeTool {
            case .brush, .eraser, .clone, .heal, .smudge, .dodge, .burn:
                brushOptions
            case .eyedropper:
                eyedropperOptions
            case .marquee:
                Picker("", selection: Binding(
                    get: { editorState.marqueeEllipse },
                    set: { editorState.marqueeEllipse = $0 }
                )) {
                    Image(systemName: "rectangle.dashed").help("Rectangle").tag(false)
                    Image(systemName: "circle.dashed").help("Ellipse").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                featherControl
            case .lasso:
                Picker("", selection: Binding(
                    get: { editorState.lassoPolygonal },
                    set: { editorState.lassoPolygonal = $0 }
                )) {
                    Text("Freehand").tag(false)
                    Text("Polygonal").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                featherControl
            case .wand:
                option("Tolerance") {
                    NumericSlider(value: Binding(
                        get: { editorState.wandTolerance },
                        set: { editorState.wandTolerance = $0 }
                    ), range: 0.02...0.9, defaultValue: 0.25, percent: true)
                    .frame(width: 150)
                }
                featherControl
            case .objectSelect:
                ObjectSelectOptions(vision: editorState.vision,
                                    focus: EditorFocus(document: document, editorState: editorState,
                                                       renderStore: renderStore, undoManager: undoManager))
                featherControl
            case .hand:
                option("Rotate View") {
                    NumericSlider(value: Binding(
                        get: { editorState.canvasRotationDegrees },
                        set: { editorState.canvasRotationDegrees = $0 }),
                        range: -180...180, defaultValue: 0, fractionDigits: 0)
                        .frame(width: 170)
                }
                Button("Reset") { editorState.canvasRotationDegrees = 0 }
            case .move, .crop, .zoom, .pen, .node:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        // Fixed height: contents change per tool, the bar never jumps.
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .background(Theme.chrome)
        .hairline(.bottom)
        .panelStyle()
        .clipped()
    }

    private func option<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(Theme.textDim)
            content()
        }
    }

    /// Feather applies to the current selection immediately and becomes the
    /// default for the next one.
    private var featherControl: some View {
        option("Feather") {
            NumericSlider(value: Binding(
                get: { editorState.selection?.feather ?? editorState.featherDefault },
                set: { newValue in
                    editorState.featherDefault = newValue
                    editorState.selection?.feather = newValue
                }
            ), range: 0...80, defaultValue: 0, fractionDigits: 0)
            .frame(width: 150)
        }
        .help("⇧ adds · ⌥ subtracts")
    }

    @ViewBuilder
    private var eyedropperOptions: some View {
        Text("Sample to")
            .foregroundStyle(Theme.textDim)

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
                        .stroke(isTarget ? Theme.accent : Theme.fieldBorder,
                                lineWidth: isTarget ? 2 : 1)
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

        Picker("", selection: Binding(
            get: { brush.selectedPresetID },
            set: { id in
                if let preset = brush.presets.first(where: { $0.id == id }) {
                    brush.apply(preset)
                }
            })) {
            ForEach(brush.presets) { preset in Text(preset.name).tag(preset.id) }
        }
        .labelsHidden()
        .frame(width: 120)

        Menu {
            Button("Import Presets…") { importBrushPresets(into: brush) }
            Button("Export Custom Presets…") { exportBrushPresets(brush.customPresets) }
                .disabled(brush.customPresets.isEmpty)
        } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Brush Presets")

        if editorState.editingMaskLayerID != nil {
            Label("Mask", systemImage: "circle.lefthalf.filled")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)

            Picker("", selection: Binding(
                get: { editorState.maskBrushReveals },
                set: { editorState.maskBrushReveals = $0 }
            )) {
                Text("Hide").tag(false)
                Text("Reveal").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Button("Done") {
                editorState.editingMaskLayerID = nil
                editorState.activeTool = .move
            }
        }

        option("Size") {
            NumericSlider(value: Binding(get: { brush.size }, set: { brush.size = $0 }),
                          range: 4...600, defaultValue: 120, fractionDigits: 0)
                .frame(width: 150)
        }
        option("Hardness") {
            NumericSlider(value: Binding(get: { brush.hardness }, set: { brush.hardness = $0 }),
                          range: 0...1, defaultValue: 0.6, percent: true)
                .frame(width: 130)
        }
        option("Opacity") {
            NumericSlider(value: Binding(get: { brush.opacity }, set: { brush.opacity = $0 }),
                          range: 0.05...1, defaultValue: 1, percent: true)
                .frame(width: 130)
        }
        Button {
            showsDynamics.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .buttonStyle(IconButtonStyle(size: 24, isActive: showsDynamics))
        .help("Brush Dynamics")
        .popover(isPresented: $showsDynamics, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Spacing") {
                    NumericSlider(value: Binding(get: { brush.spacing }, set: { brush.spacing = $0 }),
                                  range: 0.03...1, defaultValue: 0.15)
                }
                LabeledContent("Smoothing") {
                    NumericSlider(value: Binding(get: { brush.smoothing }, set: { brush.smoothing = $0 }),
                                  range: 0...0.95, defaultValue: 0.25)
                }
                LabeledContent("Scatter") {
                    NumericSlider(value: Binding(get: { brush.scatter }, set: { brush.scatter = $0 }),
                                  range: 0...2, defaultValue: 0)
                }
                LabeledContent("Size Jitter") {
                    NumericSlider(value: Binding(get: { brush.sizeJitter }, set: { brush.sizeJitter = $0 }),
                                  range: 0...1, defaultValue: 0)
                }
                LabeledContent("Opacity Jitter") {
                    NumericSlider(value: Binding(get: { brush.opacityJitter }, set: { brush.opacityJitter = $0 }),
                                  range: 0...1, defaultValue: 0)
                }
                LabeledContent("Angle Jitter") {
                    NumericSlider(value: Binding(get: { brush.angleJitter }, set: { brush.angleJitter = $0 }),
                                  range: 0...1, defaultValue: 0)
                }
                LabeledContent("Tip Aspect") {
                    NumericSlider(value: Binding(get: { brush.tipAspect }, set: { brush.tipAspect = $0 }),
                                  range: 0.1...1, defaultValue: 1)
                }
                LabeledContent("Grain") {
                    NumericSlider(value: Binding(get: { brush.grain }, set: { brush.grain = $0 }),
                                  range: 0...1, defaultValue: 0)
                }
                Toggle("Pressure → Size", isOn: Binding(get: { brush.pressureControlsSize },
                                                         set: { brush.pressureControlsSize = $0 }))
                Toggle("Pressure → Opacity", isOn: Binding(get: { brush.pressureControlsOpacity },
                                                            set: { brush.pressureControlsOpacity = $0 }))
            }
            .padding(12)
            .frame(width: 300)
            .panelStyle()
        }
        if editorState.activeTool == .clone || editorState.activeTool == .heal {
            Text(editorState.cloneSourceCanvas == nil ? "⌥-click to set source" : "Source set")
                .foregroundStyle(editorState.cloneSourceCanvas == nil ? Theme.warning : Theme.textDim)
        }
        if editorState.activeTool == .brush && editorState.editingMaskLayerID == nil {
            BarDivider()
            // Quick palette swatches for the brush. Enumerated snapshot, not
            // live indices — see PalettePanel for the crash this avoids.
            HStack(spacing: 4) {
                ForEach(Array(document.model.palette.colors.enumerated()), id: \.offset) { _, swatch in
                    Button {
                        brush.color = swatch
                    } label: {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(swatch.color)
                            .stroke(Theme.fieldBorder, lineWidth: 1)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func importBrushPresets(into brush: BrushSettings) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["pfbrush", "abr"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let presets = try? BrushPresetLibrary.import(data, fileExtension: url.pathExtension) else { return }
        brush.customPresets.append(contentsOf: presets)
        if let first = presets.first { brush.apply(first) }
    }

    private func exportBrushPresets(_ presets: [BrushPreset]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Brushes.pfbrush"
        if let type = UTType(filenameExtension: "pfbrush") { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? BrushPresetLibrary.export(presets) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
