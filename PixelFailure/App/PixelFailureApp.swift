import SwiftUI

@main
struct PixelFailureApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { PixelDocument() }) { configuration in
            EditorView(document: configuration.document)
        }
        .commands {
            EditorCommands()
            LayerCommands()
            SelectCommands()
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
              layer.kind.isImage, !layer.isLocked else { return nil }
        return layer
    }

    var body: some Commands {
        CommandMenu("Select") {
            Button("Select All") {
                guard let focus else { return }
                focus.editorState.selection = .all(canvasSize: focus.document.model.canvasSize)
            }
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
