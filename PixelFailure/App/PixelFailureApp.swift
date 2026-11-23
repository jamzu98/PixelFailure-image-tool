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
            EditorView(document: configuration.document, fileURL: configuration.fileURL)
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

        Settings {
            SettingsView()
        }
        .windowResizability(.contentSize)

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

/// A menu item bound to a rebindable command.
struct ActionButton: View {
    let action: ShortcutAction
    let focus: EditorFocus?
    var title: String?

    init(_ action: ShortcutAction, _ focus: EditorFocus?, title: String? = nil) {
        self.action = action
        self.focus = focus
        self.title = title
    }

    var body: some View {
        Button(title ?? action.title) {
            if let focus { EditorActions.perform(action, focus) }
        }
        .keyboardShortcut(ShortcutStore.shared.menuShortcut(action))
        .disabled(!EditorActions.canPerform(action, focus))
    }
}

/// A checkable menu item bound to a rebindable toggle command.
struct ActionToggle: View {
    let action: ShortcutAction
    let focus: EditorFocus?
    let isOn: Bool

    init(_ action: ShortcutAction, _ focus: EditorFocus?, isOn: Bool) {
        self.action = action
        self.focus = focus
        self.isOn = isOn
    }

    var body: some View {
        Toggle(action.title, isOn: Binding(
            get: { isOn },
            set: { _ in if let focus { EditorActions.perform(action, focus) } }
        ))
        .keyboardShortcut(ShortcutStore.shared.menuShortcut(action))
        .disabled(focus == nil)
    }
}

/// App-level menu item (works with no document open).
private struct AppActionButton: View {
    let action: ShortcutAction
    let perform: () -> Void

    var body: some View {
        Button(action.title, action: perform)
            .keyboardShortcut(ShortcutStore.shared.menuShortcut(action))
    }
}

struct FileCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.newDocument) private var newDocument
    @Environment(\.openDocument) private var openDocument
    @Environment(\.dismissWindow) private var dismissWindow
    @FocusedValue(\.editorFocus) private var focus

    private var launcher: DocumentLauncher {
        DocumentLauncher(newDocument: newDocument, openDocument: openDocument)
    }

    var body: some Commands {
        let _ = ExternalOpenRouter.shared.install(
            DocumentLauncher(newDocument: newDocument, openDocument: openDocument) {
                dismissWindow(id: HomeModel.windowID)
            })
        CommandGroup(replacing: .newItem) {
            AppActionButton(action: .newDocument) { HomeModel.shared.show(.new, using: openWindow) }
            AppActionButton(action: .newBlankCanvas) {
                var settings = NewDocumentStore.shared.lastUsed
                settings.name = "Untitled"
                settings.starterGenerator = nil
                launcher.create(settings)
            }
            AppActionButton(action: .showHome) { HomeModel.shared.show(.home, using: openWindow) }
        }
        // SwiftUI keeps its own Open… / Open Recent for projects; images
        // open as a new canvas of their own size, as in Photoshop.
        CommandGroup(after: .newItem) {
            AppActionButton(action: .openImageAsCanvas) { launcher.presentOpenPanel() }
        }
        CommandGroup(after: .saveItem) {
            ActionButton(.export, focus)
        }
    }
}

struct ViewCommands: Commands {
    @FocusedValue(\.editorFocus) private var focus

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            ActionButton(.zoomIn, focus)
            ActionButton(.zoomOut, focus)
            ActionButton(.fitOnScreen, focus)
            ActionButton(.actualPixels, focus)
            ActionButton(.resetViewRotation, focus)
            Divider()
            let workspace = focus?.document.model.workspace
            ActionToggle(.toggleRulers, focus, isOn: workspace?.showsRulers ?? false)
            ActionToggle(.toggleGrid, focus, isOn: workspace?.grid.isVisible ?? false)
            ActionToggle(.toggleGuides, focus, isOn: focus?.editorState.showsGuides ?? true)
            ActionToggle(.toggleSmartGuides, focus, isOn: workspace?.smartGuidesEnabled ?? false)
            ActionToggle(.toggleSnap, focus, isOn: workspace?.grid.snapsToGrid ?? false)
            ActionButton(.clearGuides, focus)
            Divider()
            ActionToggle(.toggleNavigator, focus, isOn: workspace?.showsNavigator ?? false)
            ActionToggle(.togglePanels, focus, isOn: !(focus?.editorState.panelsHidden ?? false))
            Divider()
        }
    }
}

struct EditorCommands: Commands {
    @FocusedValue(\.editorFocus) private var focus

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            ActionButton(.fillForeground, focus)
            ActionButton(.fillBackground, focus)
            ActionButton(.freeTransform, focus)
            ActionButton(.deselectLayers, focus)
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
            ActionButton(.selectAll, focus)
            ActionButton(.deselect, focus)
            ActionButton(.reselect, focus)
            ActionButton(.invertSelection, focus)
            ActionButton(.selectAllLayers, focus)

            Divider()

            ActionButton(.selectSubject, focus, title: "Subject")
            Button("Background") {
                guard let focus else { return }
                focus.editorState.vision.selectSubject(inverted: true, focus: focus)
            }
            .disabled(focus == nil)
            Button("People") {
                guard let focus else { return }
                focus.editorState.vision.selectPeople(focus: focus)
            }
            .disabled(focus == nil)
            Menu("Faces") {
                ForEach([("Face", FaceFeatures.face), ("Face Skin", .skin), ("Eyes", .eyes),
                         ("Eyebrows", .brows), ("Lips", .lips), ("Nose", .nose), ("Pupils", .pupils)],
                        id: \.0) { item in
                    Button(item.0) {
                        guard let focus else { return }
                        focus.editorState.vision.selectFaces(item.1, focus: focus)
                    }
                }
            }
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

            ActionButton(.fillForeground, focus, title: "Fill Selection with Foreground Color")

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

}

struct LayerCommands: Commands {
    @FocusedValue(\.editorFocus) private var focus

    var body: some Commands {
        CommandMenu("Layer") {
            Menu("New") {
                if let focus {
                    Menu("Pattern") {
                        GeneratorMenuItems { type in
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
            ActionButton(.newLayer, focus, title: "New Paint Layer")
            ActionButton(.duplicateLayer, focus)

            Divider()

            ActionButton(.reroll, focus)
            ActionButton(.randomize, focus)

            Divider()

            ActionButton(.groupLayers, focus)
            ActionButton(.ungroup, focus)
            ActionButton(.clippingMask, focus)

            Menu("Arrange") {
                ActionButton(.bringToFront, focus)
                ActionButton(.bringForward, focus)
                ActionButton(.sendBackward, focus)
                ActionButton(.sendToBack, focus)
                Divider()
                ActionButton(.selectLayerAbove, focus)
                ActionButton(.selectLayerBelow, focus)
            }
            .disabled(focus == nil)

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

            ActionButton(.rasterize, focus)

            Button("Super Resolution 2×") {
                guard let focus, let id = focus.editorState.selectedLayerID else { return }
                let outcome = focus.document.superResolveLayer(layerID: id, renderStore: focus.renderStore,
                                                               undoManager: focus.undoManager)
                if outcome == .tooLarge {
                    let alert = NSAlert()
                    alert.messageText = "Layer Too Large"
                    alert.informativeText = "Super Resolution output is limited to \(PixelDocument.superResolutionMaxDimension) px on the long side."
                    alert.runModal()
                }
            }
            .disabled(focus?.editorState.selectedLayerID.flatMap {
                focus?.document.model.layer(id: $0)?.kind.isImage
            } != true)

            ActionButton(.flipHorizontal, focus)
            ActionButton(.flipVertical, focus)
            ActionButton(.lockLayer, focus)
            ActionButton(.toggleVisibility, focus)

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

            ActionButton(.deleteLayer, focus)
        }
    }
}
