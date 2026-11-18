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
    @State private var recoveryID = UUID()
    @State private var recoveryTask: Task<Void, Never>?
    @State private var pendingRecoveryURL: URL?

    init(document: PixelDocument) {
        self.document = document
        _renderStore = State(initialValue: RenderStore(document: document))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Always present at a fixed height so switching tools never
            // shifts the canvas.
            ToolOptionsBar(document: document, editorState: editorState)

            HSplitView {
                HStack(spacing: 0) {
                    ToolStrip(document: document, editorState: editorState)
                    VStack(spacing: 0) {
                        CanvasViewport(document: document, editorState: editorState, renderStore: renderStore,
                                       animationTime: editorState.animationLayerID == nil
                                           ? nil : editorState.animationPlayhead)
                        if let animationLayerID = editorState.animationLayerID {
                            AnimationTimelineDock(document: document, editorState: editorState,
                                                  layerID: animationLayerID, renderStore: renderStore)
                                .hairline(.top)
                        }
                    }
                }
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

                GeometryReader { dock in
                    VSplitView {
                        InspectorView(document: document, editorState: editorState, renderStore: renderStore)
                            .frame(minHeight: 180, maxHeight: .infinity)
                        VStack(spacing: 0) {
                            PalettePanel(document: document, editorState: editorState, renderStore: renderStore)
                            LayerListView(document: document, editorState: editorState, renderStore: renderStore)
                        }
                        // Properties carries the most controls; keep it the
                        // larger half of the dock.
                        .frame(minHeight: 240, maxHeight: max(240, dock.size.height * 0.45))
                    }
                }
                .frame(minWidth: 280, idealWidth: 310, maxWidth: 420)
                .background(Theme.panel)
            }
        }
        .background(Theme.chrome)
        .frame(minWidth: 1120, minHeight: 640)
        .focusedSceneValue(\.editorFocus, EditorFocus(document: document,
                                                      editorState: editorState,
                                                      renderStore: renderStore,
                                                      undoManager: undoManager))
        .toolbar { toolbarContent }
        // Paint the title bar as one solid strip; otherwise each split pane's
        // background (layers, canvas, inspector) bleeds up into it as sections.
        .toolbarBackground(Theme.chrome, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .sheet(isPresented: Binding(get: { editorState.showExportSheet },
                                    set: { editorState.showExportSheet = $0 })) {
            NavigationStack {
                ExportSheet(document: document, renderStore: renderStore)
            }
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
        .alert("Recover Unsaved Document?", isPresented: Binding(
            get: { pendingRecoveryURL != nil },
            set: { if !$0 { pendingRecoveryURL = nil } })) {
                Button("Recover") { recoverPendingDocument() }
                Button("Discard", role: .destructive) { discardPendingRecovery() }
                Button("Later", role: .cancel) { pendingRecoveryURL = nil }
            } message: {
                Text("An autosave from an interrupted session was found.")
            }
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .onChange(of: document.model) { oldModel, newModel in
            renderStore.modelDidChange(from: oldModel, to: newModel)
            recoveryTask?.cancel()
            recoveryTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                _ = try? RecoveryStore.save(document, identifier: recoveryID)
            }
        }
        .onAppear {
            AutomationBridge.shared.activeDocument = document
            pendingRecoveryURL = RecoveryStore.available().first
        }
        .onDisappear {
            recoveryTask?.cancel()
            RecoveryStore.discard(identifier: recoveryID)
            if AutomationBridge.shared.activeDocument === document {
                AutomationBridge.shared.activeDocument = nil
            }
        }
    }

    private func recoverPendingDocument() {
        guard let url = pendingRecoveryURL,
              let archive = try? RecoveryStore.load(url) else { return }
        document.restoreRecovery(archive)
        try? RecoveryStore.discard(url)
        pendingRecoveryURL = nil
    }

    private func discardPendingRecovery() {
        if let url = pendingRecoveryURL { try? RecoveryStore.discard(url) }
        pendingRecoveryURL = nil
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
            .help("Reroll Seed (⌘R)")

            Button {
                rerollSelected(randomizeParams: true)
            } label: {
                Label("Randomize", systemImage: "sparkles")
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(selectedPatternLayerID == nil)
            .help("Randomize (⌥⌘R)")

            Button {
                editorState.showExportSheet = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .keyboardShortcut("e", modifiers: .command)
            .help("Export (⌘E)")

            Menu {
                Button("Share Rendered PNG…") { shareRenderedArtwork() }
                Button("Print…") { printArtwork() }
                    .keyboardShortcut("p", modifiers: .command)
                Divider()
                Button("Show Welcome") { didCompleteOnboarding = false }
            } label: {
                // Tall stacked glyphs overflow the compact toolbar capsule at
                // the default scale; shrink them so they sit inside it.
                Label {
                    Text("Share")
                } icon: {
                    Image(systemName: "square.and.arrow.up.on.square").imageScale(.small)
                }
            }

            Menu {
                if editorState.isRecordingAction {
                    Button("Stop Recording") {
                        editorState.recordedActions.append(document.actionRecorder.stop(name: "Recorded Action"))
                        editorState.isRecordingAction = false
                    }
                } else {
                    Button("Start Recording") {
                        document.actionRecorder.start()
                        editorState.isRecordingAction = true
                    }
                }
                Divider()
                ForEach(editorState.recordedActions) { action in
                    Button("Run \(action.name)") {
                        document.update(undoManager, actionName: action.name) {
                            ActionExecutor.apply(action, to: &$0)
                        }
                    }
                }
            } label: {
                Label {
                    Text(editorState.isRecordingAction ? "Recording" : "Actions")
                } icon: {
                    Image(systemName: editorState.isRecordingAction ? "record.circle.fill" : "play.square.stack")
                        .imageScale(.small)
                }
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
        let inches = document.model.printSettings.physicalSize(for: document.model.canvasSize)
        let printSize = CGSize(width: inches.width * 72, height: inches.height * 72)
        let view = NSImageView(frame: CGRect(origin: .zero, size: printSize))
        view.image = NSImage(cgImage: image, size: printSize)
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
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("PixelFailure")
                    .font(.system(size: 22, weight: .semibold))
                Text("Generative artwork, images, and vectors in one layered canvas.")
                    .foregroundStyle(Theme.textDim)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                onboardingRow("dice", "⌘R", "Reroll a pattern")
                onboardingRow("cursorarrow", "V  B  P", "Move, brush, pen")
                onboardingRow("square.2.layers.3d", "⌘G", "Group layers")
                onboardingRow("square.and.arrow.up", "⌘E", "Export PNG, SVG, PDF, PSD")
            }
            HStack {
                Spacer()
                Button("Get Started", action: complete)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 420)
    }

    @ViewBuilder
    private func onboardingRow(_ icon: String, _ keys: String, _ detail: String) -> some View {
        GridRow {
            Image(systemName: icon)
                .foregroundStyle(Theme.icon)
                .frame(width: 20)
            Text(keys)
                .font(.system(size: 11, weight: .medium).monospaced())
                .foregroundStyle(Theme.textDim)
            Text(detail)
        }
    }
}
