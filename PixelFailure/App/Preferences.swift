import AppKit
import SwiftUI

/// App-wide preferences (Settings window, ⌘,), persisted in UserDefaults.
/// Observable, so views that read a value re-render when it changes.
@Observable
final class Preferences {
    static let shared = Preferences()

    @ObservationIgnored private let defaults: UserDefaults

    enum BrushCursor: String, CaseIterable, Identifiable {
        case tip, tipCrosshair, precise
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .tip: "Brush Tip"
            case .tipCrosshair: "Brush Tip + Crosshair"
            case .precise: "Precise"
            }
        }
    }

    enum CanvasSurround: String, CaseIterable, Identifiable {
        case standard, black, darkGray, mediumGray, lightGray, custom
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .standard: "Default"
            case .black: "Black"
            case .darkGray: "Dark Gray"
            case .mediumGray: "Medium Gray"
            case .lightGray: "Light Gray"
            case .custom: "Custom"
            }
        }
    }

    enum NewPatternParameters: String, CaseIterable, Identifiable {
        case defaults, randomized
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .defaults: "Generator Defaults"
            case .randomized: "Randomized"
            }
        }
    }

    // MARK: General

    var historyStates: Int { didSet { set(historyStates, Key.historyStates) } }
    var autoRecoveryEnabled: Bool { didSet { set(autoRecoveryEnabled, Key.autoRecoveryEnabled) } }
    /// Seconds of inactivity before an autosave for crash recovery.
    var autoRecoveryDelay: Double { didSet { set(autoRecoveryDelay, Key.autoRecoveryDelay) } }

    // MARK: Interface

    var canvasSurround: CanvasSurround { didSet { set(canvasSurround.rawValue, Key.canvasSurround) } }
    var customSurroundHex: String { didSet { set(customSurroundHex, Key.customSurroundHex) } }
    var showsStatusBar: Bool { didSet { set(showsStatusBar, Key.showsStatusBar) } }
    var showsShortcutsInTooltips: Bool { didSet { set(showsShortcutsInTooltips, Key.showsShortcutsInTooltips) } }

    // MARK: Tools

    var useShiftForToolSwitch: Bool { didSet { set(useShiftForToolSwitch, Key.useShiftForToolSwitch) } }
    var springLoadedTools: Bool { didSet { set(springLoadedTools, Key.springLoadedTools) } }
    var zoomWithScrollWheel: Bool { didSet { set(zoomWithScrollWheel, Key.zoomWithScrollWheel) } }
    var zoomToClickedPoint: Bool { didSet { set(zoomToClickedPoint, Key.zoomToClickedPoint) } }
    var nudgeDistance: Double { didSet { set(nudgeDistance, Key.nudgeDistance) } }
    var shiftNudgeDistance: Double { didSet { set(shiftNudgeDistance, Key.shiftNudgeDistance) } }
    /// Screen points within which moving layers snap to guides/edges.
    var snapDistance: Double { didSet { set(snapDistance, Key.snapDistance) } }
    var brushCursor: BrushCursor { didSet { set(brushCursor.rawValue, Key.brushCursor) } }
    var defaultForegroundHex: String { didSet { set(defaultForegroundHex, Key.defaultForegroundHex) } }
    var defaultBackgroundHex: String { didSet { set(defaultBackgroundHex, Key.defaultBackgroundHex) } }

    // MARK: Guides, grid & selection

    var guideColorHex: String { didSet { set(guideColorHex, Key.guideColorHex) } }
    var smartGuideColorHex: String { didSet { set(smartGuideColorHex, Key.smartGuideColorHex) } }
    var gridColorHex: String { didSet { set(gridColorHex, Key.gridColorHex) } }
    var gridOpacity: Double { didSet { set(gridOpacity, Key.gridOpacity) } }
    var showsPixelGrid: Bool { didSet { set(showsPixelGrid, Key.showsPixelGrid) } }
    var animatesSelectionEdges: Bool { didSet { set(animatesSelectionEdges, Key.animatesSelectionEdges) } }

    // MARK: Smart selection

    var smartSelectHoverPreview: Bool { didSet { set(smartSelectHoverPreview, Key.smartSelectHoverPreview) } }
    var smartSelectPrefetch: Bool { didSet { set(smartSelectPrefetch, Key.smartSelectPrefetch) } }
    var defaultFeather: Double { didSet { set(defaultFeather, Key.defaultFeather) } }
    var defaultWandTolerance: Double { didSet { set(defaultWandTolerance, Key.defaultWandTolerance) } }

    // MARK: Generators

    var newPatternParameters: NewPatternParameters {
        didSet { set(newPatternParameters.rawValue, Key.newPatternParameters) }
    }
    /// Reroll keeps the generator's current parameters; Randomize changes both.
    var randomizeSwitchesPalette: Bool { didSet { set(randomizeSwitchesPalette, Key.randomizeSwitchesPalette) } }

    // MARK: Export

    var defaultExportFormat: String { didSet { set(defaultExportFormat, Key.defaultExportFormat) } }
    var rememberExportFormat: Bool { didSet { set(rememberExportFormat, Key.rememberExportFormat) } }
    var defaultExportQuality: Double { didSet { set(defaultExportQuality, Key.defaultExportQuality) } }

    // MARK: Lifecycle

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        historyStates = defaults.object(forKey: Key.historyStates) as? Int ?? Default.historyStates
        autoRecoveryEnabled = defaults.object(forKey: Key.autoRecoveryEnabled) as? Bool ?? true
        autoRecoveryDelay = defaults.object(forKey: Key.autoRecoveryDelay) as? Double ?? Default.autoRecoveryDelay

        canvasSurround = defaults.string(forKey: Key.canvasSurround).flatMap(CanvasSurround.init) ?? .standard
        customSurroundHex = defaults.string(forKey: Key.customSurroundHex) ?? "#1E1E1E"
        showsStatusBar = defaults.object(forKey: Key.showsStatusBar) as? Bool ?? true
        showsShortcutsInTooltips = defaults.object(forKey: Key.showsShortcutsInTooltips) as? Bool ?? true

        useShiftForToolSwitch = defaults.object(forKey: Key.useShiftForToolSwitch) as? Bool ?? true
        springLoadedTools = defaults.object(forKey: Key.springLoadedTools) as? Bool ?? true
        zoomWithScrollWheel = defaults.object(forKey: Key.zoomWithScrollWheel) as? Bool ?? false
        zoomToClickedPoint = defaults.object(forKey: Key.zoomToClickedPoint) as? Bool ?? true
        nudgeDistance = defaults.object(forKey: Key.nudgeDistance) as? Double ?? Default.nudge
        shiftNudgeDistance = defaults.object(forKey: Key.shiftNudgeDistance) as? Double ?? Default.shiftNudge
        snapDistance = defaults.object(forKey: Key.snapDistance) as? Double ?? Default.snapDistance
        brushCursor = defaults.string(forKey: Key.brushCursor).flatMap(BrushCursor.init) ?? .tip
        defaultForegroundHex = defaults.string(forKey: Key.defaultForegroundHex) ?? Default.foreground
        defaultBackgroundHex = defaults.string(forKey: Key.defaultBackgroundHex) ?? Default.background

        guideColorHex = defaults.string(forKey: Key.guideColorHex) ?? Default.guideColor
        smartGuideColorHex = defaults.string(forKey: Key.smartGuideColorHex) ?? Default.smartGuideColor
        gridColorHex = defaults.string(forKey: Key.gridColorHex) ?? Default.gridColor
        gridOpacity = defaults.object(forKey: Key.gridOpacity) as? Double ?? Default.gridOpacity
        showsPixelGrid = defaults.object(forKey: Key.showsPixelGrid) as? Bool ?? true
        animatesSelectionEdges = defaults.object(forKey: Key.animatesSelectionEdges) as? Bool ?? true

        smartSelectHoverPreview = defaults.object(forKey: Key.smartSelectHoverPreview) as? Bool ?? true
        smartSelectPrefetch = defaults.object(forKey: Key.smartSelectPrefetch) as? Bool ?? true
        defaultFeather = defaults.object(forKey: Key.defaultFeather) as? Double ?? 0
        defaultWandTolerance = defaults.object(forKey: Key.defaultWandTolerance) as? Double ?? Default.wandTolerance

        newPatternParameters = defaults.string(forKey: Key.newPatternParameters)
            .flatMap(NewPatternParameters.init) ?? .defaults
        randomizeSwitchesPalette = defaults.object(forKey: Key.randomizeSwitchesPalette) as? Bool ?? false

        defaultExportFormat = defaults.string(forKey: Key.defaultExportFormat) ?? "PNG"
        rememberExportFormat = defaults.object(forKey: Key.rememberExportFormat) as? Bool ?? true
        defaultExportQuality = defaults.object(forKey: Key.defaultExportQuality) as? Double ?? 0.9
    }

    private func set(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    // MARK: Derived values

    var canvasSurroundColor: Color {
        switch canvasSurround {
        case .standard: Theme.canvas
        case .black: .black
        case .darkGray: Color(white: 0.16)
        case .mediumGray: Color(white: 0.32)
        case .lightGray: Color(white: 0.62)
        case .custom: RGBAColor(hex: customSurroundHex).color
        }
    }

    var guideColor: Color { RGBAColor(hex: guideColorHex).color }
    var smartGuideColor: Color { RGBAColor(hex: smartGuideColorHex).color }
    var gridColor: Color { RGBAColor(hex: gridColorHex).color.opacity(gridOpacity) }
    var defaultForeground: RGBAColor { RGBAColor(hex: defaultForegroundHex) }
    var defaultBackground: RGBAColor { RGBAColor(hex: defaultBackgroundHex) }

    /// A color binding over one of the hex-string properties.
    func colorBinding(_ keyPath: ReferenceWritableKeyPath<Preferences, String>) -> Binding<Color> {
        Binding(get: { RGBAColor(hex: self[keyPath: keyPath]).color },
                set: { self[keyPath: keyPath] = RGBAColor(colorValue: $0).hexString })
    }

    // MARK: Reset

    func resetGeneral() {
        historyStates = Default.historyStates
        autoRecoveryEnabled = true
        autoRecoveryDelay = Default.autoRecoveryDelay
        defaults.removeObject(forKey: LaunchAction.defaultsKey)
    }

    func resetInterface() {
        canvasSurround = .standard
        customSurroundHex = "#1E1E1E"
        showsStatusBar = true
        showsShortcutsInTooltips = true
    }

    func resetTools() {
        useShiftForToolSwitch = true
        springLoadedTools = true
        zoomWithScrollWheel = false
        zoomToClickedPoint = true
        nudgeDistance = Default.nudge
        shiftNudgeDistance = Default.shiftNudge
        snapDistance = Default.snapDistance
        brushCursor = .tip
        defaultForegroundHex = Default.foreground
        defaultBackgroundHex = Default.background
    }

    func resetGuides() {
        guideColorHex = Default.guideColor
        smartGuideColorHex = Default.smartGuideColor
        gridColorHex = Default.gridColor
        gridOpacity = Default.gridOpacity
        showsPixelGrid = true
        animatesSelectionEdges = true
    }

    func resetSmartSelection() {
        smartSelectHoverPreview = true
        smartSelectPrefetch = true
        defaultFeather = 0
        defaultWandTolerance = Default.wandTolerance
    }

    func resetGenerators() {
        newPatternParameters = .defaults
        randomizeSwitchesPalette = false
    }

    func resetExport() {
        defaultExportFormat = "PNG"
        rememberExportFormat = true
        defaultExportQuality = 0.9
    }

    /// Forgets which inspector sections were collapsed.
    func resetPanelLayout() {
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("inspector.section.") || key == "inspector.tab" {
            defaults.removeObject(forKey: key)
        }
    }

    private enum Default {
        static let historyStates = 200
        static let autoRecoveryDelay = 2.0
        static let nudge = 1.0
        static let shiftNudge = 10.0
        static let snapDistance = 8.0
        static let foreground = "#000000"
        static let background = "#FFFFFF"
        static let guideColor = "#3D8BFF"
        static let smartGuideColor = "#FF3EBF"
        static let gridColor = "#FFFFFF"
        static let gridOpacity = 0.13
        static let wandTolerance = 0.25
    }

    private enum Key {
        static let historyStates = "prefs.historyStates"
        static let autoRecoveryEnabled = "prefs.autoRecovery.enabled"
        static let autoRecoveryDelay = "prefs.autoRecovery.delay"
        static let canvasSurround = "prefs.canvasSurround"
        static let customSurroundHex = "prefs.canvasSurround.custom"
        static let showsStatusBar = "prefs.showsStatusBar"
        static let showsShortcutsInTooltips = "prefs.tooltipShortcuts"
        static let useShiftForToolSwitch = "prefs.tools.shiftSwitch"
        static let springLoadedTools = "prefs.tools.springLoaded"
        static let zoomWithScrollWheel = "prefs.tools.scrollZoom"
        static let zoomToClickedPoint = "prefs.tools.zoomToClick"
        static let nudgeDistance = "prefs.tools.nudge"
        static let shiftNudgeDistance = "prefs.tools.shiftNudge"
        static let snapDistance = "prefs.tools.snapDistance"
        static let brushCursor = "prefs.tools.brushCursor"
        static let defaultForegroundHex = "prefs.colors.foreground"
        static let defaultBackgroundHex = "prefs.colors.background"
        static let guideColorHex = "prefs.guides.color"
        static let smartGuideColorHex = "prefs.guides.smartColor"
        static let gridColorHex = "prefs.grid.color"
        static let gridOpacity = "prefs.grid.opacity"
        static let showsPixelGrid = "prefs.grid.pixelGrid"
        static let animatesSelectionEdges = "prefs.selection.animated"
        static let smartSelectHoverPreview = "prefs.smartSelect.hover"
        static let smartSelectPrefetch = "prefs.smartSelect.prefetch"
        static let defaultFeather = "prefs.selection.feather"
        static let defaultWandTolerance = "prefs.selection.wandTolerance"
        static let newPatternParameters = "prefs.generators.newParams"
        static let randomizeSwitchesPalette = "prefs.generators.randomizePalette"
        static let defaultExportFormat = "prefs.export.format"
        static let rememberExportFormat = "prefs.export.remember"
        static let defaultExportQuality = "prefs.export.quality"
    }
}
