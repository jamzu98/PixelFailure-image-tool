import AppKit
import SwiftUI

/// Layers panel: layers listed top-of-stack first, with visibility toggles,
/// double-click rename, drag reorder, and add/remove controls.
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

    @State private var anchorID: UUID?
    @State private var renamingID: UUID?
    @State private var dropTargetID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Layers") { EmptyView() }
            layerControls

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(displayedRows) { entry in
                        row(entry)
                    }
                }
            }
            .contextMenu {
                Menu("New Layer") {
                    AddLayerMenuItems(document: document, editorState: editorState)
                }
            }

            canvasRow
            footer
        }
        .background(Theme.panel)
        .panelStyle()
    }

    // MARK: - Blend / opacity

    private var layerControls: some View {
        let layer = document.model.layer(id: editorState.selectedLayerID)
        return HStack(spacing: 8) {
            Picker("Blend Mode", selection: Binding(
                get: { layer?.blendMode ?? .normal },
                set: { newValue in
                    guard let id = layer?.id else { return }
                    document.update(undoManager, actionName: "Blend Mode") { model in
                        model.modifyLayer(id: id) { $0.blendMode = newValue }
                    }
                }
            )) {
                ForEach(LayerBlendMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .frame(minWidth: 80, maxWidth: 110)

            Spacer(minLength: 0)

            Text("Opacity")
                .foregroundStyle(Theme.textDim)
                .fixedSize()
            NumericSlider(value: Binding(
                get: { layer.flatMap { document.model.layer(id: $0.id)?.opacity } ?? 1 },
                set: { newValue in
                    guard let id = layer?.id else { return }
                    document.updateDuringGesture { model in
                        model.modifyLayer(id: id) { $0.opacity = newValue }
                    }
                }
            ), range: 0...1, defaultValue: 1, percent: true) { editing in
                if editing { document.beginGesture() } else { document.endGesture(undoManager, actionName: "Opacity") }
            }
            .frame(width: 112)
        }
        .disabled(layer == nil)
        .padding(.horizontal, 8)
        .frame(height: 34)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }

    // MARK: - Rows

    private func row(_ entry: RowEntry) -> some View {
        let id = entry.layer.id
        return LayerRow(document: document,
                        layer: entry.layer,
                        depth: entry.depth,
                        isSelected: editorState.selectedLayerIDs.contains(id),
                        isExpanded: editorState.expandedGroups.contains(id),
                        isRenaming: Binding(get: { renamingID == id },
                                            set: { renamingID = $0 ? id : nil }),
                        isDropTarget: dropTargetID == id,
                        renderStore: renderStore,
                        onToggleExpand: {
                            if editorState.expandedGroups.contains(id) {
                                editorState.expandedGroups.remove(id)
                            } else {
                                editorState.expandedGroups.insert(id)
                            }
                        })
            .onTapGesture {
                // Second click of a double-click renames in place.
                if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                    renamingID = id
                } else {
                    select(id)
                }
            }
            .draggable(id.uuidString)
            .dropDestination(for: String.self) { identifiers, _ in
                guard let raw = identifiers.first,
                      let sourceID = UUID(uuidString: raw) else { return false }
                return dropLayer(sourceID, onto: entry.layer)
            } isTargeted: { targeted in
                if targeted { dropTargetID = id } else if dropTargetID == id { dropTargetID = nil }
            }
            .contextMenu {
                rowContextMenu(entry.layer)
            }
    }

    /// Click selects; ⌘-click toggles; ⇧-click extends from the last click.
    private func select(_ id: UUID) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if editorState.selectedLayerIDs.contains(id) {
                editorState.selectedLayerIDs.remove(id)
            } else {
                editorState.selectedLayerIDs.insert(id)
            }
        } else if flags.contains(.shift), let anchorID,
                  let from = displayedRows.firstIndex(where: { $0.id == anchorID }),
                  let to = displayedRows.firstIndex(where: { $0.id == id }) {
            let range = min(from, to)...max(from, to)
            editorState.selectedLayerIDs = Set(displayedRows[range].map(\.id))
            return
        } else {
            editorState.selectedLayerIDs = [id]
        }
        anchorID = id
    }

    /// Selecting "Canvas" (no layer) shows document settings in Properties.
    private var canvasRow: some View {
        let isSelected = editorState.selectedLayerIDs.isEmpty
        return HStack(spacing: 8) {
            Color.clear.frame(width: 18)
            RoundedRectangle(cornerRadius: 2)
                .fill(document.model.background.color)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.separator, lineWidth: 1))
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Canvas")
                    .italic()
                Text("\(Int(document.model.canvasSize.width)) × \(Int(document.model.canvasSize.height))")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
            }
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: 9))
                .foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 8)
        .frame(height: 42)
        .background(isSelected ? Theme.rowSelected : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { editorState.selectedLayerID = nil }
        .dropDestination(for: String.self) { identifiers, _ in
            guard let raw = identifiers.first,
                  let sourceID = UUID(uuidString: raw) else { return false }
            return document.moveLayer(id: sourceID, to: nil,
                                      at: document.model.layers.count,
                                      undoManager: undoManager)
        }
        .overlay(alignment: .top) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }

    // MARK: - Footer

    private var footer: some View {
        let selectedID = editorState.selectedLayerID
        let selectedLayer = document.model.layer(id: selectedID)
        return HStack(spacing: 2) {
            Spacer()
            Button {
                if let id = selectedID {
                    document.addMask(to: id, hideAll: false, renderStore: renderStore, undoManager: undoManager)
                }
            } label: { Image(systemName: "circle.lefthalf.filled") }
                .disabled(selectedLayer == nil || selectedLayer?.mask != nil)
                .help("Add Mask")

            Button {
                if let id = document.groupLayers(ids: editorState.selectedLayerIDs, undoManager: undoManager) {
                    editorState.selectedLayerID = id
                }
            } label: { Image(systemName: "folder.badge.plus") }
                .disabled(editorState.selectedLayerIDs.isEmpty)
                .help("Group (⌘G)")

            Menu {
                AddLayerMenuItems(document: document, editorState: editorState)
            } label: {
                Image(systemName: "plus.square")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.icon)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24, height: 24)
            .help("New Layer")

            Button {
                if let id = selectedID, let newID = document.duplicateLayer(id: id, undoManager: undoManager) {
                    editorState.selectedLayerID = newID
                }
            } label: { Image(systemName: "plus.square.on.square") }
                .disabled(selectedID == nil)
                .help("Duplicate (⌘J)")

            Button {
                if let id = selectedID {
                    document.deleteLayer(id: id, undoManager: undoManager)
                    editorState.selectedLayerID = nil
                }
            } label: { Image(systemName: "trash") }
                .disabled(selectedID == nil)
                .help("Delete Layer")
        }
        .buttonStyle(IconButtonStyle())
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(Theme.header)
        .hairline(.top)
    }

    @ViewBuilder
    private func rowContextMenu(_ layer: Layer) -> some View {
        Button("Copy") {
            if let selection = editorState.selection,
               editorState.selectedLayerID == layer.id,
               layer.kind.isImage {
                document.copySelection(selection, layerID: layer.id, renderStore: renderStore)
            } else {
                document.copyLayer(id: layer.id, renderStore: renderStore)
            }
        }
        Button("Cut") {
            if let selection = editorState.selection,
               editorState.selectedLayerID == layer.id,
               layer.kind.isImage {
                document.cutSelection(selection, layerID: layer.id,
                                      renderStore: renderStore, undoManager: undoManager)
            } else {
                document.cutLayer(id: layer.id, renderStore: renderStore, undoManager: undoManager)
                editorState.selectedLayerIDs.remove(layer.id)
            }
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

    /// Dropping on a group places the source at the top of that group.
    /// Dropping on any other row places it immediately above that row in the
    /// row's current container. Dropping on Canvas moves it to root/top.
    private func dropLayer(_ sourceID: UUID, onto target: Layer) -> Bool {
        guard sourceID != target.id else { return false }
        if let group = target.groupConfig {
            return document.moveLayer(id: sourceID, to: target.id,
                                      at: group.children.count,
                                      undoManager: undoManager)
        }
        let parentID = document.model.parentGroupID(of: target.id)
        guard let container = document.model.containerLayers(parentGroupID: parentID),
              let targetIndex = container.firstIndex(where: { $0.id == target.id }) else { return false }
        var destination = targetIndex + 1
        if document.model.parentGroupID(of: sourceID) == parentID,
           let sourceIndex = container.firstIndex(where: { $0.id == sourceID }),
           sourceIndex < destination {
            destination -= 1
        }
        return document.moveLayer(id: sourceID, to: parentID,
                                  at: destination, undoManager: undoManager)
    }
}

private struct LayerRow: View {
    @ObservedObject var document: PixelDocument
    let layer: Layer
    var depth: Int = 0
    var isSelected: Bool
    var isExpanded: Bool = false
    @Binding var isRenaming: Bool
    var isDropTarget: Bool
    let renderStore: RenderStore
    var onToggleExpand: () -> Void = {}
    @Environment(\.undoManager) private var undoManager
    @State private var draftName: String = ""
    @State private var isHovering = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button {
                document.update(undoManager, actionName: layer.isVisible ? "Hide Layer" : "Show Layer") { model in
                    model.modifyLayer(id: layer.id) { $0.isVisible.toggle() }
                }
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(layer.isVisible ? Theme.icon : Theme.textFaint)
                    .frame(width: 18, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(layer.isVisible ? "Hide" : "Show")

            if depth > 0 {
                Color.clear.frame(width: CGFloat(depth) * 14)
            }

            if layer.kind.isGroup {
                Button(action: onToggleExpand) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textDim)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            thumbnail

            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    TextField("Layer", text: $draftName)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 3)
                        .background(Theme.field)
                        .overlay(Rectangle().stroke(Theme.accent, lineWidth: 1))
                        .focused($nameFocused)
                        .onAppear {
                            draftName = layer.name
                            nameFocused = true
                        }
                        .onSubmit { commitRename() }
                        .onChange(of: nameFocused) { _, focused in if !focused { commitRename() } }
                        .onKeyPress(.escape) {
                            isRenaming = false
                            return .handled
                        }
                } else {
                    Text(layer.name)
                        .lineLimit(1)
                        .foregroundStyle(layer.isVisible ? Theme.text : Theme.textDim)
                }
                if layer.kind.kindName != layer.name {
                    Text(layer.kind.kindName)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 2)

            if layer.clipsToBelow {
                Image(systemName: "arrow.turn.left.down")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textDim)
                    .help("Clipped to layer below")
            }
            if !layer.styles.isEmpty {
                Text("fx")
                    .font(.system(size: 10, weight: .semibold).italic())
                    .foregroundStyle(Theme.textDim)
            }
            if layer.mask != nil {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
                    .help("Has mask")
            }
            if layer.isLocked || isHovering {
                Button {
                    document.toggleLock(id: layer.id, undoManager: undoManager)
                } label: {
                    Image(systemName: layer.isLocked ? "lock.fill" : "lock.open")
                        .font(.system(size: 9))
                        .foregroundStyle(layer.isLocked ? Theme.textDim : Theme.textFaint)
                        .frame(width: 16, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(layer.isLocked ? "Unlock" : "Lock")
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .frame(height: 42)
        .background(isSelected ? Theme.rowSelected : (isHovering ? Theme.hover.opacity(0.45) : Color.clear))
        .overlay(alignment: .top) {
            if isDropTarget { Rectangle().fill(Theme.accent).frame(height: 2) }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.header).frame(height: 1)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private var thumbnail: some View {
        ZStack {
            CheckerboardBackground()
            if let image = renderStore.thumbnail(for: layer, model: document.model) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: layer.kind.iconName)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.icon)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.field)
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 2)
            .stroke(isSelected ? Theme.textDim : Theme.separator, lineWidth: 1))
    }

    private func commitRename() {
        guard isRenaming else { return }
        let name = draftName.trimmingCharacters(in: .whitespaces)
        isRenaming = false
        guard !name.isEmpty, name != layer.name else { return }
        document.update(undoManager, actionName: "Rename Layer") { model in
            model.modifyLayer(id: layer.id) { $0.name = name }
        }
    }
}

/// Transparency checkerboard used behind layer thumbnails.
struct CheckerboardBackground: View {
    var cell: CGFloat = 4

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.82)))
            var dark = Path()
            let columns = Int(ceil(size.width / cell)), rows = Int(ceil(size.height / cell))
            for row in 0..<rows {
                for column in 0..<columns where (row + column).isMultiple(of: 2) {
                    dark.addRect(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell,
                                        width: cell, height: cell))
                }
            }
            context.fill(dark, with: .color(Color(white: 0.66)))
        }
    }
}
