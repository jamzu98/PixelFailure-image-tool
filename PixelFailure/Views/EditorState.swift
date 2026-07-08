import SwiftUI

/// Per-window UI state that isn't part of the document.
@Observable
final class EditorState {
    var selectedLayerID: UUID?
    var showExportSheet = false
    var showImageImporter = false
}

/// Lets app-level menu commands reach the focused window's editor state.
extension FocusedValues {
    @Entry var editorState: EditorState?
}
