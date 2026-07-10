import SwiftUI

/// Plain sRGB color value used throughout the model — Codable, deterministic,
/// and convertible to every color type the renderers need.
nonisolated struct RGBAColor: Codable, Hashable, Sendable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(hex: String, alpha: Double = 1) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        if s.count == 6 {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = alpha
        } else if s.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        } else {
            r = 0; g = 0; b = 0; a = alpha
        }
    }

    static let black = RGBAColor(r: 0, g: 0, b: 0)
    static let white = RGBAColor(r: 1, g: 1, b: 1)
    static let clear = RGBAColor(r: 0, g: 0, b: 0, a: 0)

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }

    /// Component values interpreted in the document's working space.
    func color(in space: WorkingColorSpace) -> Color {
        Color(space.swiftUISpace, red: r, green: g, blue: b, opacity: a)
    }

    func cgColor(in space: WorkingColorSpace) -> CGColor {
        CGColor(colorSpace: space.cgColorSpace,
                components: [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(a)]) ?? cgColor
    }

    /// The same visual color re-expressed in another working space
    /// (perceptual conversion, components clamped to the target gamut).
    func converted(from source: WorkingColorSpace, to target: WorkingColorSpace) -> RGBAColor {
        guard source != target,
              let converted = cgColor(in: source).converted(to: target.cgColorSpace,
                                                            intent: .defaultIntent, options: nil),
              let parts = converted.components, parts.count >= 4 else { return self }
        return RGBAColor(r: min(max(Double(parts[0]), 0), 1),
                         g: min(max(Double(parts[1]), 0), 1),
                         b: min(max(Double(parts[2]), 0), 1),
                         a: Double(parts[3]))
    }

    /// Relative luminance (perceptual-ish, for sorting and duotone ramps).
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    var hexString: String {
        String(format: "#%02X%02X%02X",
               Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    /// e.g. "rgba(12,34,56,0.5)" — used by the SVG exporter.
    var svgString: String {
        let ri = Int((r * 255).rounded()), gi = Int((g * 255).rounded()), bi = Int((b * 255).rounded())
        if a >= 0.999 { return "rgb(\(ri),\(gi),\(bi))" }
        return "rgba(\(ri),\(gi),\(bi),\(String(format: "%.3f", a)))"
    }

    /// SVG's rgb() is sRGB by definition; wide-gamut components convert
    /// (out-of-gamut colors clip — the documented SVG degradation).
    func svgString(in space: WorkingColorSpace) -> String {
        space == .sRGB ? svgString : converted(from: space, to: .sRGB).svgString
    }

    func withAlpha(_ alpha: Double) -> RGBAColor {
        RGBAColor(r: r, g: g, b: b, a: alpha)
    }

    func lerp(to other: RGBAColor, t: Double) -> RGBAColor {
        let t = min(max(t, 0), 1)
        return RGBAColor(r: r + (other.r - r) * t,
                         g: g + (other.g - g) * t,
                         b: b + (other.b - b) * t,
                         a: a + (other.a - a) * t)
    }

    init(colorValue: Color) {
        self.init(colorValue: colorValue, in: .sRGB)
    }

    /// Captures a picked color in the working space, so wide-gamut picks
    /// survive instead of clamping to sRGB.
    init(colorValue: Color, in space: WorkingColorSpace) {
        let ns = NSColor(colorValue)
        let target: NSColorSpace = space == .displayP3 ? .displayP3 : .sRGB
        let converted = ns.usingColorSpace(target) ?? .black
        r = Double(converted.redComponent)
        g = Double(converted.greenComponent)
        b = Double(converted.blueComponent)
        a = Double(converted.alphaComponent)
    }
}
