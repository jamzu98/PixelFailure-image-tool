import CoreGraphics
import Foundation

nonisolated struct Layer: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var isVisible: Bool
    var opacity: Double
    var blendMode: LayerBlendMode
    var transform: LayerTransform
    var kind: LayerKind
    /// Optional so documents from before masks existed keep decoding.
    var mask: LayerMask?
    /// Locked layers can't be moved, transformed, or painted on.
    var isLocked: Bool
    /// Uses the alpha of the nearest visible sibling below as a clipping base.
    var clipsToBelow: Bool
    var styles: [LayerStyle]
    /// Snapshot taken the first time a destructive operation bakes this
    /// layer's pixels (rasterize, retouch, super-resolution, painting).
    /// Powers "Revert to Original" across sessions — the append-only image
    /// store keeps the referenced bytes alive.
    var source: LayerSource?

    init(id: UUID = UUID(),
         name: String,
         isVisible: Bool = true,
         opacity: Double = 1,
         blendMode: LayerBlendMode = .normal,
         transform: LayerTransform,
         kind: LayerKind,
         mask: LayerMask? = nil,
         isLocked: Bool = false,
         clipsToBelow: Bool = false,
         styles: [LayerStyle] = [],
         source: LayerSource? = nil) {
        self.id = id
        self.name = name
        self.isVisible = isVisible
        self.opacity = opacity
        self.blendMode = blendMode
        self.transform = transform
        self.kind = kind
        self.mask = mask
        self.isLocked = isLocked
        self.clipsToBelow = clipsToBelow
        self.styles = styles
        self.source = source
    }

    // Custom decoding so documents saved before isLocked existed still open.
    private enum CodingKeys: String, CodingKey {
        case id, name, isVisible, opacity, blendMode, transform, kind, mask, isLocked, clipsToBelow, styles, source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isVisible = try container.decode(Bool.self, forKey: .isVisible)
        opacity = try container.decode(Double.self, forKey: .opacity)
        blendMode = try container.decode(LayerBlendMode.self, forKey: .blendMode)
        transform = try container.decode(LayerTransform.self, forKey: .transform)
        kind = try container.decode(LayerKind.self, forKey: .kind)
        mask = try container.decodeIfPresent(LayerMask.self, forKey: .mask)
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        clipsToBelow = try container.decodeIfPresent(Bool.self, forKey: .clipsToBelow) ?? false
        styles = try container.decodeIfPresent([LayerStyle].self, forKey: .styles) ?? []
        source = try container.decodeIfPresent(LayerSource.self, forKey: .source)
    }
}

/// What a layer was before its pixels were first baked: the complete kind
/// (vector config or original image reference) plus the transform scale the
/// bake folded into pixels.
nonisolated struct LayerSource: Codable, Hashable, Sendable {
    var kind: LayerKind
    var scale: Double

    /// A short human-readable name for what reverting restores.
    var displayName: String {
        switch kind {
        case .pattern(let config): "the \(config.generator.displayName) generator"
        case .image: "the original image"
        case .text: "editable text"
        case .fill: "the fill layer"
        case .shape: "the editable shape"
        case .group: "the layer group"
        case .adjustment: "the adjustment layer"
        case .path: "the editable path"
        }
    }
}

nonisolated enum LayerKind: Codable, Hashable, Sendable {
    case pattern(PatternConfig)
    case image(ImageConfig)
    case text(TextConfig)
    case fill(FillConfig)
    case shape(ShapeConfig)
    case group(GroupConfig)
    case adjustment(AdjustmentConfig)
    case path(PathConfig)

    var isPattern: Bool { if case .pattern = self { true } else { false } }
    var isImage: Bool { if case .image = self { true } else { false } }
    var isText: Bool { if case .text = self { true } else { false } }
    var isFill: Bool { if case .fill = self { true } else { false } }
    var isShape: Bool { if case .shape = self { true } else { false } }
    var isGroup: Bool { if case .group = self { true } else { false } }
    var isAdjustment: Bool { if case .adjustment = self { true } else { false } }
    var isPath: Bool { if case .path = self { true } else { false } }

    var iconName: String {
        switch self {
        case .pattern: "circle.grid.3x3.fill"
        case .image: "photo"
        case .text: "textformat"
        case .fill: "rectangle.fill"
        case .shape: "square.on.circle"
        case .group: "folder"
        case .adjustment: "slider.horizontal.3"
        case .path: "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
}

nonisolated struct BezierNode: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var anchor: CGPoint
    var inControl: CGPoint
    var outControl: CGPoint

    init(id: UUID = UUID(), anchor: CGPoint, inControl: CGPoint? = nil,
         outControl: CGPoint? = nil) {
        self.id = id
        self.anchor = anchor
        self.inControl = inControl ?? anchor
        self.outControl = outControl ?? anchor
    }
}

nonisolated enum PathCommand: Codable, Hashable, Sendable {
    case move(CGPoint)
    case line(CGPoint)
    case quad(CGPoint, CGPoint)
    case cubic(CGPoint, CGPoint, CGPoint)
    case close
}

nonisolated struct PathConfig: Codable, Hashable, Sendable {
    var size: CGSize
    var nodes: [BezierNode]
    var commands: [PathCommand]?
    var isClosed: Bool
    var fill: RGBAColor?
    var stroke: RGBAColor?
    var strokeWidth: Double

    init(size: CGSize, nodes: [BezierNode] = [], commands: [PathCommand]? = nil,
         isClosed: Bool = false, fill: RGBAColor? = nil,
         stroke: RGBAColor? = RGBAColor(hex: "#EFE8D8"), strokeWidth: Double = 8) {
        self.size = size
        self.nodes = nodes
        self.commands = commands
        self.isClosed = isClosed
        self.fill = fill
        self.stroke = stroke
        self.strokeWidth = strokeWidth
    }
}

nonisolated struct AdjustmentConfig: Codable, Hashable, Sendable {
    var effects: [Effect]

    init(effects: [Effect] = [Effect(type: .adjust)]) {
        self.effects = effects
    }
}

nonisolated enum LayerStyleType: String, Codable, CaseIterable, Hashable, Sendable {
    case dropShadow, stroke, outerGlow

    var displayName: String {
        switch self {
        case .dropShadow: "Drop Shadow"
        case .stroke: "Stroke"
        case .outerGlow: "Outer Glow"
        }
    }
}

nonisolated struct LayerStyle: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var type: LayerStyleType
    var isEnabled: Bool
    var color: RGBAColor
    var size: Double
    var opacity: Double
    var offsetX: Double
    var offsetY: Double

    init(id: UUID = UUID(), type: LayerStyleType, isEnabled: Bool = true,
         color: RGBAColor = .black, size: Double = 16, opacity: Double = 0.6,
         offsetX: Double = 12, offsetY: Double = 12) {
        self.id = id
        self.type = type
        self.isEnabled = isEnabled
        self.color = color
        self.size = size
        self.opacity = opacity
        self.offsetX = offsetX
        self.offsetY = offsetY
    }
}

// MARK: - Group

/// A group of layers. Children live in the same coordinate space as root
/// layers (a group is a nested canvas); the group's own transform, opacity,
/// blend mode, and mask apply on top of the composited children.
nonisolated struct GroupConfig: Codable, Hashable, Sendable {
    /// Bottom-to-top, like the root list.
    var children: [Layer]

    init(children: [Layer] = []) {
        self.children = children
    }
}

// MARK: - Fill / gradient

nonisolated enum FillStyle: String, Codable, CaseIterable, Hashable, Sendable {
    case solid, linearGradient, radialGradient

    var displayName: String {
        switch self {
        case .solid: "Solid"
        case .linearGradient: "Linear Gradient"
        case .radialGradient: "Radial Gradient"
        }
    }
}

/// A canvas-filling solid color or gradient layer.
nonisolated struct FillConfig: Codable, Hashable, Sendable {
    var style: FillStyle
    /// Gradient stops in order (>= 1 color; solid uses the first).
    var colors: [RGBAColor]
    /// Linear gradient direction in degrees (0 = left→right).
    var angle: Double

    init(style: FillStyle = .linearGradient,
         colors: [RGBAColor] = [RGBAColor(hex: "#9C4A2F"), RGBAColor(hex: "#EAD7C2")],
         angle: Double = 90) {
        self.style = style
        self.colors = colors
        self.angle = angle
    }
}

// MARK: - Shape

nonisolated enum ShapeKind: String, Codable, CaseIterable, Hashable, Sendable {
    case rectangle, roundedRectangle, ellipse, line, polygon, star

    var displayName: String {
        switch self {
        case .rectangle: "Rectangle"
        case .roundedRectangle: "Rounded Rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .polygon: "Polygon"
        case .star: "Star"
        }
    }
}

/// A single vector shape layer — stays vector all the way to SVG.
nonisolated struct ShapeConfig: Codable, Hashable, Sendable {
    var kind: ShapeKind
    /// Natural size of the shape's bounding box.
    var size: CGSize
    var fill: RGBAColor?
    var stroke: RGBAColor?
    var strokeWidth: Double
    /// For roundedRectangle, as a fraction of the smaller dimension (0...0.5).
    var cornerRadius: Double
    /// For polygon/star.
    var sides: Int
    /// For star: inner radius as a fraction of the outer.
    var starInnerRatio: Double

    init(kind: ShapeKind = .rectangle,
         size: CGSize = CGSize(width: 800, height: 800),
         fill: RGBAColor? = RGBAColor(hex: "#C4744F"),
         stroke: RGBAColor? = nil,
         strokeWidth: Double = 12,
         cornerRadius: Double = 0.12,
         sides: Int = 6,
         starInnerRatio: Double = 0.45) {
        self.kind = kind
        self.size = size
        self.fill = fill
        self.stroke = stroke
        self.strokeWidth = strokeWidth
        self.cornerRadius = cornerRadius
        self.sides = sides
        self.starInnerRatio = starInnerRatio
    }
}

// MARK: - Mask

/// Grayscale mask stored in the document's image store.
/// White reveals, black hides (Photoshop convention).
nonisolated struct LayerMask: Codable, Hashable, Sendable {
    var imageKey: String
    var pixelSize: CGSize
    var isEnabled: Bool
    var inverted: Bool
    var pattern: PatternConfig?

    init(imageKey: String, pixelSize: CGSize, isEnabled: Bool = true, inverted: Bool = false,
         pattern: PatternConfig? = nil) {
        self.imageKey = imageKey
        self.pixelSize = pixelSize
        self.isEnabled = isEnabled
        self.inverted = inverted
        self.pattern = pattern
    }
}

// MARK: - Pattern

/// Which algorithmic generator a pattern layer uses. Cases only — the actual
/// generator implementations are registered in Generators/GeneratorRegistry.
nonisolated enum GeneratorType: String, Codable, CaseIterable, Hashable, Sendable {
    case gridLattice
    case phyllotaxis
    case flowField
    case truchet
    case waves
    case rings
    case sampledGrid
}

nonisolated struct PatternConfig: Codable, Hashable, Sendable {
    var generator: GeneratorType
    var seed: UInt64
    var params: ParamValues
    /// For image-driven generators: the image layer to sample.
    var sourceImageLayerID: UUID?

    init(generator: GeneratorType, seed: UInt64 = SeededRNG.randomSeed(), params: ParamValues = ParamValues(),
         sourceImageLayerID: UUID? = nil) {
        self.generator = generator
        self.seed = seed
        self.params = params
        self.sourceImageLayerID = sourceImageLayerID
    }

    private enum CodingKeys: String, CodingKey {
        case generator, seed, params, sourceImageLayerID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generator = try container.decode(GeneratorType.self, forKey: .generator)
        seed = try container.decode(UInt64.self, forKey: .seed)
        params = try container.decodeIfPresent(ParamValues.self, forKey: .params) ?? ParamValues()
        sourceImageLayerID = try container.decodeIfPresent(UUID.self, forKey: .sourceImageLayerID)
    }
}

// MARK: - Image

nonisolated struct ImageConfig: Codable, Hashable, Sendable {
    /// File name inside the document bundle's images/ directory.
    var imageKey: String
    /// Original pixel size of the stored image.
    var pixelSize: CGSize
    /// Crop rectangle in unit coordinates (0...1) of the original image.
    var crop: CGRect?
    var effects: [Effect]

    init(imageKey: String, pixelSize: CGSize, crop: CGRect? = nil, effects: [Effect] = []) {
        self.imageKey = imageKey
        self.pixelSize = pixelSize
        self.crop = crop
        self.effects = effects
    }

    /// Pixel size after cropping — the layer's natural size.
    var croppedPixelSize: CGSize {
        guard let crop else { return pixelSize }
        return CGSize(width: max(1, pixelSize.width * crop.width),
                      height: max(1, pixelSize.height * crop.height))
    }
}

// MARK: - Text

nonisolated enum FontWeightChoice: String, Codable, CaseIterable, Hashable, Sendable {
    case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black

    var displayName: String {
        switch self {
        case .ultraLight: "Ultra Light"
        case .thin: "Thin"
        case .light: "Light"
        case .regular: "Regular"
        case .medium: "Medium"
        case .semibold: "Semibold"
        case .bold: "Bold"
        case .heavy: "Heavy"
        case .black: "Black"
        }
    }
}

nonisolated enum TextAlignmentChoice: String, Codable, CaseIterable, Hashable, Sendable {
    case left, center, right

    var displayName: String {
        switch self {
        case .left: "Left"
        case .center: "Center"
        case .right: "Right"
        }
    }
}

nonisolated enum TextVerticalAlignment: String, Codable, CaseIterable, Hashable, Sendable {
    case top, center, bottom
    var displayName: String { rawValue.capitalized }
}

nonisolated struct TextConfig: Codable, Hashable, Sendable {
    var text: String
    var fontFamily: String
    var weight: FontWeightChoice
    var italic: Bool
    var size: Double
    /// Extra spacing between characters, in points.
    var tracking: Double
    /// Line height multiplier.
    var lineHeight: Double
    var alignment: TextAlignmentChoice
    var color: RGBAColor
    var allCaps: Bool
    var boxSize: CGSize?
    var styleRuns: [TextStyleRun]?
    var pathLayerID: UUID?
    /// Optional for manifest back-compat; nil means the historic defaults.
    var verticalAlignment: TextVerticalAlignment?
    var ligatures: Bool?
    var smallCaps: Bool?
    var stylisticAlternates: Int?

    init(text: String = "UNTITLED",
         fontFamily: String = "Helvetica Neue",
         weight: FontWeightChoice = .medium,
         italic: Bool = false,
         size: Double = 160,
         tracking: Double = 8,
         lineHeight: Double = 1.1,
         alignment: TextAlignmentChoice = .center,
         color: RGBAColor = RGBAColor(hex: "#EFE8D8"),
         allCaps: Bool = true, boxSize: CGSize? = nil,
         styleRuns: [TextStyleRun]? = nil, pathLayerID: UUID? = nil,
         verticalAlignment: TextVerticalAlignment? = nil,
         ligatures: Bool? = nil, smallCaps: Bool? = nil,
         stylisticAlternates: Int? = nil) {
        self.text = text
        self.fontFamily = fontFamily
        self.weight = weight
        self.italic = italic
        self.size = size
        self.tracking = tracking
        self.lineHeight = lineHeight
        self.alignment = alignment
        self.color = color
        self.allCaps = allCaps
        self.boxSize = boxSize
        self.styleRuns = styleRuns
        self.pathLayerID = pathLayerID
        self.verticalAlignment = verticalAlignment
        self.ligatures = ligatures
        self.smallCaps = smallCaps
        self.stylisticAlternates = stylisticAlternates
    }

    var displayText: String { allCaps ? text.uppercased() : text }
}

nonisolated struct TextStyleRun: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var location: Int
    var length: Int
    var fontFamily: String?
    var weight: FontWeightChoice?
    var size: Double?
    var color: RGBAColor?

    init(id: UUID = UUID(), location: Int, length: Int,
         fontFamily: String? = nil, weight: FontWeightChoice? = nil,
         size: Double? = nil, color: RGBAColor? = nil) {
        self.id = id
        self.location = location
        self.length = length
        self.fontFamily = fontFamily
        self.weight = weight
        self.size = size
        self.color = color
    }
}
