import AppKit
import SwiftUI

@main
struct PixelFailureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // A pro editor runs dark regardless of the system appearance, so
        // artwork colors are judged against neutral gray chrome.
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        TitlebarClickThrough.install()
    }

    var body: some Scene {
        DocumentGroup(newDocument: {
            PixelDocument(model: NewDocumentStore.loadLastUsed().makeModel())
        }) { configuration in
            EditorView(document: configuration.document)
        }
        .defaultSize(width: 1440, height: 900)
        // One slim bar: title and toolbar items share a single compact row.
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))
        .commands {
            FileCommands()
            EditorCommands()
            ViewCommands()
            LayerCommands()
            SelectCommands()
        }

        Window("Home", id: HomeModel.windowID) {
            HomeView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .defaultLaunchBehavior(LaunchAction.current == .home ? .presented : .suppressed)
        .restorationBehavior(.disabled)
        .commandsRemoved()
    }
}

struct FileCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.newDocument) private var newDocument
    @Environment(\.openDocument) private var openDocument

    private var launcher: DocumentLauncher {
        DocumentLauncher(newDocument: newDocument, openDocument: openDocument)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New…") { HomeModel.shared.show(.new, using: openWindow) }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Blank Canvas") {
                var settings = NewDocumentStore.shared.lastUsed
                settings.name = "Untitled"
                settings.starterGenerator = nil
                launcher.create(settings)
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            Button("Home") { HomeModel.shared.show(.home, using: openWindow) }
        }
        // SwiftUI keeps its own Open… / Open Recent for projects; images
        // open as a new canvas of their own size, as in Photoshop.
        CommandGroup(after: .newItem) {
            Button("Open Image as Canvas…") { launcher.presentOpenPanel() }
                .keyboardShortcut("o", modifiers: [.command, .option])
        }
    }
}

struct ViewCommands: Commands {
    @FocusedValue(\.editorFocus) private var focus

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Toggle("Show Navigator", isOn: Binding(
                get: { focus?.document.model.workspace.showsNavigator ?? false },
                set: { value in
                    guard let focus else { return }
                    focus.document.update(focus.undoManager, actionName: "Toggle Navigator") {
                        $0.workspace.showsNavigator = value
                    }
                }
            ))
            .disabled(focus == nil)
        }
    }
}

struct EditorCommands: Commands {
    @FocusedValue(\.editorFocus) private var focus

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Deselect") {
                focus?.editorState.selectedLayerID = nil
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(focus?.editorState.selectedLayerID == nil)
        }
    }
}

struct SelectCommands: Commands {
    @FocusedValue(\.editorFocus) private var focus

    private var hasSelection: Bool { focus?.editorState.selection != nil }
    private var selectedImageLayer: Layer? {
        guard let focus,
              let layer = focus.document.model.layer(id: focus.editorState.selectedLayerID),
              layer.kind.isImage,
              !focus.document.model.isEffectivelyLocked(layer.id) else { return nil }
        return layer
    }

    var body: some Commands {
        CommandMenu("Select") {
            Button("Select All") {
                guard let focus else { return }
                focus.editorState.selection = .all(canvasSize: focus.document.model.canvasSize)
            }
            .keyboardShortcut("a", modifiers: .command)
            .disabled(focus == nil)

            Button("Deselect") {
                focus?.editorState.selection = nil
            }
            .disabled(!hasSelection)

            Button("Invert Selection") {
                guard let focus, let selection = focus.editorState.selection else { return }
                focus.editorState.selection = selection.inverted(canvasSize: focus.document.model.canvasSize)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(!hasSelection)

            Divider()

            Button("Select Subject") { selectForeground(inverted: false) }
                .disabled(focus == nil)
            Button("Select Background") { selectForeground(inverted: true) }
                .disabled(focus == nil)

            Divider()

            Menu("Feather") {
                ForEach([0.0, 2, 5, 10, 25, 50], id: \.self) { radius in
                    Button(radius == 0 ? "None" : "\(Int(radius)) px") {
                        focus?.editorState.selection?.feather = radius
                        focus?.editorState.featherDefault = radius
                    }
                }
            }
            .disabled(!hasSelection)

            Menu("Expand") {
                ForEach([2.0, 5, 10, 25, 50], id: \.self) { amount in
                    Button("\(Int(amount)) px") {
                        guard let focus, let selection = focus.editorState.selection else { return }
                        focus.editorState.selection = SelectionTransforms.offset(
                            selection, by: amount, canvasSize: focus.document.model.canvasSize)
                    }
                }
            }
            .disabled(!hasSelection)

            Menu("Contract") {
                ForEach([2.0, 5, 10, 25, 50], id: \.self) { amount in
                    Button("\(Int(amount)) px") {
                        guard let focus, let selection = focus.editorState.selection else { return }
                        focus.editorState.selection = SelectionTransforms.offset(
                            selection, by: -amount, canvasSize: focus.document.model.canvasSize)
                    }
                }
            }
            .disabled(!hasSelection)

            Divider()

            Button("New Layer from Selection") {
                guard let focus, let selection = focus.editorState.selection,
                      let layer = selectedImageLayer else { return }
                if let id = focus.document.layerFromSelection(selection, layerID: layer.id,
                                                              renderStore: focus.renderStore,
                                                              undoManager: focus.undoManager) {
                    focus.editorState.selectedLayerID = id
                }
            }
            .disabled(!hasSelection || selectedImageLayer == nil)

            Button("Mask from Selection") {
                guard let focus, let selection = focus.editorState.selection,
                      let id = focus.editorState.selectedLayerID else { return }
                focus.document.maskFromSelection(selection, layerID: id,
                                                 renderStore: focus.renderStore,
                                                 undoManager: focus.undoManager)
            }
            .disabled(!hasSelection || focus?.editorState.selectedLayerID == nil)

            Button("Fill Selection with Brush Color") {
                guard let focus, let selection = focus.editorState.selection,
                      let layer = selectedImageLayer else { return }
                focus.document.fillPixels(selection: selection, layerID: layer.id,
                                          color: focus.editorState.brush.color,
                                          renderStore: focus.renderStore,
                                          undoManager: focus.undoManager)
            }
            .disabled(!hasSelection || selectedImageLayer == nil)

            Button("Delete Selected Pixels") {
                guard let focus, let selection = focus.editorState.selection,
                      let layer = selectedImageLayer else { return }
                focus.document.deletePixels(selection: selection, layerID: layer.id,
                                            renderStore: focus.renderStore,
                                            undoManager: focus.undoManager)
            }
            .disabled(!hasSelection || selectedImageLayer == nil)

            Button("Content-Aware Fill") {
                guard let focus, let selection = focus.editorState.selection,
                      let layer = selectedImageLayer else { return }
                focus.document.contentAwareFill(selection: selection, layerID: layer.id,
                                                renderStore: focus.renderStore,
                                                undoManager: focus.undoManager)
            }
            .disabled(!hasSelection || selectedImageLayer == nil)
        }
    }

    private func selectForeground(inverted: Bool) {
        guard let focus,
              let image = PNGExporter.render(
                items: focus.renderStore.renderItems(model: focus.document.model, quality: .preview),
                background: focus.document.model.background,
                canvasSize: focus.document.model.canvasSize,
                targetPixelSize: focus.document.model.canvasSize) else { return }
        do {
            let foreground = try SmartSelection.foreground(in: image,
                                                            canvasSize: focus.document.model.canvasSize)
            focus.editorState.selection = inverted
                ? foreground.inverted(canvasSize: focus.document.model.canvasSize)
                : foreground
        } catch {
            NSSound.beep()
        }
    }
}

struct LayerCommands: Commands {
    @FocusedValue(\.editorFocus) private var focus

    var body: some Commands {
        CommandMenu("Layer") {
            Menu("New") {
                if let focus {
                    Menu("Pattern") {
                        ForEach(GeneratorType.allCases, id: \.self) { type in
                            Button(type.displayName) {
                                focus.editorState.selectedLayerID =
                                    focus.document.addPatternLayer(type, undoManager: focus.undoManager)
                            }
                        }
                    }
                    Button("Image…") {
                        focus.editorState.showImageImporter = true
                    }
                    Button("Text") {
                        focus.editorState.selectedLayerID = focus.document.addTextLayer(undoManager: focus.undoManager)
                    }
                    Button("Fill / Gradient") {
                        focus.editorState.selectedLayerID = focus.document.addFillLayer(undoManager: focus.undoManager)
                    }
                    Menu("Shape") {
                        ForEach(ShapeKind.allCases, id: \.self) { kind in
                            Button(kind.displayName) {
                                focus.editorState.selectedLayerID =
                                    focus.document.addShapeLayer(kind, undoManager: focus.undoManager)
                            }
                        }
                    }
                    Button("Paint Layer") {
                        focus.editorState.selectedLayerID = focus.document.addPaintLayer(undoManager: focus.undoManager)
                    }
                    Button("Adjustment Layer") {
                        focus.editorState.selectedLayerID = focus.document.addAdjustmentLayer(undoManager: focus.undoManager)
                    }
                    Button("Path") {
                        focus.editorState.selectedLayerID = focus.document.addPathLayer(undoManager: focus.undoManager)
                    }
                }
            }
            .disabled(focus == nil)

            Divider()

            Button("Group Layers") {
                guard let focus, !focus.editorState.selectedLayerIDs.isEmpty else { return }
                if let id = focus.document.groupLayers(ids: focus.editorState.selectedLayerIDs,
                                                       undoManager: focus.undoManager) {
                    focus.editorState.selectedLayerID = id
                }
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(focus?.editorState.selectedLayerIDs.isEmpty ?? true)

            Button("Ungroup") {
                guard let focus, let id = focus.editorState.selectedLayerID else { return }
                focus.document.ungroup(id: id, undoManager: focus.undoManager)
                focus.editorState.selectedLayerIDs = []
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(focus?.editorState.selectedLayerID.flatMap {
                focus?.document.model.layer(id: $0)?.kind.isGroup
            } != true)

            Menu("Align") {
                ForEach(PixelDocument.AlignEdge.allCases, id: \.self) { edge in
                    Button(edge.displayName) {
                        guard let focus else { return }
                        focus.document.alignLayers(ids: focus.editorState.selectedLayerIDs, edge: edge,
                                                   renderStore: focus.renderStore,
                                                   undoManager: focus.undoManager)
                    }
                }
            }
            .disabled(focus?.editorState.selectedLayerIDs.isEmpty ?? true)

            Menu("Distribute") {
                Button("Horizontally") {
                    guard let focus else { return }
                    focus.document.distributeLayers(ids: focus.editorState.selectedLayerIDs, horizontally: true,
                                                    renderStore: focus.renderStore, undoManager: focus.undoManager)
                }
                Button("Vertically") {
                    guard let focus else { return }
                    focus.document.distributeLayers(ids: focus.editorState.selectedLayerIDs, horizontally: false,
                                                    renderStore: focus.renderStore, undoManager: focus.undoManager)
                }
            }
            .disabled((focus?.editorState.selectedLayerIDs.count ?? 0) < 3)

            Divider()

            Button("Duplicate Layer") {
                guard let focus, let id = focus.editorState.selectedLayerID else { return }
                focus.editorState.selectedLayerID = focus.document.duplicateLayer(id: id, undoManager: focus.undoManager)
            }
            .keyboardShortcut("j", modifiers: .command)
            .disabled(focus?.editorState.selectedLayerID == nil)

            Button("Rasterize Layer") {
                guard let focus, let id = focus.editorState.selectedLayerID else { return }
                focus.document.rasterizeLayer(id: id, renderStore: focus.renderStore, undoManager: focus.undoManager)
            }
            .disabled(focus?.editorState.selectedLayerID == nil)

            Button("Super Resolution 2×") {
                guard let focus, let id = focus.editorState.selectedLayerID else { return }
                focus.document.superResolveLayer(layerID: id, renderStore: focus.renderStore,
                                                 undoManager: focus.undoManager)
            }
            .disabled(focus?.editorState.selectedLayerID.flatMap {
                focus?.document.model.layer(id: $0)?.kind.isImage
            } != true)

            Button("Flip Horizontal") {
                guard let focus, let id = focus.editorState.selectedLayerID else { return }
                focus.document.flipLayer(id: id, horizontally: true, undoManager: focus.undoManager)
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(focus?.editorState.selectedLayerID == nil)

            Button("Flip Vertical") {
                guard let focus, let id = focus.editorState.selectedLayerID else { return }
                focus.document.flipLayer(id: id, horizontally: false, undoManager: focus.undoManager)
            }
            .disabled(focus?.editorState.selectedLayerID == nil)

            Button("Lock/Unlock Layer") {
                guard let focus, let id = focus.editorState.selectedLayerID else { return }
                focus.document.toggleLock(id: id, undoManager: focus.undoManager)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(focus?.editorState.selectedLayerID == nil)

            Menu("Add Mask") {
                Button("Reveal All") {
                    guard let focus, let id = focus.editorState.selectedLayerID else { return }
                    focus.document.addMask(to: id, hideAll: false, renderStore: focus.renderStore,
                                           undoManager: focus.undoManager)
                }
                Button("Hide All") {
                    guard let focus, let id = focus.editorState.selectedLayerID else { return }
                    focus.document.addMask(to: id, hideAll: true, renderStore: focus.renderStore,
                                           undoManager: focus.undoManager)
                }
            }
            .disabled(focus?.editorState.selectedLayerID == nil)

            Divider()

            Button("Delete Layer") {
                guard let focus, let id = focus.editorState.selectedLayerID else { return }
                focus.document.deleteLayer(id: id, undoManager: focus.undoManager)
                focus.editorState.selectedLayerID = nil
            }
            .disabled(focus?.editorState.selectedLayerID == nil)
        }
    }
}
