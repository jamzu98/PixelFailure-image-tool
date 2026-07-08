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

    init(id: UUID = UUID(),
         name: String,
         isVisible: Bool = true,
         opacity: Double = 1,
         blendMode: LayerBlendMode = .normal,
         transform: LayerTransform,
         kind: LayerKind) {
        self.id = id
        self.name = name
        self.isVisible = isVisible
        self.opacity = opacity
        self.blendMode = blendMode
        self.transform = transform
        self.kind = kind
    }
}

nonisolated enum LayerKind: Codable, Hashable, Sendable {
    case pattern(PatternConfig)
    case image(ImageConfig)
    case text(TextConfig)

    var isPattern: Bool { if case .pattern = self { true } else { false } }
    var isImage: Bool { if case .image = self { true } else { false } }
    var isText: Bool { if case .text = self { true } else { false } }

    var iconName: String {
        switch self {
        case .pattern: "circle.grid.3x3.fill"
        case .image: "photo"
        case .text: "textformat"
        }
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
