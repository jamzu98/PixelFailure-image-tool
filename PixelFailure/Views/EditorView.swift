import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @ObservedObject var document: PixelDocument
    @State private var editorState = EditorState()
    @State private var renderStore: RenderStore
    @Environment(\.undoManager) private var undoManager
    @AppStorage("didCompleteOnboarding") private var didCompleteOnboarding = false
    @State private var importNotice: String?

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
                    CanvasViewport(document: document, editorState: editorState, renderStore: renderStore,
                                   animationTime: editorState.animationLayerID == nil
                                       ? nil : editorState.animationPlayhead)
                }
                if let animationLayerID = editorState.animationLayerID {
                    Divider()
                    AnimationTimelineDock(document: document, editorState: editorState,
                                          layerID: animationLayerID, renderStore: renderStore)
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
        .sheet(isPresented: Binding(get: { !didCompleteOnboarding },
                                    set: { if !$0 { didCompleteOnboarding = true } })) {
            OnboardingView { didCompleteOnboarding = true }
        }
        .fileImporter(isPresented: Binding(get: { editorState.showImageImporter },
                                           set: { editorState.showImageImporter = $0 }),
                      allowedContentTypes: importTypes) { result in
            importImage(result)
        }
        .alert("Import notice", isPresented: Binding(get: { importNotice != nil },
                                                      set: { if !$0 { importNotice = nil } })) {
            Button("OK") { importNotice = nil }
        } message: {
            Text(importNotice ?? "")
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
            .help("Export artwork (⌘E)")

            Menu {
                Button("Share Rendered PNG…") { shareRenderedArtwork() }
                Button("Print…") { printArtwork() }
                    .keyboardShortcut("p", modifiers: .command)
                Divider()
                Button("Show Welcome") { didCompleteOnboarding = false }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up.on.square")
            }
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

    private var importTypes: [UTType] {
        var types: [UTType] = [.image, .pdf]
        if let psd = UTType(filenameExtension: "psd") { types.append(psd) }
        return types
    }

    private func importImage(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let name = url.deletingPathExtension().lastPathComponent
        if let outcome = document.importAsset(data: data, fileExtension: url.pathExtension,
                                              suggestedName: name, undoManager: undoManager) {
            editorState.selectedLayerID = outcome.layerID
            importNotice = outcome.warning
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
                        if let outcome = document.importAsset(data: imageData,
                                                              fileExtension: url.pathExtension,
                                                              suggestedName: name,
                                                              undoManager: undoManager) {
                            editorState.selectedLayerID = outcome.layerID
                            importNotice = outcome.warning
                        }
                    }
                }
                return true
            }
        }
        return false
    }

    private func renderedArtwork() -> CGImage? {
        var image = PNGExporter.render(items: renderStore.renderItems(model: document.model, quality: .full),
                                       background: document.model.background,
                                       canvasSize: document.model.canvasSize,
                                       targetPixelSize: document.model.canvasSize,
                                       colorSettings: document.model.colorSettings)
        if let current = image, !document.model.canvasEffects.isEmpty {
            image = EffectPipeline.shared.apply(effects: document.model.canvasEffects,
                                                to: current, palette: document.model.palette)
        }
        return image
    }

    private func shareRenderedArtwork() {
        guard let image = renderedArtwork(), let data = PNGExporter.pngData(image),
              let anchor = NSApp.keyWindow?.contentView else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PixelFailure-\(UUID().uuidString).png")
        do {
            try data.write(to: url, options: .atomic)
            NSSharingServicePicker(items: [url])
                .show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } catch {
            importNotice = "Sharing failed: \(error.localizedDescription)"
        }
    }

    private func printArtwork() {
        guard let image = renderedArtwork() else { return }
        let view = NSImageView(frame: CGRect(origin: .zero, size: document.model.canvasSize))
        view.image = NSImage(cgImage: image, size: document.model.canvasSize)
        view.imageScaling = .scaleProportionallyUpOrDown
        let operation = NSPrintOperation(view: view, printInfo: NSPrintInfo.shared)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }
}

private struct OnboardingView: View {
    let complete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "circle.grid.cross")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(.tint)
            Text("Welcome to PixelFailure")
                .font(.largeTitle.bold())
            Text("Build deterministic generative artwork, combine it with images and editable vectors, then finish it with selections, masks, adjustments, and retouching.")
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                onboardingRow("sidebar.left", "Layers", "Drag layers into groups; Shift-click selects several.")
                onboardingRow("cursorarrow.motionlines", "Canvas", "Use V to move, B to paint, and P for editable paths.")
                onboardingRow("dice", "Generative", "⌘R rerolls a seed; the variations grid explores complete parameter combinations.")
                onboardingRow("square.and.arrow.up", "Export", "⌘E exports PNG, JPEG, TIFF, HEIC, WebP, PDF, or SVG.")
            }
            HStack {
                Spacer()
                Button("Start Creating", action: complete)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 620)
    }

    @ViewBuilder
    private func onboardingRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        GridRow {
            Image(systemName: icon).frame(width: 28)
            Text(title).fontWeight(.semibold)
            Text(detail).foregroundStyle(.secondary)
        }
    }
}
