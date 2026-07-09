import SwiftUI

/// Left sidebar: layers listed top-of-stack first, with visibility toggles,
/// inline rename, drag reorder, and add/remove controls.
struct LayerListView: View {
    @ObservedObject var document: PixelDocument
    @Bindable var editorState: EditorState
    let renderStore: RenderStore
    @Environment(\.undoManager) private var undoManager

    /// One sidebar row: a layer plus its nesting depth.
    private struct RowEntry: Identifiable {
        let layer: Layer
        let depth: Int
        var id: UUID { layer.id }
    }

    /// Tree flattened for display: top-of-stack first at every level, group
    /// children shown when the group is expanded.
    private var displayedRows: [RowEntry] {
        func walk(_ layers: [Layer], depth: Int) -> [RowEntry] {
            layers.reversed().flatMap { layer -> [RowEntry] in
                var rows = [RowEntry(layer: layer, depth: depth)]
                if let group = layer.groupConfig, editorState.expandedGroups.contains(layer.id) {
                    rows += walk(group.children, depth: depth + 1)
                }
                return rows
            }
        }
        return walk(document.model.layers, depth: 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: multiSelectionBinding) {
                ForEach(displayedRows) { entry in
                    LayerRow(document: document,
                             layer: entry.layer,
                             depth: entry.depth,
                             isExpanded: editorState.expandedGroups.contains(entry.layer.id),
                             renderStore: renderStore,
                             onToggleExpand: {
                                 if editorState.expandedGroups.contains(entry.layer.id) {
                                     editorState.expandedGroups.remove(entry.layer.id)
                                 } else {
                                     editorState.expandedGroups.insert(entry.layer.id)
                                 }
                             })
                        .tag(entry.layer.id)
                        .contextMenu {
                            rowContextMenu(entry.layer)
                        }
                }
                .onMove { source, destination in
                    moveDisplayed(from: source, to: destination)
                }
            }
            .listStyle(.sidebar)

            Divider()

            // Canvas pseudo-row: selects "nothing", which shows the canvas
            // settings (size, background) in the inspector.
            Button {
                editorState.selectedLayerID = nil
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "aspectratio")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text("Canvas")
                    Spacer()
                    Text("\(Int(document.model.canvasSize.width)) × \(Int(document.model.canvasSize.height))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .background(editorState.selectedLayerID == nil ? Color.accentColor.opacity(0.22) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .help("Canvas settings (size, background color)")

            Divider()

            HStack(spacing: 8) {
                Menu {
                    AddLayerMenuItems(document: document, editorState: editorState)
                } label: {
                    Image(systemName: "plus")
                }
                .menuIndicator(.hidden)
                .frame(width: 28)

                Button {
                    if let id = editorState.selectedLayerID {
                        document.deleteLayer(id: id, undoManager: undoManager)
                        editorState.selectedLayerID = nil
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(editorState.selectedLayerID == nil)

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private var multiSelectionBinding: Binding<Set<UUID>> {
        Binding(get: { editorState.selectedLayerIDs },
                set: { editorState.selectedLayerIDs = $0 })
    }

    @ViewBuilder
    private func rowContextMenu(_ layer: Layer) -> some View {
        Button("Copy") {
            document.copyLayer(id: layer.id, renderStore: renderStore)
        }
        Button("Cut") {
            document.cutLayer(id: layer.id, renderStore: renderStore, undoManager: undoManager)
            editorState.selectedLayerIDs.remove(layer.id)
        }
        Button("Paste") {
            switch LayerPasteboard.readAny() {
            case .layer(let transfer):
                editorState.selectedLayerID = document.pasteLayer(transfer, undoManager: undoManager)
            case .image(let data, _):
                if let id = document.addImageLayer(data: data, suggestedName: "Pasted Image",
                                                   undoManager: undoManager) {
                    editorState.selectedLayerID = id
                }
            case nil:
                break
            }
        }
        .disabled(!LayerPasteboard.hasPayload)
        Divider()
        if editorState.selectedLayerIDs.count > 1 {
            Button("Group \(editorState.selectedLayerIDs.count) Layers") {
                if let id = document.groupLayers(ids: editorState.selectedLayerIDs, undoManager: undoManager) {
                    editorState.selectedLayerID = id
                }
            }
        }
        if layer.kind.isGroup {
            Button("Ungroup") {
                document.ungroup(id: layer.id, undoManager: undoManager)
                editorState.selectedLayerIDs.remove(layer.id)
            }
        }
        Button("Duplicate") {
            if let newID = document.duplicateLayer(id: layer.id, undoManager: undoManager) {
                editorState.selectedLayerID = newID
            }
        }
        Button("Rasterize") {
            document.rasterizeLayer(id: layer.id, renderStore: renderStore, undoManager: undoManager)
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
        Button("Delete", role: .destructive) {
            document.deleteLayer(id: layer.id, undoManager: undoManager)
            editorState.selectedLayerIDs.remove(layer.id)
        }
    }

    /// Drag reorder: top-level rows only (nested layers reorder via the
    /// Arrange context menu, which is container-aware).
    private func moveDisplayed(from source: IndexSet, to destination: Int) {
        let rows = displayedRows
        guard let sourceIndex = source.first,
              rows.indices.contains(sourceIndex),
              rows[sourceIndex].depth == 0 else { return }
        // Only allow drops at top-level boundaries.
        let boundaryOK = destination == rows.count
            || (rows.indices.contains(destination) && rows[destination].depth == 0)
        guard boundaryOK else { return }

        var topLevel = Array(document.model.layers.reversed())
        guard let fromIndex = topLevel.firstIndex(where: { $0.id == rows[sourceIndex].layer.id }) else { return }
        // Map the flat destination to a top-level index.
        let before = rows[..<destination].filter { $0.depth == 0 }.count
        var moved = topLevel
        moved.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: min(before, topLevel.count))
        let reordered = Array(moved.reversed())
        document.update(undoManager, actionName: "Reorder Layers") { model in
            model.layers = reordered
        }
    }
}

private struct LayerRow: View {
    @ObservedObject var document: PixelDocument
    let layer: Layer
    var depth: Int = 0
    var isExpanded: Bool = false
    let renderStore: RenderStore
    var onToggleExpand: () -> Void = {}
    @Environment(\.undoManager) private var undoManager
    @State private var draftName: String = ""

    var body: some View {
        HStack(spacing: 6) {
            if depth > 0 {
                Spacer()
                    .frame(width: CGFloat(depth) * 14)
            }

            if layer.kind.isGroup {
                Button(action: onToggleExpand) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                }
                .buttonStyle(.borderless)
            }

            Button {
                document.update(undoManager, actionName: layer.isVisible ? "Hide Layer" : "Show Layer") { model in
                    model.modifyLayer(id: layer.id) { $0.isVisible.toggle() }
                }
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(layer.isVisible ? .primary : .tertiary)
            }
            .buttonStyle(.borderless)

            // Content thumbnail with the kind icon as fallback.
            Group {
                if let thumbnail = renderStore.thumbnail(for: layer, model: document.model) {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: layer.kind.iconName)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator, lineWidth: 0.5))

            TextField("Layer", text: $draftName)
                .textFieldStyle(.plain)
                .onSubmit {
                    let name = draftName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty, name != layer.name else { return }
                    document.update(undoManager, actionName: "Rename Layer") { model in
                        model.modifyLayer(id: layer.id) { $0.name = name }
                    }
                }

            if layer.mask != nil {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Has a mask")
            }

            Button {
                document.toggleLock(id: layer.id, undoManager: undoManager)
            } label: {
                Image(systemName: layer.isLocked ? "lock.fill" : "lock.open")
                    .font(.caption)
                    .foregroundStyle(layer.isLocked ? .primary : .quaternary)
            }
            .buttonStyle(.borderless)
            .help(layer.isLocked ? "Unlock layer" : "Lock layer")
        }
        .opacity(layer.isVisible ? 1 : 0.55)
        .onAppear { draftName = layer.name }
        .onChange(of: layer.name) { _, newValue in draftName = newValue }
    }
}
