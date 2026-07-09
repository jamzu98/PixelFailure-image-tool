import SwiftUI

/// The viewport tools, Photoshop-style.
enum EditorTool: String, CaseIterable, Identifiable {
    case move, hand, zoom, eyedropper, brush, eraser, crop

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .move: "Move"
        case .hand: "Hand"
        case .zoom: "Zoom"
        case .eyedropper: "Eyedropper"
        case .brush: "Brush"
        case .eraser: "Eraser"
        case .crop: "Crop"
        }
    }

    var systemImage: String {
        switch self {
        case .move: "cursorarrow"
        case .hand: "hand.raised"
        case .zoom: "magnifyingglass"
        case .eyedropper: "eyedropper"
        case .brush: "paintbrush.pointed"
        case .eraser: "eraser"
        case .crop: "crop"
        }
    }

    var shortcutKey: Character {
        switch self {
        case .move: "v"
        case .hand: "h"
        case .zoom: "z"
        case .eyedropper: "i"
        case .brush: "b"
        case .eraser: "e"
        case .crop: "c"
        }
    }
}

/// Brush parameters shared by the brush and eraser tools.
@Observable
final class BrushSettings {
    /// Diameter in canvas pixels.
    var size: Double = 120
    /// 0 = soft falloff, 1 = hard edge.
    var hardness: Double = 0.6
    var opacity: Double = 1.0
    var color = RGBAColor(hex: "#EFE8D8")
}

/// Per-window UI state that isn't part of the document.
@Observable
final class EditorState {
    var selectedLayerID: UUID?
    var showExportSheet = false
    var showImageImporter = false

    var activeTool: EditorTool = .move
    var brush = BrushSettings()

    /// Which palette swatch the eyedropper replaces next (wraps around).
    var eyedropperSwatchIndex = 0

    /// When set, brush strokes edit this layer's mask instead of its content.
    var editingMaskLayerID: UUID?
    /// While mask editing: true = brush reveals (paints white), false = hides.
    var maskBrushReveals = false

    /// In-flight crop rectangle in canvas coordinates (crop tool).
    var cropDraft: CGRect?
}

/// Lets app-level menu commands reach the focused window's editor context.
struct EditorFocus {
    let document: PixelDocument
    let editorState: EditorState
    let renderStore: RenderStore
    let undoManager: UndoManager?
}

extension FocusedValues {
    @Entry var editorFocus: EditorFocus?
}
