import SwiftUI

/// Left sidebar: layers listed top-of-stack first, with visibility toggles,
/// inline rename, drag reorder, and add/remove controls.
struct LayerListView: View {
    @ObservedObject var document: PixelDocument
    @Bindable var editorState: EditorState
    let renderStore: RenderStore
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selectionBinding) {
                ForEach(displayedLayers) { layer in
                    LayerRow(document: document, layer: layer, renderStore: renderStore)
                        .tag(layer.id)
                        .contextMenu {
                            Button("Copy") {
                                document.copyLayer(id: layer.id, renderStore: renderStore)
                            }
                            Button("Cut") {
                                document.cutLayer(id: layer.id, renderStore: renderStore, undoManager: undoManager)
                                if editorState.selectedLayerID == layer.id {
                                    editorState.selectedLayerID = nil
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
                                if editorState.selectedLayerID == layer.id {
                                    editorState.selectedLayerID = nil
                                }
                            }
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

    /// Model stores bottom-to-top; the list shows top layer first.
    private var displayedLayers: [Layer] {
        document.model.layers.reversed()
    }

    private var selectionBinding: Binding<UUID?> {
        Binding(get: { editorState.selectedLayerID },
                set: { editorState.selectedLayerID = $0 })
    }

    private func moveDisplayed(from source: IndexSet, to destination: Int) {
        var displayed = displayedLayers
        displayed.move(fromOffsets: source, toOffset: destination)
        let reordered = Array(displayed.reversed())
        document.update(undoManager, actionName: "Reorder Layers") { model in
            model.layers = reordered
        }
    }
}

private struct LayerRow: View {
    @ObservedObject var document: PixelDocument
    let layer: Layer
    let renderStore: RenderStore
    @Environment(\.undoManager) private var undoManager
    @State private var draftName: String = ""

    var body: some View {
        HStack(spacing: 6) {
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
