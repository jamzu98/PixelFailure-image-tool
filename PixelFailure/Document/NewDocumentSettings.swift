import CoreGraphics
import Foundation

/// Display units for canvas dimensions. The document always stores pixels;
/// physical units convert through the resolution.
nonisolated enum MeasurementUnit: String, Codable, CaseIterable, Sendable {
    case pixels, inches, centimeters, millimeters

    var displayName: String {
        switch self {
        case .pixels: "Pixels"
        case .inches: "Inches"
        case .centimeters: "Centimeters"
        case .millimeters: "Millimeters"
        }
    }

    var abbreviation: String {
        switch self {
        case .pixels: "px"
        case .inches: "in"
        case .centimeters: "cm"
        case .millimeters: "mm"
        }
    }

    private var inchesPerUnit: Double {
        switch self {
        case .pixels: 1
        case .inches: 1
        case .centimeters: 1 / 2.54
        case .millimeters: 1 / 25.4
        }
    }

    func toPixels(_ value: Double, dpi: Double) -> Double {
        self == .pixels ? value : value * inchesPerUnit * dpi
    }

    func fromPixels(_ pixels: Double, dpi: Double) -> Double {
        self == .pixels ? pixels : pixels / dpi / inchesPerUnit
    }

    var fractionDigits: Int { self == .pixels ? 0 : 2 }
}

nonisolated enum BackgroundChoice: String, Codable, CaseIterable, Sendable {
    case white, black, custom

    var displayName: String {
        switch self {
        case .white: "White"
        case .black: "Black"
        case .custom: "Custom"
        }
    }
}

/// Guide sets laid down on a new canvas.
nonisolated enum GuideLayout: String, Codable, CaseIterable, Sendable {
    case none, center, thirds, safeMargin

    var displayName: String {
        switch self {
        case .none: "None"
        case .center: "Center"
        case .thirds: "Rule of Thirds"
        case .safeMargin: "Safe Margin (5%)"
        }
    }

    func guides(for size: CGSize) -> [CanvasGuide] {
        let w = size.width, h = size.height
        let pairs: [(GuideOrientation, Double)]
        switch self {
        case .none:
            pairs = []
        case .center:
            pairs = [(.vertical, w / 2), (.horizontal, h / 2)]
        case .thirds:
            pairs = [(.vertical, w / 3), (.vertical, w * 2 / 3),
                     (.horizontal, h / 3), (.horizontal, h * 2 / 3)]
        case .safeMargin:
            let inset = min(w, h) * 0.05
            pairs = [(.vertical, inset), (.vertical, w - inset),
                     (.horizontal, inset), (.horizontal, h - inset)]
        }
        return pairs.map { CanvasGuide(orientation: $0.0, position: $0.1.rounded()) }
    }
}

/// Everything the New Document dialog decides. Remembered between launches
/// (last used, recents, saved presets), so it is Codable and every field
/// decodes leniently.
nonisolated struct NewDocumentSettings: Codable, Hashable, Sendable {
    static let maxDimension: Double = 30_000
    static let defaultBackground = RGBAColor(hex: "#211E1B")

    var name = "Untitled"
    /// Pixels.
    var width: Double = 3000
    /// Pixels.
    var height: Double = 3000
    var unit: MeasurementUnit = .pixels
    var dpi: Double = 300
    var workingSpace: WorkingColorSpace = .sRGB
    var bitDepth: RasterBitDepth = .eight
    var background: BackgroundChoice = .custom
    var customBackground = NewDocumentSettings.defaultBackground
    /// nil starts blank; otherwise one pattern layer of this generator.
    var starterGenerator: GeneratorType?
    var palette: Palette = BuiltInPalettes.default
    var guides: GuideLayout = .none
    var showsGrid = false
    var showsRulers = true

    init() {}

    init(name: String, width: Double, height: Double, dpi: Double = 72,
         unit: MeasurementUnit = .pixels) {
        self.name = name
        self.width = width
        self.height = height
        self.dpi = dpi
        self.unit = unit
    }

    private enum CodingKeys: String, CodingKey {
        case name, width, height, unit, dpi, workingSpace, bitDepth, background,
             customBackground, starterGenerator, palette, guides, showsGrid, showsRulers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = NewDocumentSettings()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? base.name
        width = (try? c.decodeIfPresent(Double.self, forKey: .width)) ?? base.width
        height = (try? c.decodeIfPresent(Double.self, forKey: .height)) ?? base.height
        unit = (try? c.decodeIfPresent(MeasurementUnit.self, forKey: .unit)) ?? base.unit
        dpi = (try? c.decodeIfPresent(Double.self, forKey: .dpi)) ?? base.dpi
        workingSpace = (try? c.decodeIfPresent(WorkingColorSpace.self, forKey: .workingSpace)) ?? base.workingSpace
        bitDepth = (try? c.decodeIfPresent(RasterBitDepth.self, forKey: .bitDepth)) ?? base.bitDepth
        background = (try? c.decodeIfPresent(BackgroundChoice.self, forKey: .background)) ?? base.background
        customBackground = (try? c.decodeIfPresent(RGBAColor.self, forKey: .customBackground)) ?? base.customBackground
        starterGenerator = try? c.decodeIfPresent(GeneratorType.self, forKey: .starterGenerator)
        palette = (try? c.decodeIfPresent(Palette.self, forKey: .palette)) ?? base.palette
        guides = (try? c.decodeIfPresent(GuideLayout.self, forKey: .guides)) ?? base.guides
        showsGrid = (try? c.decodeIfPresent(Bool.self, forKey: .showsGrid)) ?? base.showsGrid
        showsRulers = (try? c.decodeIfPresent(Bool.self, forKey: .showsRulers)) ?? base.showsRulers
    }

    var pixelSize: CGSize {
        CGSize(width: Self.clampDimension(width), height: Self.clampDimension(height))
    }

    static func clampDimension(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value.rounded(), 1), maxDimension)
    }

    var backgroundColor: RGBAColor {
        switch background {
        case .white: .white
        case .black: .black
        case .custom: customBackground
        }
    }

    var isPortrait: Bool { height > width }

    /// Size-only identity, so a preset tile can tell whether it matches.
    func hasSameFormat(as other: NewDocumentSettings) -> Bool {
        pixelSize == other.pixelSize && abs(dpi - other.dpi) < 0.01
    }

    /// Takes a preset's format (size, resolution, unit) while keeping this
    /// document's color, content, and layout choices.
    func applyingFormat(of preset: NewDocumentSettings) -> NewDocumentSettings {
        var result = self
        result.name = preset.name
        result.width = preset.width
        result.height = preset.height
        result.dpi = preset.dpi
        result.unit = preset.unit
        return result
    }

    var dimensionSummary: String {
        let size = pixelSize
        if unit == .pixels {
            return "\(Int(size.width)) × \(Int(size.height)) px"
        }
        let w = unit.fromPixels(size.width, dpi: dpi)
        let h = unit.fromPixels(size.height, dpi: dpi)
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2))
        return "\(w.formatted(format)) × \(h.formatted(format)) \(unit.abbreviation)"
    }

    func makeModel() -> ProjectModel {
        let size = pixelSize
        var model = ProjectModel(
            canvasSize: size,
            colorSettings: ColorSettings(workingSpace: workingSpace, bitDepth: bitDepth),
            background: backgroundColor,
            palette: palette,
            workspace: WorkspaceSettings(guides: guides.guides(for: size),
                                         grid: GridSettings(isVisible: showsGrid,
                                                            spacing: Self.gridSpacing(for: size)),
                                         showsRulers: showsRulers),
            printSettings: PrintSettings(dpi: dpi))
        if let starterGenerator {
            model.layers = [Layer(name: starterGenerator.displayName,
                                  transform: LayerTransform(position: model.canvasCenter),
                                  kind: .pattern(PatternConfig(generator: starterGenerator)))]
        }
        return model
    }

    /// About twelve cells across the short side, on a round number.
    private static func gridSpacing(for size: CGSize) -> Double {
        let raw = min(size.width, size.height) / 12
        let steps: [Double] = [10, 20, 25, 50, 100, 200, 250, 500, 1000]
        return steps.min { abs($0 - raw) < abs($1 - raw) } ?? 100
    }
}

// MARK: - Presets

nonisolated enum PresetCategory: String, CaseIterable, Sendable {
    case recent, saved, music, social, print, screen

    var displayName: String {
        switch self {
        case .recent: "Recent"
        case .saved: "Saved"
        case .music: "Music"
        case .social: "Social"
        case .print: "Print"
        case .screen: "Screen"
        }
    }
}

nonisolated struct DocumentPreset: Identifiable, Hashable, Sendable {
    var id: String
    var settings: NewDocumentSettings

    var name: String { settings.name }

    static func builtIn(_ category: PresetCategory) -> [DocumentPreset] {
        func px(_ name: String, _ w: Double, _ h: Double, dpi: Double = 72) -> DocumentPreset {
            DocumentPreset(id: "\(category.rawValue).\(name)",
                           settings: NewDocumentSettings(name: name, width: w, height: h, dpi: dpi))
        }
        func inches(_ name: String, _ w: Double, _ h: Double, dpi: Double = 300) -> DocumentPreset {
            DocumentPreset(id: "\(category.rawValue).\(name)",
                           settings: NewDocumentSettings(name: name, width: (w * dpi).rounded(),
                                                         height: (h * dpi).rounded(), dpi: dpi,
                                                         unit: .inches))
        }
        func mm(_ name: String, _ w: Double, _ h: Double, dpi: Double = 300) -> DocumentPreset {
            DocumentPreset(id: "\(category.rawValue).\(name)",
                           settings: NewDocumentSettings(name: name, width: (w / 25.4 * dpi).rounded(),
                                                         height: (h / 25.4 * dpi).rounded(), dpi: dpi,
                                                         unit: .millimeters))
        }

        switch category {
        case .recent, .saved:
            return []
        case .music:
            return [
                px("Album Cover", 3000, 3000, dpi: 300),
                px("Album Cover HD", 4000, 4000, dpi: 300),
                inches("12\" Vinyl Sleeve", 12.5, 12.5),
                inches("7\" Single Sleeve", 7.25, 7.25),
                inches("CD Booklet", 4.75, 4.75),
                px("Canvas Loop 9:16", 1080, 1920),
                px("Artist Banner", 2660, 1140),
                inches("Tour Poster 18×24", 18, 24),
            ]
        case .social:
            return [
                px("Square Post", 1080, 1080),
                px("Portrait Post", 1080, 1350),
                px("Story / Reel", 1080, 1920),
                px("Video Thumbnail", 1280, 720),
                px("Channel Banner", 2560, 1440),
                px("Header 3:1", 1500, 500),
                px("Link Preview", 1200, 630),
            ]
        case .print:
            return [
                mm("A4", 210, 297),
                mm("A3", 297, 420),
                mm("A2", 420, 594),
                inches("US Letter", 8.5, 11),
                inches("Tabloid", 11, 17),
                inches("Postcard", 6, 4),
                inches("Square 12×12", 12, 12),
            ]
        case .screen:
            return [
                px("HD 1080p", 1920, 1080),
                px("QHD 1440p", 2560, 1440),
                px("4K UHD", 3840, 2160),
                px("5K Retina", 5120, 2880),
                px("Phone Wallpaper", 1290, 2796),
                px("Tablet Wallpaper", 2048, 2732),
            ]
        }
    }
}
