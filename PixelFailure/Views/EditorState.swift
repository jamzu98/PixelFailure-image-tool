import SwiftUI

/// The viewport tools, Photoshop-style.
enum EditorTool: String, CaseIterable, Identifiable {
    case move, marquee, lasso, wand, hand, zoom, eyedropper, brush, eraser, crop

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .move: "Move"
        case .marquee: "Marquee Select"
        case .lasso: "Lasso Select"
        case .wand: "Magic Wand"
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
        case .marquee: "rectangle.dashed"
        case .lasso: "lasso"
        case .wand: "wand.and.rays"
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
        case .marquee: "m"
        case .lasso: "l"
        case .wand: "w"
        case .hand: "h"
        case .zoom: "z"
        case .eyedropper: "i"
        case .brush: "b"
        case .eraser: "e"
        case .crop: "c"
        }
    }

    var isSelectionTool: Bool {
        self == .marquee || self == .lasso || self == .wand
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

    // MARK: Selections

    /// The active selection (canvas space). Session state, like in most
    /// editors — not part of the document.
    var selection: CanvasSelection?
    /// Live preview path while a marquee/lasso gesture is in flight.
    var selectionDraft: Path?
    /// Vertices collected by the polygonal lasso (nil = not building one).
    var lassoVertices: [CGPoint]?
    /// Marquee shape: false = rectangle, true = ellipse.
    var marqueeEllipse = false
    /// Lasso mode: false = freehand, true = polygonal (click to add points).
    var lassoPolygonal = false
    /// Magic wand color tolerance (0...1).
    var wandTolerance = 0.25
    /// Feather (canvas px) applied to newly created selections.
    var featherDefault = 0.0
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
