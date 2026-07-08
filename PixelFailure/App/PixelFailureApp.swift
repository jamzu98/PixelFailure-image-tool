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
