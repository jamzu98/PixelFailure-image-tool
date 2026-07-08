import SwiftUI

@main
struct PixelFailureApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { PixelDocument() }) { configuration in
            EditorView(document: configuration.document)
        }
        .commands {
            EditorCommands()
        }
    }
}

struct EditorCommands: Commands {
    @FocusedValue(\.editorState) private var editorState

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Deselect") {
                editorState?.selectedLayerID = nil
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(editorState?.selectedLayerID == nil)
        }
    }
}
