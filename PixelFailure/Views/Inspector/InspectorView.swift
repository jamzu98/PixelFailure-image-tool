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
    @State private var snapshotName = "Snapshot"

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if editorState.selectedLayerIDs.count > 1 {
                    multiSelectionSection
                } else if let layer = document.model.layer(id: editorState.selectedLayerID) {
                    commonSection(layer)
                    maskSection(layer)
                    compositingSection(layer)
                    switch layer.kind {
                    case .pattern(let config):
                        PatternInspector(document: document, editorState: editorState,
                                         layerID: layer.id, config: config,
                                         renderStore: renderStore)
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
                    case .adjustment(let config):
                        EffectStackSection(document: document, title: "Adjustments",
                                           target: .layer(layer.id), effects: config.effects,
                                           footnote: "Applies non-destructively to visible layers below in this container.")
                    case .path(let config):
                        pathSection(layerID: layer.id, config: config)
                    }
                } else {
                    canvasSection
                }
                historySection
            }
            .formStyle(.grouped)

            Divider()

            PalettePanel(document: document, editorState: editorState, renderStore: renderStore)
        }
    }

    private var historySection: some View {
        Section("History & Snapshots") {
            DisclosureGroup("Recent History (\(document.history.count))") {
                ForEach(Array(document.history.suffix(30).reversed())) { state in
                    Button {
                        document.jumpToHistory(state.id, undoManager: undoManager)
                    } label: {
                        HStack {
                            Text(state.name)
                            Spacer()
                            Text(state.createdAt, style: .time).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                TextField("Snapshot name", text: $snapshotName)
                Button("Save") {
                    document.createCheckpoint(name: snapshotName.isEmpty ? "Snapshot" : snapshotName)
                }
            }
            ForEach(document.checkpoints) { state in
                Button("Restore \(state.name)") {
                    document.restoreCheckpoint(state.id, undoManager: undoManager)
                }
            }
        }
    }

    @ViewBuilder
    private func compositingSection(_ layer: Layer) -> some View {
        Section("Compositing") {
            Toggle("Clip to Layer Below", isOn: Binding(
                get: { document.model.layer(id: layer.id)?.clipsToBelow ?? false },
                set: { value in
                    document.update(undoManager, actionName: "Clipping Mask") {
                        $0.modifyLayer(id: layer.id) { $0.clipsToBelow = value }
                    }
                }))

            ForEach(layer.styles) { style in
                DisclosureGroup(style.type.displayName) {
                    Toggle("Enabled", isOn: styleBinding(layer.id, style, \.isEnabled))
                    ColorPicker("Color", selection: Binding(
                        get: { style.color.color(in: document.model.colorSettings.workingSpace) },
                        set: { color in
                            updateStyle(layer.id, style.id, action: "Style Color") {
                                $0.color = RGBAColor(colorValue: color, in: document.model.colorSettings.workingSpace)
                            }
                    }))
                    LabeledContent("Size") {
                        NumericSlider(value: styleBinding(layer.id, style, \.size),
                                      range: 0...120, defaultValue: 16)
                    }
                    LabeledContent("Opacity") {
                        NumericSlider(value: styleBinding(layer.id, style, \.opacity),
                                      range: 0...1, defaultValue: 0.6)
                    }
                    if style.type == .dropShadow {
                        LabeledContent("Offset X") {
                            NumericSlider(value: styleBinding(layer.id, style, \.offsetX),
                                          range: -150...150, defaultValue: 12)
                        }
                        LabeledContent("Offset Y") {
                            NumericSlider(value: styleBinding(layer.id, style, \.offsetY),
                                          range: -150...150, defaultValue: 12)
                        }
                    }
                    Button("Remove Style", role: .destructive) {
                        document.update(undoManager, actionName: "Remove Style") {
                            $0.modifyLayer(id: layer.id) { $0.styles.removeAll { $0.id == style.id } }
                        }
                    }
                }
            }
            Menu("Add Layer Style") {
                ForEach(LayerStyleType.allCases, id: \.self) { type in
                    Button(type.displayName) {
                        document.update(undoManager, actionName: "Add \(type.displayName)") {
                            $0.modifyLayer(id: layer.id) { $0.styles.append(LayerStyle(type: type)) }
                        }
                    }
                }
            }
        }
    }

    private func updateStyle(_ layerID: UUID, _ styleID: UUID, action: String,
                             _ change: @escaping (inout LayerStyle) -> Void) {
        document.update(undoManager, actionName: action) { model in
            model.modifyLayer(id: layerID) { layer in
                guard let index = layer.styles.firstIndex(where: { $0.id == styleID }) else { return }
                change(&layer.styles[index])
            }
        }
    }

    private func styleBinding<T>(_ layerID: UUID, _ style: LayerStyle,
                                 _ keyPath: WritableKeyPath<LayerStyle, T>) -> Binding<T> {
        Binding(get: {
            document.model.layer(id: layerID)?.styles.first(where: { $0.id == style.id })?[keyPath: keyPath]
                ?? style[keyPath: keyPath]
        }, set: { value in
            updateStyle(layerID, style.id, action: "Layer Style") { $0[keyPath: keyPath] = value }
        })
    }

    // MARK: - Common layer controls

    @ViewBuilder
    private func commonSection(_ layer: Layer) -> some View {
        Section("Layer") {
            LabeledContent("Opacity") {
                NumericSlider(value: Binding(
                    get: { document.model.layer(id: layer.id)?.opacity ?? 1 },
                    set: { newValue in
                        document.updateDuringGesture { model in
                            model.modifyLayer(id: layer.id) { $0.opacity = newValue }
                        }
                    }
                ), range: 0...1, defaultValue: 1) { editing in
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

            if document.model.isEffectivelyLocked(layer.id) {
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
                NumericSlider(value: Binding(
                    get: { log2(document.model.layer(id: layer.id)?.transform.scale ?? 1) },
                    set: { newValue in
                        document.updateDuringGesture { model in
                            model.modifyLayer(id: layer.id) { $0.transform.scale = pow(2, newValue) }
                        }
                    }
                ), range: -4...4, defaultValue: 0) { editing in
                    if editing { document.beginGesture() } else { document.endGesture(undoManager, actionName: "Scale") }
                }
            }

            LabeledContent("Rotation") {
                NumericSlider(value: Binding(
                    get: { document.model.layer(id: layer.id)?.transform.rotationDegrees ?? 0 },
                    set: { newValue in
                        document.updateDuringGesture { model in
                            model.modifyLayer(id: layer.id) { $0.transform.rotationDegrees = newValue }
                        }
                    }
                ), range: -180...180, defaultValue: 0, fractionDigits: 1) { editing in
                    if editing { document.beginGesture() } else { document.endGesture(undoManager, actionName: "Rotation") }
                }
            }

            LabeledContent("Skew") {
                HStack(spacing: 4) {
                    numericField("X°", value: Binding(
                        get: { document.model.layer(id: layer.id)?.transform.skewXDegrees ?? 0 },
                        set: { value in document.update(undoManager, actionName: "Skew") {
                            $0.modifyLayer(id: layer.id) { $0.transform.skewXDegrees = value }
                        }}))
                    numericField("Y°", value: Binding(
                        get: { document.model.layer(id: layer.id)?.transform.skewYDegrees ?? 0 },
                        set: { value in document.update(undoManager, actionName: "Skew") {
                            $0.modifyLayer(id: layer.id) { $0.transform.skewYDegrees = value }
                        }}))
                }
            }

            HStack {
                Button("Corner Pin") {
                    document.update(undoManager, actionName: "Corner Pin") {
                        $0.modifyLayer(id: layer.id) { $0.transform.deformation = .identityCornerPin }
                    }
                }
                Button("Warp 3×3") {
                    let points = (0..<3).flatMap { row in (0..<3).map { column in
                        CGPoint(x: Double(column) / 2, y: Double(row) / 2)
                    }}
                    document.update(undoManager, actionName: "Warp Mesh") {
                        $0.modifyLayer(id: layer.id) {
                            $0.transform.deformation = .warpMesh(columns: 3, rows: 3, points: points)
                        }
                    }
                }
                if layer.transform.deformation != nil {
                    Button("Clear Distort") {
                        document.update(undoManager, actionName: "Clear Distortion") {
                            $0.modifyLayer(id: layer.id) { $0.transform.deformation = nil }
                        }
                    }
                }
            }
            if layer.transform.deformation != nil {
                deformationControls(layer)
                Button("Perspective Crop to Distortion") {
                    document.perspectiveCrop(to: layer.id, renderStore: renderStore,
                                             undoManager: undoManager)
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
        .disabled(document.model.isEffectivelyLocked(layer.id))
    }

    @ViewBuilder
    private func deformationControls(_ layer: Layer) -> some View {
        let points: [CGPoint] = switch layer.transform.deformation {
        case .cornerPin(let points): points
        case .warpMesh(_, _, let points): points
        case nil: []
        }
        DisclosureGroup("Distortion Points") {
            ForEach(points.indices, id: \.self) { index in
                LabeledContent("P\(index + 1)") {
                    HStack(spacing: 4) {
                        numericField("X", value: Binding(
                            get: { points[index].x },
                            set: { setDeformationPoint(layer.id, index: index,
                                                       point: CGPoint(x: $0, y: points[index].y)) }))
                        numericField("Y", value: Binding(
                            get: { points[index].y },
                            set: { setDeformationPoint(layer.id, index: index,
                                                       point: CGPoint(x: points[index].x, y: $0)) }))
                    }
                }
            }
            Text("Coordinates are normalized to the layer; values outside 0…1 are allowed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func setDeformationPoint(_ layerID: UUID, index: Int, point: CGPoint) {
        document.update(undoManager, actionName: "Distort Point") { model in
            model.modifyLayer(id: layerID) { layer in
                switch layer.transform.deformation {
                case .cornerPin(var points):
                    guard points.indices.contains(index) else { return }
                    points[index] = point; layer.transform.deformation = .cornerPin(points)
                case .warpMesh(let columns, let rows, var points):
                    guard points.indices.contains(index) else { return }
                    points[index] = point
                    layer.transform.deformation = .warpMesh(columns: columns, rows: rows, points: points)
                case nil: break
                }
            }
        }
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

        let booleanEligible = editorState.selectedLayerIDs.filter {
            guard let layer = document.model.layer(id: $0) else { return false }
            return layer.kind.isPath || layer.kind.isShape
        }
        if booleanEligible.count >= 2 {
            Section("Boolean Paths") {
                HStack {
                    ForEach(PixelDocument.BooleanPathOperation.allCases, id: \.self) { operation in
                        Button(operation.displayName) {
                            if let id = document.booleanPath(ids: editorState.selectedLayerIDs,
                                                             operation: operation,
                                                             undoManager: undoManager) {
                                editorState.selectedLayerID = id
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func pathSection(layerID: UUID, config: PathConfig) -> some View {
        Section("Path") {
            Text(config.commands == nil
                 ? "\(config.nodes.count) editable nodes" : "Boolean path commands")
                .foregroundStyle(.secondary)
            Toggle("Closed", isOn: Binding(
                get: { config.isClosed },
                set: { value in
                    document.update(undoManager, actionName: "Close Path") {
                        $0.modifyLayer(id: layerID) { $0.modifyPath { $0.isClosed = value } }
                    }
                }))
            Toggle("Fill", isOn: Binding(
                get: { config.fill != nil },
                set: { value in
                    document.update(undoManager, actionName: "Path Fill") {
                        $0.modifyLayer(id: layerID) {
                            $0.modifyPath { $0.fill = value ? document.model.palette.color(1) : nil }
                        }
                    }
                }))
            if let fill = config.fill {
                ColorPicker("Fill Color", selection: Binding(
                    get: { fill.color(in: document.model.colorSettings.workingSpace) },
                    set: { color in
                        document.update(undoManager, actionName: "Path Fill Color") {
                            $0.modifyLayer(id: layerID) {
                                $0.modifyPath { $0.fill = RGBAColor(colorValue: color, in: document.model.colorSettings.workingSpace) }
                            }
                        }
                    }))
            }
            Toggle("Stroke", isOn: Binding(
                get: { config.stroke != nil },
                set: { value in
                    document.update(undoManager, actionName: "Path Stroke") {
                        $0.modifyLayer(id: layerID) {
                            $0.modifyPath { $0.stroke = value ? RGBAColor(hex: "#EFE8D8") : nil }
                        }
                    }
                }))
            if let stroke = config.stroke {
                ColorPicker("Stroke Color", selection: Binding(
                    get: { stroke.color(in: document.model.colorSettings.workingSpace) },
                    set: { color in
                        document.update(undoManager, actionName: "Path Stroke Color") {
                            $0.modifyLayer(id: layerID) {
                                $0.modifyPath { $0.stroke = RGBAColor(colorValue: color, in: document.model.colorSettings.workingSpace) }
                            }
                        }
                }))
                LabeledContent("Stroke Width") {
                    NumericSlider(value: Binding(
                        get: { config.strokeWidth },
                        set: { value in
                            document.updateDuringGesture {
                                $0.modifyLayer(id: layerID) { $0.modifyPath { $0.strokeWidth = value } }
                            }
                        }), range: 0.5...100, defaultValue: 8) { editing in
                            if editing { document.beginGesture() }
                            else { document.endGesture(undoManager, actionName: "Path Stroke Width") }
                        }
                }
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
                if let pattern = mask.pattern {
                    Picker("Pattern", selection: Binding(
                        get: { pattern.generator },
                        set: { generator in
                            document.setPatternMask(on: layer.id, generator: generator,
                                                    renderStore: renderStore, undoManager: undoManager)
                        })) {
                        ForEach(GeneratorType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    ParamControls(document: document,
                                  specs: pattern.generator.generator.specs,
                                  values: pattern.params) { model, key, value in
                        model.modifyLayer(id: layer.id) { layer in
                            layer.mask?.pattern?.params.set(key, value)
                        }
                    }
                    Button("Reroll Pattern Mask") {
                        document.rerollPatternMask(on: layer.id, undoManager: undoManager)
                    }
                } else {
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
                Menu("Pattern Mask") {
                    ForEach(GeneratorType.allCases, id: \.self) { type in
                        Button(type.displayName) {
                            document.setPatternMask(on: layer.id, generator: type,
                                                    renderStore: renderStore, undoManager: undoManager)
                        }
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

            LabeledContent("Resolution") {
                HStack {
                    TextField("DPI", value: Binding(
                        get: { document.model.printSettings.dpi },
                        set: { dpi in document.update(undoManager, actionName: "Print Resolution") {
                            $0.printSettings.dpi = max(1, dpi)
                        }}), format: .number.precision(.fractionLength(0)))
                        .frame(width: 62)
                    Text("dpi").foregroundStyle(.secondary)
                }
            }
            let physical = document.model.printSettings.physicalSize(for: document.model.canvasSize)
            Text(String(format: "Print size %.2f × %.2f in", physical.width, physical.height))
                .font(.caption).foregroundStyle(.secondary)

            Button("Add Full-canvas Export Slice") {
                document.update(undoManager, actionName: "Add Export Slice") {
                    $0.exportSlices.append(ExportSlice(name: "Artwork",
                                                       rect: CGRect(origin: .zero, size: $0.canvasSize)))
                }
            }
            ForEach(document.model.exportSlices) { slice in
                Text("\(slice.name) · \(slice.scales.map { "@\($0)x" }.joined(separator: ", "))")
                    .font(.caption)
            }

            ColorPicker("Background", selection: Binding(
                get: { document.model.background.color(in: document.model.colorSettings.workingSpace) },
                set: { newValue in
                    document.update(undoManager, actionName: "Background Color") { model in
                        model.background = RGBAColor(colorValue: newValue,
                                                     in: model.colorSettings.workingSpace)
                    }
                }
            ))
            Text("Type any resolution above, or pick a preset from the toolbar. Select a layer to edit its settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { syncDraftSize() }
        .onChange(of: document.model.canvasSize) { _, _ in syncDraftSize() }

        colorSection

        EffectStackSection(document: document,
                           title: "Canvas Effects",
                           target: .canvas,
                           effects: document.model.canvasEffects,
                           footnote: "Applied to the whole composite. Affects PNG export and the preview; SVG export skips them.")

        workspaceSection
    }

    @ViewBuilder
    private var colorSection: some View {
        Section("Color") {
            Picker("Working Space", selection: Binding(
                get: { document.model.colorSettings.workingSpace },
                set: { value in
                    document.update(undoManager, actionName: "Working Color Space") {
                        $0.colorSettings.workingSpace = value
                    }
                })) {
                ForEach(WorkingColorSpace.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Bit Depth", selection: Binding(
                get: { document.model.colorSettings.bitDepth },
                set: { value in
                    document.update(undoManager, actionName: "Raster Bit Depth") {
                        $0.colorSettings.bitDepth = value
                    }
                })) {
                ForEach(RasterBitDepth.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Text("Exports embed the working-space profile. Switching the space reassigns existing color values to the new gamut; imported images keep their own profiles. 16-bit keeps smooth gradients band-free and exports via PNG and TIFF.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var workspaceSection: some View {
        Section("Workspace") {
            Toggle("Rulers", isOn: workspaceBinding(\.showsRulers, action: "Toggle Rulers"))
            Toggle("Smart Guides", isOn: workspaceBinding(\.smartGuidesEnabled,
                                                           action: "Toggle Smart Guides"))
            Toggle("Navigator", isOn: workspaceBinding(\.showsNavigator,
                                                        action: "Toggle Navigator"))
            Toggle("Grid", isOn: Binding(
                get: { document.model.workspace.grid.isVisible },
                set: { value in
                    document.update(undoManager, actionName: "Toggle Grid") { $0.workspace.grid.isVisible = value }
                }))
            if document.model.workspace.grid.isVisible {
                LabeledContent("Grid Spacing") {
                    TextField("px", value: Binding(
                        get: { document.model.workspace.grid.spacing },
                        set: { value in
                            document.update(undoManager, actionName: "Grid Spacing") {
                                $0.workspace.grid.spacing = min(max(value, 4), 2000)
                            }
                        }), format: .number.precision(.fractionLength(0)))
                    .frame(width: 70)
                }
                Stepper("Subdivisions: \(document.model.workspace.grid.subdivisions)",
                        value: Binding(
                            get: { document.model.workspace.grid.subdivisions },
                            set: { value in
                                document.update(undoManager, actionName: "Grid Subdivisions") {
                                    $0.workspace.grid.subdivisions = min(max(value, 1), 10)
                                }
                            }), in: 1...10)
                Toggle("Snap to Grid", isOn: Binding(
                    get: { document.model.workspace.grid.snapsToGrid },
                    set: { value in
                        document.update(undoManager, actionName: "Snap to Grid") {
                            $0.workspace.grid.snapsToGrid = value
                        }
                    }))
            }
        }

        if !document.model.workspace.guides.isEmpty {
            Section("Guides") {
                ForEach(document.model.workspace.guides) { guide in
                    HStack {
                        Image(systemName: guide.orientation == .vertical
                              ? "line.vertical" : "line.horizontal")
                        TextField("Position", value: Binding(
                            get: { document.model.workspace.guides.first(where: { $0.id == guide.id })?.position ?? guide.position },
                            set: { value in
                                document.update(undoManager, actionName: "Move Guide") { model in
                                    guard let index = model.workspace.guides.firstIndex(where: { $0.id == guide.id }) else { return }
                                    model.workspace.guides[index].position = value
                                }
                            }), format: .number.precision(.fractionLength(0)))
                        Button {
                            document.update(undoManager, actionName: "Delete Guide") {
                                $0.workspace.guides.removeAll { $0.id == guide.id }
                            }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Clear Guides") {
                    document.update(undoManager, actionName: "Clear Guides") {
                        $0.workspace.guides.removeAll()
                    }
                }
            }
        }
    }

    private func workspaceBinding(_ keyPath: WritableKeyPath<WorkspaceSettings, Bool>,
                                  action: String) -> Binding<Bool> {
        Binding(get: { document.model.workspace[keyPath: keyPath] },
                set: { value in
                    document.update(undoManager, actionName: action) {
                        $0.workspace[keyPath: keyPath] = value
                    }
                })
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
