import Foundation

nonisolated struct Palette: Codable, Hashable, Sendable {
    var name: String
    var colors: [RGBAColor]

    init(name: String, colors: [RGBAColor]) {
        self.name = name
        self.colors = colors
    }

    init(name: String, hex: [String]) {
        self.name = name
        self.colors = hex.map { RGBAColor(hex: $0) }
    }

    /// Color at index, wrapping — generators can index freely.
    func color(_ index: Int) -> RGBAColor {
        guard !colors.isEmpty else { return .black }
        return colors[((index % colors.count) + colors.count) % colors.count]
    }

    /// Deterministic random pick.
    func random(using rng: inout SeededRNG) -> RGBAColor {
        guard !colors.isEmpty else { return .black }
        return rng.pick(colors)
    }

    /// Interpolated color along the palette treated as a ramp, t in [0, 1].
    func ramp(_ t: Double) -> RGBAColor {
        guard colors.count > 1 else { return colors.first ?? .black }
        let clamped = min(max(t, 0), 1)
        let scaled = clamped * Double(colors.count - 1)
        let i = min(Int(scaled), colors.count - 2)
        return colors[i].lerp(to: colors[i + 1], t: scaled - Double(i))
    }

    /// Palette sorted dark → light (nice for duotone and ramps).
    var sortedByLuminance: Palette {
        Palette(name: name, colors: colors.sorted { $0.luminance < $1.luminance })
    }

    /// Palettes are always exactly this many colors.
    static let swatchCount = 5

    /// Truncates or pads (by sampling the existing ramp) to exactly
    /// `Palette.swatchCount` colors.
    var normalized: Palette {
        if colors.count == Self.swatchCount { return self }
        guard !colors.isEmpty else {
            return Palette(name: name, colors: Array(repeating: .black, count: Self.swatchCount))
        }
        let resampled = (0..<Self.swatchCount).map { i in
            ramp(Double(i) / Double(Self.swatchCount - 1))
        }
        return Palette(name: name, colors: resampled)
    }
}

/// Curated muted/earthy palettes — the app's aesthetic default.
nonisolated enum BuiltInPalettes {
    static let all: [Palette] = [
        Palette(name: "Terracotta", hex: ["#9C4A2F", "#C4744F", "#E0A57D", "#EAD7C2", "#3F3128"]),
        Palette(name: "Sage & Sand", hex: ["#7A8450", "#A3A76B", "#D6CDA4", "#EFE8D8", "#4A4A3A"]),
        Palette(name: "Ochre Dust", hex: ["#B98A2F", "#D9B45B", "#E8D8A6", "#8A6D3B", "#40342A"]),
        Palette(name: "Rust & Bone", hex: ["#8C3B2E", "#B45A3C", "#D9A07E", "#EFE4D4", "#2E2620"]),
        Palette(name: "Moss & Clay", hex: ["#5B6B44", "#8A9A5B", "#C2B280", "#B66E4F", "#33302B"]),
        Palette(name: "Dusty Blues", hex: ["#5B7285", "#8AA2B2", "#C9D2D4", "#D9C7B2", "#3A3F45"]),
        Palette(name: "Charcoal & Cream", hex: ["#2B2B28", "#4F4A44", "#8A8178", "#CFC5B4", "#F0EAD8"]),
        Palette(name: "Desert Evening", hex: ["#6E4A5E", "#A26769", "#D5A688", "#ECD9C0", "#3B2F3A"]),
        Palette(name: "Olive Grove", hex: ["#44543B", "#6F7F52", "#A9AC7E", "#D9D2B0", "#8C5F3F"]),
        Palette(name: "Faded Denim", hex: ["#3F5266", "#6C8299", "#A5B5C0", "#D8D3C5", "#8A6F5C"]),
        Palette(name: "Pale Winter", hex: ["#5C6668", "#8E9AA0", "#B9C4C9", "#D8DDD9", "#EDEAE2"]),
        Palette(name: "Ember", hex: ["#3B2A25", "#6E3B2C", "#A6503A", "#D98E5F", "#EAC9A0"]),
    ]

    static let `default` = all[0]
}
