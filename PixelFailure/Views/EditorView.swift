import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @ObservedObject var document: PixelDocument
    @State private var editorState = EditorState()
    @State private var renderStore: RenderStore
    @Environment(\.undoManager) private var undoManager

    init(document: PixelDocument) {
        self.document = document
        _renderStore = State(initialValue: RenderStore(document: document))
    }

    var body: some View {
        HSplitView {
            LayerListView(document: document, editorState: editorState, renderStore: renderStore)
                .frame(minWidth: 200, idealWidth: 230, maxWidth: 320)

            VStack(spacing: 0) {
                // Always present at a fixed height so switching tools never
                // shifts the canvas or tool strip.
                ToolOptionsBar(document: document, editorState: editorState)
                Divider()
                HStack(spacing: 0) {
                    ToolStrip(document: document, editorState: editorState)
                    Divider()
                    CanvasViewport(document: document, editorState: editorState, renderStore: renderStore)
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)

            InspectorView(document: document, editorState: editorState, renderStore: renderStore)
                .frame(minWidth: 280, idealWidth: 310, maxWidth: 380)
        }
        .frame(minWidth: 1120, minHeight: 640)
        .focusedSceneValue(\.editorFocus, EditorFocus(document: document,
                                                      editorState: editorState,
                                                      renderStore: renderStore,
                                                      undoManager: undoManager))
        .toolbar { toolbarContent }
        .sheet(isPresented: Binding(get: { editorState.showExportSheet },
                                    set: { editorState.showExportSheet = $0 })) {
            ExportSheet(document: document, renderStore: renderStore)
        }
        .fileImporter(isPresented: Binding(get: { editorState.showImageImporter },
                                           set: { editorState.showImageImporter = $0 }),
                      allowedContentTypes: [.image]) { result in
            importImage(result)
        }
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                canvasSizeButton("Square — 3000 × 3000", CGSize(width: 3000, height: 3000))
                canvasSizeButton("Square — 2000 × 2000", CGSize(width: 2000, height: 2000))
                canvasSizeButton("4K UHD — 3840 × 2160", CGSize(width: 3840, height: 2160))
                canvasSizeButton("5K — 5120 × 2880", CGSize(width: 5120, height: 2880))
                canvasSizeButton("Phone — 1290 × 2796", CGSize(width: 1290, height: 2796))
                canvasSizeButton("Poster — 2480 × 3508", CGSize(width: 2480, height: 3508))
                Divider()
                Button("Custom…") {
                    // Deselect so the inspector shows the canvas size fields.
                    editorState.selectedLayerID = nil
                }
            } label: {
                Label("Canvas", systemImage: "aspectratio")
            }
            .help("Canvas size")

            Button {
                rerollSelected(randomizeParams: false)
            } label: {
                Label("Reroll", systemImage: "dice")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(selectedPatternLayerID == nil)
            .help("Reroll the selected pattern layer's seed (⌘R)")

            Button {
                rerollSelected(randomizeParams: true)
            } label: {
                Label("Randomize", systemImage: "sparkles")
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(selectedPatternLayerID == nil)
            .help("Reroll seed and randomize parameters (⌥⌘R)")

            Button {
                editorState.showExportSheet = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .keyboardShortcut("e", modifiers: .command)
            .help("Export PNG or SVG (⌘E)")
        }
    }

    private func canvasSizeButton(_ title: String, _ size: CGSize) -> some View {
        Button {
            document.setCanvasSize(size, undoManager: undoManager)
        } label: {
            if document.model.canvasSize == size {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var selectedPatternLayerID: UUID? {
        guard let layer = document.model.layer(id: editorState.selectedLayerID),
              layer.kind.isPattern else { return nil }
        return layer.id
    }

    private func rerollSelected(randomizeParams: Bool) {
        guard let id = selectedPatternLayerID else { return }
        document.reroll(layerID: id, randomizeParams: randomizeParams, undoManager: undoManager)
    }

    // MARK: - Image import

    private func importImage(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let name = url.deletingPathExtension().lastPathComponent
        if let id = document.addImageLayer(data: data, suggestedName: name, undoManager: undoManager) {
            editorState.selectedLayerID = id
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in
                        guard let imageData = try? Data(contentsOf: url) else { return }
                        let name = url.deletingPathExtension().lastPathComponent
                        if let id = document.addImageLayer(data: imageData, suggestedName: name,
                                                           undoManager: undoManager) {
                            editorState.selectedLayerID = id
                        }
                    }
                }
                return true
            }
        }
        return false
    }
}
