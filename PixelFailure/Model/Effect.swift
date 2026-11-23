import Foundation

/// Which image effect a stack entry applies. Cases only — parameter schemas
/// and rendering live in Effects/CoreImagePipeline.
nonisolated enum EffectType: String, Codable, CaseIterable, Hashable, Sendable {
    case adjust
    case curves
    case levels
    case targetedHSL
    case whiteBalance
    case vibrance
    case shadowsHighlights
    case pixelate
    case hexPixelate
    case halftone
    case lineScreen
    case posterize
    case threshold
    case duotone
    case grain
    case blur
    case sharpen
    case noiseReduction
    case lensCorrection
    case rawDevelop
    case bloom
    case sliceGlitch
    case chromaticAberration
    case scanlines
    case pixelSort
    case datamosh
    case noiseShift
    case dither

    /// Menu sections for the add-effect menu.
    static let groups: [(title: String, types: [EffectType])] = [
        ("Tone & Color", [.adjust, .curves, .levels, .targetedHSL, .whiteBalance, .vibrance,
                          .shadowsHighlights, .rawDevelop]),
        ("Detail", [.blur, .sharpen, .noiseReduction, .lensCorrection, .grain, .bloom]),
        ("Stylize", [.pixelate, .hexPixelate, .halftone, .lineScreen, .posterize, .threshold, .duotone]),
        ("Glitch", [.sliceGlitch, .chromaticAberration, .scanlines, .pixelSort, .datamosh, .noiseShift,
                    .dither]),
    ]

    var displayName: String {
        switch self {
        case .adjust: "Adjust"
        case .curves: "Curves"
        case .levels: "Levels"
        case .targetedHSL: "Targeted HSL"
        case .whiteBalance: "White Balance"
        case .vibrance: "Vibrance"
        case .shadowsHighlights: "Shadows / Highlights"
        case .pixelate: "Pixelate"
        case .hexPixelate: "Hex Pixelate"
        case .halftone: "Halftone"
        case .lineScreen: "Line Screen"
        case .posterize: "Posterize"
        case .threshold: "Threshold"
        case .duotone: "Palette Map"
        case .grain: "Grain"
        case .blur: "Blur"
        case .sharpen: "Unsharp Mask"
        case .noiseReduction: "Noise Reduction"
        case .lensCorrection: "Lens Correction"
        case .rawDevelop: "RAW Develop"
        case .bloom: "Bloom"
        case .sliceGlitch: "Slice Glitch"
        case .chromaticAberration: "Chromatic Aberration"
        case .scanlines: "Scanlines"
        case .pixelSort: "Pixel Sort"
        case .datamosh: "Datamosh"
        case .noiseShift: "Noise RGB Shift"
        case .dither: "Dither"
        }
    }
}

/// One entry in an image layer's non-destructive effect stack.
nonisolated struct Effect: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var type: EffectType
    var isEnabled: Bool
    var params: ParamValues

    init(id: UUID = UUID(), type: EffectType, isEnabled: Bool = true, params: ParamValues = ParamValues()) {
        self.id = id
        self.type = type
        self.isEnabled = isEnabled
        self.params = params
    }
}
