import SwiftUI

/// Per-window UI state that isn't part of the document.
@Observable
final class EditorState {
    var selectedLayerID: UUID?
    var showExportSheet = false
    var showImageImporter = false
}
