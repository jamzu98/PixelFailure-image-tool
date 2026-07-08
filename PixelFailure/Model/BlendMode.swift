import SwiftUI
import CoreGraphics

/// Layer blend modes, restricted to the set that GraphicsContext, CGContext,
/// and SVG/CSS `mix-blend-mode` all support so every renderer agrees.
nonisolated enum LayerBlendMode: String, Codable, CaseIterable, Hashable, Sendable {
    case normal, multiply, screen, overlay
    case darken, lighten
    case colorDodge, colorBurn
    case softLight, hardLight
    case difference, exclusion
    case hue, saturation, color, luminosity

    var displayName: String {
        switch self {
        case .normal: "Normal"
        case .multiply: "Multiply"
        case .screen: "Screen"
        case .overlay: "Overlay"
        case .darken: "Darken"
        case .lighten: "Lighten"
        case .colorDodge: "Color Dodge"
        case .colorBurn: "Color Burn"
        case .softLight: "Soft Light"
        case .hardLight: "Hard Light"
        case .difference: "Difference"
        case .exclusion: "Exclusion"
        case .hue: "Hue"
        case .saturation: "Saturation"
        case .color: "Color"
        case .luminosity: "Luminosity"
        }
    }

    var graphicsContextMode: GraphicsContext.BlendMode {
        switch self {
        case .normal: .normal
        case .multiply: .multiply
        case .screen: .screen
        case .overlay: .overlay
        case .darken: .darken
        case .lighten: .lighten
        case .colorDodge: .colorDodge
        case .colorBurn: .colorBurn
        case .softLight: .softLight
        case .hardLight: .hardLight
        case .difference: .difference
        case .exclusion: .exclusion
        case .hue: .hue
        case .saturation: .saturation
        case .color: .color
        case .luminosity: .luminosity
        }
    }

    var cgBlendMode: CGBlendMode {
        switch self {
        case .normal: .normal
        case .multiply: .multiply
        case .screen: .screen
        case .overlay: .overlay
        case .darken: .darken
        case .lighten: .lighten
        case .colorDodge: .colorDodge
        case .colorBurn: .colorBurn
        case .softLight: .softLight
        case .hardLight: .hardLight
        case .difference: .difference
        case .exclusion: .exclusion
        case .hue: .hue
        case .saturation: .saturation
        case .color: .color
        case .luminosity: .luminosity
        }
    }

    /// CSS mix-blend-mode value for SVG export.
    var svgName: String {
        switch self {
        case .normal: "normal"
        case .multiply: "multiply"
        case .screen: "screen"
        case .overlay: "overlay"
        case .darken: "darken"
        case .lighten: "lighten"
        case .colorDodge: "color-dodge"
        case .colorBurn: "color-burn"
        case .softLight: "soft-light"
        case .hardLight: "hard-light"
        case .difference: "difference"
        case .exclusion: "exclusion"
        case .hue: "hue"
        case .saturation: "saturation"
        case .color: "color"
        case .luminosity: "luminosity"
        }
    }
}
