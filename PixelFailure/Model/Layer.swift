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

    init(id: UUID = UUID(),
         name: String,
         isVisible: Bool = true,
         opacity: Double = 1,
         blendMode: LayerBlendMode = .normal,
         transform: LayerTransform,
         kind: LayerKind,
         mask: LayerMask? = nil) {
        self.id = id
        self.name = name
        self.isVisible = isVisible
        self.opacity = opacity
        self.blendMode = blendMode
        self.transform = transform
        self.kind = kind
        self.mask = mask
    }
}

nonisolated enum LayerKind: Codable, Hashable, Sendable {
    case pattern(PatternConfig)
    case image(ImageConfig)
    case text(TextConfig)
    case fill(FillConfig)
    case shape(ShapeConfig)

    var isPattern: Bool { if case .pattern = self { true } else { false } }
    var isImage: Bool { if case .image = self { true } else { false } }
    var isText: Bool { if case .text = self { true } else { false } }
    var isFill: Bool { if case .fill = self { true } else { false } }
    var isShape: Bool { if case .shape = self { true } else { false } }

    var iconName: String {
        switch self {
        case .pattern: "circle.grid.3x3.fill"
        case .image: "photo"
        case .text: "textformat"
        case .fill: "rectangle.fill"
        case .shape: "square.on.circle"
        }
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

    init(imageKey: String, pixelSize: CGSize, isEnabled: Bool = true, inverted: Bool = false) {
        self.imageKey = imageKey
        self.pixelSize = pixelSize
        self.isEnabled = isEnabled
        self.inverted = inverted
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

    init(generator: GeneratorType, seed: UInt64 = SeededRNG.randomSeed(), params: ParamValues = ParamValues(), sourceImageLayerID: UUID? = nil) {
        self.generator = generator
        self.seed = seed
        self.params = params
        self.sourceImageLayerID = sourceImageLayerID
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

    init(text: String = "UNTITLED",
         fontFamily: String = "Helvetica Neue",
         weight: FontWeightChoice = .medium,
         italic: Bool = false,
         size: Double = 160,
         tracking: Double = 8,
         lineHeight: Double = 1.1,
         alignment: TextAlignmentChoice = .center,
         color: RGBAColor = RGBAColor(hex: "#EFE8D8"),
         allCaps: Bool = true) {
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
    }

    var displayText: String { allCaps ? text.uppercased() : text }
}
