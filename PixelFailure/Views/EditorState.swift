import SwiftUI

/// The viewport tools, Photoshop-style.
enum EditorTool: String, CaseIterable, Identifiable {
    case move, marquee, lasso, wand, objectSelect, hand, zoom, eyedropper, brush, eraser, crop
    case clone, heal, smudge, dodge, burn
    case pen, node

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .move: "Move"
        case .marquee: "Marquee Select"
        case .lasso: "Lasso Select"
        case .wand: "Magic Wand"
        case .objectSelect: "Object Select"
        case .hand: "Hand"
        case .zoom: "Zoom"
        case .eyedropper: "Eyedropper"
        case .brush: "Brush"
        case .eraser: "Eraser"
        case .crop: "Crop"
        case .clone: "Clone Stamp"
        case .heal: "Healing Brush"
        case .smudge: "Smudge"
        case .dodge: "Dodge"
        case .burn: "Burn"
        case .pen: "Pen"
        case .node: "Node Edit"
        }
    }

    var systemImage: String {
        switch self {
        case .move: "cursorarrow"
        case .marquee: "rectangle.dashed"
        case .lasso: "lasso"
        case .wand: "wand.and.rays"
        case .objectSelect: "sparkles.rectangle.stack"
        case .hand: "hand.raised"
        case .zoom: "magnifyingglass"
        case .eyedropper: "eyedropper"
        case .brush: "paintbrush.pointed"
        case .eraser: "eraser"
        case .crop: "crop"
        case .clone: "square.on.square"
        case .heal: "bandage"
        case .smudge: "drop.degreesign"
        case .dodge: "sun.max"
        case .burn: "flame"
        case .pen: "pencil.tip.crop.circle"
        case .node: "point.topleft.down.to.point.bottomright.curvepath"
        }
    }

    var shortcutKey: Character {
        switch self {
        case .move: "v"
        case .marquee: "m"
        case .lasso: "l"
        case .wand: "w"
        case .objectSelect: "q"
        case .hand: "h"
        case .zoom: "z"
        case .eyedropper: "i"
        case .brush: "b"
        case .eraser: "e"
        case .crop: "c"
        case .clone: "s"
        case .heal: "j"
        case .smudge: "r"
        case .dodge: "o"
        case .burn: "u"
        case .pen: "p"
        case .node: "a"
        }
    }

    var isSelectionTool: Bool {
        self == .marquee || self == .lasso || self == .wand || self == .objectSelect
    }
}

nonisolated struct PointerSample: Sendable {
    var location: CGPoint
    var pressure: Double
    var tilt: CGSize
    var timestamp: TimeInterval
}

nonisolated struct BrushPreset: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let size: Double
    let hardness: Double
    let opacity: Double
    let spacing: Double
    let smoothing: Double
    let scatter: Double
    let sizeJitter: Double
    let opacityJitter: Double
    let angleJitter: Double
    let tipAspect: Double
    let grain: Double

    init(id: String, name: String, size: Double, hardness: Double, opacity: Double,
         spacing: Double, smoothing: Double, scatter: Double, sizeJitter: Double,
         opacityJitter: Double, angleJitter: Double = 0, tipAspect: Double = 1,
         grain: Double = 0) {
        self.id = id; self.name = name; self.size = size; self.hardness = hardness
        self.opacity = opacity; self.spacing = spacing; self.smoothing = smoothing
        self.scatter = scatter; self.sizeJitter = sizeJitter; self.opacityJitter = opacityJitter
        self.angleJitter = angleJitter; self.tipAspect = tipAspect; self.grain = grain
    }

    static let builtIns: [BrushPreset] = [
        BrushPreset(id: "soft", name: "Soft Round", size: 120, hardness: 0.2, opacity: 0.55,
                    spacing: 0.16, smoothing: 0.35, scatter: 0, sizeJitter: 0, opacityJitter: 0),
        BrushPreset(id: "hard", name: "Hard Round", size: 70, hardness: 0.95, opacity: 1,
                    spacing: 0.12, smoothing: 0.18, scatter: 0, sizeJitter: 0, opacityJitter: 0),
        BrushPreset(id: "texture", name: "Scatter", size: 90, hardness: 0.7, opacity: 0.65,
                    spacing: 0.35, smoothing: 0.1, scatter: 0.8, sizeJitter: 0.45, opacityJitter: 0.35,
                    angleJitter: 1, tipAspect: 0.55, grain: 0.45),
        BrushPreset(id: "ink", name: "Smooth Ink", size: 28, hardness: 0.9, opacity: 0.9,
                    spacing: 0.08, smoothing: 0.75, scatter: 0, sizeJitter: 0.08, opacityJitter: 0.08),
    ]
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
    var spacing = 0.15
    var smoothing = 0.25
    var scatter = 0.0
    var sizeJitter = 0.0
    var opacityJitter = 0.0
    var angleJitter = 0.0
    var tipAspect = 1.0
    var grain = 0.0
    var pressureControlsSize = true
    var pressureControlsOpacity = false
    var selectedPresetID = "soft"
    var customPresets: [BrushPreset] = []
    var presets: [BrushPreset] { BrushPreset.builtIns + customPresets }

    func apply(_ preset: BrushPreset) {
        selectedPresetID = preset.id
        size = preset.size
        hardness = preset.hardness
        opacity = preset.opacity
        spacing = preset.spacing
        smoothing = preset.smoothing
        scatter = preset.scatter
        sizeJitter = preset.sizeJitter
        opacityJitter = preset.opacityJitter
        angleJitter = preset.angleJitter
        tipAspect = preset.tipAspect
        grain = preset.grain
    }
}

/// Per-window UI state that isn't part of the document.
@Observable
final class EditorState {
    /// Multi-selection. Most single-layer flows use `selectedLayerID`, which
    /// is non-nil exactly when one layer is selected.
    var selectedLayerIDs: Set<UUID> = []

    var selectedLayerID: UUID? {
        get { selectedLayerIDs.count == 1 ? selectedLayerIDs.first : nil }
        set { selectedLayerIDs = newValue.map { [$0] } ?? [] }
    }

    /// Groups whose children are shown in the sidebar.
    var expandedGroups: Set<UUID> = []

    var showExportSheet = false
    var showImageImporter = false

    /// Non-persisted animation authoring state for this editor window.
    var animationLayerID: UUID?
    var animationPlayhead = 0.0
    var selectedAnimationKeyframeID: UUID?
    var isAnimationPlaying = false
    var isAnimationScrubbing = false

    var activeTool: EditorTool = .move
    var brush = BrushSettings()
    /// View-only canvas rotation used while drawing; never serialized.
    var canvasRotationDegrees = 0.0
    var isRecordingAction = false
    var recordedActions: [RecordedAction] = []

    /// Which palette swatch the eyedropper replaces next (wraps around).
    var eyedropperSwatchIndex = 0

    /// When set, brush strokes edit this layer's mask instead of its content.
    var editingMaskLayerID: UUID?
    /// While mask editing: true = brush reveals (paints white), false = hides.
    var maskBrushReveals = false

    /// In-flight crop rectangle in canvas coordinates (crop tool).
    var cropDraft: CGRect?
    var pointerSample = PointerSample(location: .zero, pressure: 1, tilt: .zero, timestamp: 0)
    var cloneSourceCanvas: CGPoint?

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
    /// Vision-backed smart selection (Select Subject, Object Select tool).
    let vision = VisionSelectionController()

    /// Transient smart-guide feedback while moving a layer.
    var smartGuideX: Double?
    var smartGuideY: Double?
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
