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
    @State private var snapshotName = ""
    @AppStorage("inspector.tab") private var tab: InspectorTab = .properties

    enum InspectorTab: String { case properties, history }

    var body: some View {
        VStack(spacing: 0) {
            PanelTabBar(tabs: [(InspectorTab.properties, "Properties"), (.history, "History")],
                        selection: $tab)
            switch tab {
            case .properties:
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        titleRow
                        propertiesContent
                    }
                }
                .scrollIndicators(.automatic)
            case .history:
                historyPanel
            }
        }
        .background(Theme.panel)
        .panelStyle()
    }

    // MARK: - Title

    private var titleRow: some View {
        let selected = document.model.layer(id: editorState.selectedLayerID)
        let count = editorState.selectedLayerIDs.count
        let icon = count > 1 ? "square.stack.3d.up" : (selected?.kind.iconName ?? "aspectratio")
        let title = count > 1 ? "\(count) Layers" : (selected?.name ?? "Canvas")
        let subtitle: String = {
            if count > 1 { return "Multiple selection" }
            guard let selected else {
                return "\(Int(document.model.canvasSize.width)) × \(Int(document.model.canvasSize.height)) px"
            }
            return selected.kind.kindName
        }()
        return HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Theme.icon)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let selected, document.model.isEffectivelyLocked(selected.id) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
                    .help("Locked")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }

    @ViewBuilder
    private var propertiesContent: some View {
        if editorState.selectedLayerIDs.count > 1 {
            multiSelectionSection
        } else if let layer = document.model.layer(id: editorState.selectedLayerID) {
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
            case .group:
                EmptyView()
            case .adjustment(let config):
                EffectStackSection(document: document, title: "Adjustments",
                                   target: .layer(layer.id), effects: config.effects)
            case .path(let config):
                pathSection(layerID: layer.id, config: config)
            }
            transformSection(layer)
            compositingSection(layer)
            maskSection(layer)
        } else {
            canvasSection
        }
    }

    // MARK: - History

    private var historyPanel: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(document.history.reversed())) { state in
                        Button {
                            document.jumpToHistory(state.id, undoManager: undoManager)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 4))
                                    .foregroundStyle(Theme.textFaint)
                                Text(state.name)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(state.createdAt, style: .time)
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(Theme.textFaint)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 24)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if document.history.isEmpty {
                        Text("No history yet")
                            .foregroundStyle(Theme.textFaint)
                            .padding(12)
                    }
                }
                .padding(.vertical, 4)
            }

            if !document.checkpoints.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Snapshots")
                        .font(Theme.headerFont)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                    ForEach(document.checkpoints) { state in
                        Button {
                            document.restoreCheckpoint(state.id, undoManager: undoManager)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "camera")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.textDim)
                                Text(state.name).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 24)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Restore snapshot")
                    }
                }
                .overlay(alignment: .top) { Rectangle().fill(Theme.separator).frame(height: 1) }
            }

            HStack(spacing: 6) {
                TextField("Snapshot name", text: $snapshotName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveSnapshot() }
                Button {
                    saveSnapshot()
                } label: {
                    Image(systemName: "camera")
                }
                .buttonStyle(IconButtonStyle(size: 22))
                .help("New Snapshot")
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(Theme.header)
            .hairline(.top)
        }
    }

    private func saveSnapshot() {
        let name = snapshotName.trimmingCharacters(in: .whitespacesAndNewlines)
        document.createCheckpoint(name: name.isEmpty ? "Snapshot \(document.checkpoints.count + 1)" : name)
        snapshotName = ""
    }

    @ViewBuilder
    private func compositingSection(_ layer: Layer) -> some View {
        InspectorSection("Layer Style") {
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
                    PanelColorPicker("Color", selection: Binding(
                        get: { style.color.color(in: document.model.colorSettings.workingSpace) },
                        set: { color in
                            updateStyle(layer.id, style.id, action: "Style Color") {
                                $0.color = RGBAColor(colorValue: color, in: document.model.colorSettings.workingSpace)
                            }
                    }))
                    LabeledContent("Size") {
                        NumericSlider(value: styleBinding(layer.id, style, \.size),
                                      range: 0...120, defaultValue: 16, fractionDigits: 0)
                    }
                    LabeledContent("Opacity") {
                        NumericSlider(value: styleBinding(layer.id, style, \.opacity),
                                      range: 0...1, defaultValue: 0.6, percent: true)
                    }
                    if style.type == .dropShadow {
                        LabeledContent("Offset X") {
                            NumericSlider(value: styleBinding(layer.id, style, \.offsetX),
                                          range: -150...150, defaultValue: 12, fractionDigits: 0)
                        }
                        LabeledContent("Offset Y") {
                            NumericSlider(value: styleBinding(layer.id, style, \.offsetY),
                                          range: -150...150, defaultValue: 12, fractionDigits: 0)
                        }
                    }
                    Button("Remove Style", role: .destructive) {
                        document.update(undoManager, actionName: "Remove Style") {
                            $0.modifyLayer(id: layer.id) { $0.styles.removeAll { $0.id == style.id } }
                        }
                    }
                }
            }
        } accessory: {
            Menu {
                ForEach(LayerStyleType.allCases, id: \.self) { type in
                    Button(type.displayName) {
                        document.update(undoManager, actionName: "Add \(type.displayName)") {
                            $0.modifyLayer(id: layer.id) { $0.styles.append(LayerStyle(type: type)) }
                        }
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.icon)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add Layer Style")
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

    // MARK: - Transform

    @ViewBuilder
    private func transformSection(_ layer: Layer) -> some View {
        InspectorSection("Transform") {
            LabeledContent("Position") {
                HStack(spacing: 6) {
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
                HStack(spacing: 6) {
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
                ), range: -4...4, defaultValue: 0, showsValue: false) { editing in
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
                HStack(spacing: 6) {
                    numericField("X", value: Binding(
                        get: { document.model.layer(id: layer.id)?.transform.skewXDegrees ?? 0 },
                        set: { value in document.update(undoManager, actionName: "Skew") {
                            $0.modifyLayer(id: layer.id) { $0.transform.skewXDegrees = value }
                        }}))
                    numericField("Y", value: Binding(
                        get: { document.model.layer(id: layer.id)?.transform.skewYDegrees ?? 0 },
                        set: { value in document.update(undoManager, actionName: "Skew") {
                            $0.modifyLayer(id: layer.id) { $0.transform.skewYDegrees = value }
                        }}))
                }
            }

            LabeledContent("Align") {
                HStack(spacing: 0) {
                    ForEach(PixelDocument.AlignEdge.allCases, id: \.self) { edge in
                        alignButton(edge, ids: [layer.id])
                    }
                }
            }

            HStack(spacing: 0) {
                Button {
                    document.update(undoManager, actionName: "Center Layer") { model in
                        let center = model.canvasCenter
                        model.modifyLayer(id: layer.id) { $0.transform.position = center }
                    }
                } label: { Image(systemName: "plus.viewfinder") }
                    .help("Center on Canvas")
                Button {
                    document.flipLayer(id: layer.id, horizontally: true, undoManager: undoManager)
                } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    .help("Flip Horizontal")
                Button {
                    document.flipLayer(id: layer.id, horizontally: false, undoManager: undoManager)
                } label: { Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
                    .help("Flip Vertical")
                Button {
                    document.update(undoManager, actionName: "Reset Transform") { model in
                        let center = model.canvasCenter
                        model.modifyLayer(id: layer.id) {
                            $0.transform = LayerTransform(position: center)
                        }
                    }
                } label: { Image(systemName: "arrow.counterclockwise") }
                    .help("Reset Transform")

                Spacer(minLength: 8)

                Menu("Distort") {
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
                        Divider()
                        Button("Perspective Crop") {
                            document.perspectiveCrop(to: layer.id, renderStore: renderStore,
                                                     undoManager: undoManager)
                        }
                        Button("Clear Distortion") {
                            document.update(undoManager, actionName: "Clear Distortion") {
                                $0.modifyLayer(id: layer.id) { $0.transform.deformation = nil }
                            }
                        }
                    }
                }
                .fixedSize()
            }
            .buttonStyle(IconButtonStyle())
            .padding(.leading, Theme.labelWidth + 8)

            if layer.transform.deformation != nil {
                deformationControls(layer)
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
        DisclosureGroup("Points") {
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
        let ids = editorState.selectedLayerIDs
        InspectorSection("Arrange") {
            LabeledContent("Align") {
                HStack(spacing: 0) {
                    ForEach(PixelDocument.AlignEdge.allCases, id: \.self) { edge in
                        alignButton(edge, ids: ids)
                    }
                }
            }
            LabeledContent("Distribute") {
                HStack(spacing: 6) {
                    Button("Horizontal") {
                        document.distributeLayers(ids: ids, horizontally: true,
                                                  renderStore: renderStore, undoManager: undoManager)
                    }
                    Button("Vertical") {
                        document.distributeLayers(ids: ids, horizontally: false,
                                                  renderStore: renderStore, undoManager: undoManager)
                    }
                }
                .disabled(ids.count < 3)
                .help(ids.count < 3 ? "Needs three or more layers" : "")
            }
            Button("Group Layers") {
                if let id = document.groupLayers(ids: ids, undoManager: undoManager) {
                    editorState.selectedLayerID = id
                }
            }
            .padding(.leading, Theme.labelWidth + 8)
        }

        let booleanEligible = ids.filter {
            guard let layer = document.model.layer(id: $0) else { return false }
            return layer.kind.isPath || layer.kind.isShape
        }
        if booleanEligible.count >= 2 {
            InspectorSection("Combine Paths") {
                HStack(spacing: 6) {
                    ForEach(PixelDocument.BooleanPathOperation.allCases, id: \.self) { operation in
                        Button(operation.displayName) {
                            if let id = document.booleanPath(ids: ids,
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
        InspectorSection("Path") {
            Text(config.commands == nil
                 ? "\(config.nodes.count) nodes" : "Compound path")
                .foregroundStyle(Theme.textDim)
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
                PanelColorPicker("Fill Color", selection: Binding(
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
                PanelColorPicker("Stroke Color", selection: Binding(
                    get: { stroke.color(in: document.model.colorSettings.workingSpace) },
                    set: { color in
                        document.update(undoManager, actionName: "Path Stroke Color") {
                            $0.modifyLayer(id: layerID) {
                                $0.modifyPath { $0.stroke = RGBAColor(colorValue: color, in: document.model.colorSettings.workingSpace) }
                            }
                        }
                }))
                LabeledContent("Width") {
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
        PanelNumberField(label: label, value: value, fractionDigits: 1, width: 58)
    }

    private func alignButton(_ edge: PixelDocument.AlignEdge, ids: Set<UUID>) -> some View {
        Button {
            document.alignLayers(ids: ids, edge: edge,
                                 renderStore: renderStore, undoManager: undoManager)
        } label: {
            Image(systemName: edge.symbolName)
        }
        .buttonStyle(IconButtonStyle(size: 24))
        .help("Align \(edge.displayName)")
    }

    // MARK: - Mask

    @ViewBuilder
    private func maskSection(_ layer: Layer) -> some View {
        InspectorSection("Mask") {
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
                    PanelPicker("Pattern", selection: Binding(
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
                    Button("Reroll Mask") {
                        document.rerollPatternMask(on: layer.id, undoManager: undoManager)
                    }
                } else {
                    let isEditing = editorState.editingMaskLayerID == layer.id
                    Button(isEditing ? "Done Editing" : "Paint Mask") {
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
                HStack(spacing: 6) {
                    Button("Reveal All") {
                        document.addMask(to: layer.id, hideAll: false, renderStore: renderStore, undoManager: undoManager)
                    }
                    Button("Hide All") {
                        document.addMask(to: layer.id, hideAll: true, renderStore: renderStore, undoManager: undoManager)
                    }
                    Menu("Pattern") {
                        ForEach(GeneratorType.allCases, id: \.self) { type in
                            Button(type.displayName) {
                                document.setPatternMask(on: layer.id, generator: type,
                                                        renderStore: renderStore, undoManager: undoManager)
                            }
                        }
                    }
                    .fixedSize()
                }
            }
        }
    }

    // MARK: - Canvas (no selection)

    @ViewBuilder
    private var canvasSection: some View {
        InspectorSection("Document") {
            LabeledContent("Size") {
                HStack(spacing: 6) {
                    PanelNumberField(label: "W", value: Binding(
                        get: { Double(draftWidth) }, set: { draftWidth = Int($0) }), width: 58)
                    PanelNumberField(label: "H", value: Binding(
                        get: { Double(draftHeight) }, set: { draftHeight = Int($0) }), width: 58)
                }
            }

            if draftSizeDiffers {
                HStack(spacing: 6) {
                    Button("Apply") { applyDraftSize() }
                        .keyboardShortcut(.defaultAction)
                    Button("Revert") { syncDraftSize() }
                }
                .padding(.leading, Theme.labelWidth + 8)
            }

            LabeledContent("Resolution") {
                HStack(spacing: 6) {
                    PanelNumberField(label: nil, value: Binding(
                        get: { document.model.printSettings.dpi },
                        set: { dpi in document.update(undoManager, actionName: "Print Resolution") {
                            $0.printSettings.dpi = max(1, dpi)
                        }}), width: 58)
                    Text("dpi").foregroundStyle(Theme.textDim)
                }
            }
            let physical = document.model.printSettings.physicalSize(for: document.model.canvasSize)
            LabeledContent("Print Size") {
                Text(String(format: "%.2f × %.2f in", physical.width, physical.height))
                    .foregroundStyle(Theme.textDim)
            }

            PanelColorPicker("Background", selection: Binding(
                get: { document.model.background.color(in: document.model.colorSettings.workingSpace) },
                set: { newValue in
                    document.update(undoManager, actionName: "Background Color") { model in
                        model.background = RGBAColor(colorValue: newValue,
                                                     in: model.colorSettings.workingSpace)
                    }
                }
            ))

            PanelPicker("Color Space", selection: Binding(
                get: { document.model.colorSettings.workingSpace },
                set: { value in
                    document.update(undoManager, actionName: "Working Color Space") {
                        $0.colorSettings.workingSpace = value
                    }
                })) {
                ForEach(WorkingColorSpace.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .help("Embedded in exports. Switching reassigns existing colors to the new gamut.")

            PanelPicker("Bit Depth", selection: Binding(
                get: { document.model.colorSettings.bitDepth },
                set: { value in
                    document.update(undoManager, actionName: "Raster Bit Depth") {
                        $0.colorSettings.bitDepth = value
                    }
                })) {
                ForEach(RasterBitDepth.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .help("16-bit avoids banding in gradients")
        }
        .onAppear { syncDraftSize() }
        .onChange(of: document.model.canvasSize) { _, _ in syncDraftSize() }

        EffectStackSection(document: document,
                           title: "Canvas Effects",
                           target: .canvas,
                           effects: document.model.canvasEffects)

        InspectorSection("Export Slices") {
            ForEach(document.model.exportSlices) { slice in
                HStack {
                    Text(slice.name)
                    Spacer()
                    Text(slice.scales.map { "@\($0)x" }.joined(separator: " "))
                        .foregroundStyle(Theme.textDim)
                }
            }
            if document.model.exportSlices.isEmpty {
                Text("None").foregroundStyle(Theme.textFaint)
            }
        } accessory: {
            Button {
                document.update(undoManager, actionName: "Add Export Slice") {
                    $0.exportSlices.append(ExportSlice(name: "Artwork",
                                                       rect: CGRect(origin: .zero, size: $0.canvasSize)))
                }
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(IconButtonStyle(size: 20))
            .help("Add Full-Canvas Slice")
        }

        workspaceSection
    }

    @ViewBuilder
    private var workspaceSection: some View {
        InspectorSection("View") {
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
                    PanelNumberField(label: nil, value: Binding(
                        get: { document.model.workspace.grid.spacing },
                        set: { value in
                            document.update(undoManager, actionName: "Grid Spacing") {
                                $0.workspace.grid.spacing = min(max(value, 4), 2000)
                            }
                        }), width: 58)
                }
                LabeledContent("Subdivisions") {
                    Stepper("\(document.model.workspace.grid.subdivisions)",
                            value: Binding(
                                get: { document.model.workspace.grid.subdivisions },
                                set: { value in
                                    document.update(undoManager, actionName: "Grid Subdivisions") {
                                        $0.workspace.grid.subdivisions = min(max(value, 1), 10)
                                    }
                                }), in: 1...10)
                }
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
            InspectorSection("Guides") {
                ForEach(document.model.workspace.guides) { guide in
                    HStack(spacing: 6) {
                        Image(systemName: guide.orientation == .vertical
                              ? "line.vertical" : "line.horizontal")
                            .foregroundStyle(Theme.textDim)
                            .frame(width: 14)
                        PanelNumberField(label: nil, value: Binding(
                            get: { document.model.workspace.guides.first(where: { $0.id == guide.id })?.position ?? guide.position },
                            set: { value in
                                document.update(undoManager, actionName: "Move Guide") { model in
                                    guard let index = model.workspace.guides.firstIndex(where: { $0.id == guide.id }) else { return }
                                    model.workspace.guides[index].position = value
                                }
                            }), width: 70)
                        Spacer()
                        Button {
                            document.update(undoManager, actionName: "Delete Guide") {
                                $0.workspace.guides.removeAll { $0.id == guide.id }
                            }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(IconButtonStyle(size: 20))
                    }
                }
            } accessory: {
                Button("Clear") {
                    document.update(undoManager, actionName: "Clear Guides") {
                        $0.workspace.guides.removeAll()
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
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

extension PixelDocument.AlignEdge {
    var symbolName: String {
        switch self {
        case .left: "align.horizontal.left"
        case .centerH: "align.horizontal.center"
        case .right: "align.horizontal.right"
        case .top: "align.vertical.top"
        case .centerV: "align.vertical.center"
        case .bottom: "align.vertical.bottom"
        }
    }
}

extension LayerKind {
    /// Short type label shown under layer names.
    var kindName: String {
        switch self {
        case .pattern(let config): config.generator.displayName
        case .image: "Image"
        case .text: "Text"
        case .fill(let config): config.style.displayName
        case .shape(let config): config.kind.displayName
        case .group(let config): "Group · \(config.children.count)"
        case .adjustment: "Adjustment"
        case .path: "Path"
        }
    }
}
