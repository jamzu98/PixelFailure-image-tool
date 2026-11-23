import Foundation

/// A named starting point for a generator: parameter values (including any
/// shared stages such as symmetry) and, optionally, a fixed seed.
nonisolated struct GeneratorPreset: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var generator: GeneratorType
    var params: [String: Double]
    var seed: UInt64?

    /// The pattern with this preset applied: generator defaults, then the
    /// preset's values. The layer's own symmetry/region/color stages carry
    /// over unless the preset sets them; its seed stays unless the preset
    /// pins one.
    func applied(to config: PatternConfig) -> PatternConfig {
        var result = config
        let specs = generator.generator.specs
        var values = ParamValues(defaults: specs)
        for key in GenStages.keys {
            if let existing = config.params.storage[key] { values.storage[key] = existing }
        }
        for (key, value) in params { values.storage[key] = value }
        result.generator = generator
        result.params = values
        if let seed { result.seed = seed }
        result.lockedParams.formIntersection(Set(specs.map(\.key)))
        return result
    }

    /// Captures a pattern's current settings (generator parameters and
    /// active stages, not its seed).
    static func capture(_ config: PatternConfig, name: String) -> GeneratorPreset {
        let keys = Set(config.generator.generator.specs.map(\.key)).union(GenStages.keys)
        let params = config.params.storage.filter { keys.contains($0.key) }
        return GeneratorPreset(name: name, generator: config.generator, params: params, seed: nil)
    }
}

/// Curated presets shipped with the app.
nonisolated enum BuiltInGeneratorPresets {
    static func presets(for type: GeneratorType) -> [GeneratorPreset] {
        table[type, default: []].map { GeneratorPreset(name: $0.0, generator: type, params: $0.1) }
    }

    private static let table: [GeneratorType: [(String, [String: Double])]] = [
        .gridLattice: [
            ("Bubble Field", ["columns": 22, "shape": 0, "falloff": 3, "falloffStrength": 0.8, "jitter": 0.35]),
            ("Confetti", ["columns": 30, "shape": 4, "rotationScatter": 1, "jitter": 0.6, "dropout": 0.3]),
            ("Swiss Grid", ["columns": 12, "shape": 1, "falloff": 2, "falloffStrength": 0.9, "jitter": 0]),
        ],
        .phyllotaxis: [
            ("Sunflower", ["count": 1800, "dotScale": 0.9, "sizeRamp": 0]),
            ("Halo", ["count": 1200, "hollow": 0.45, "sizeRamp": 3, "dotScale": 0.6]),
            ("Off-Angle", ["count": 1500, "angle": 137.3, "dotScale": 0.7]),
        ],
        .flowField: [
            ("Silk", ["lineCount": 1400, "steps": 160, "curl": 0.6, "noiseScale": 1.4, "lineWidth": 0.0015]),
            ("Storm", ["lineCount": 900, "steps": 90, "curl": 2.4, "noiseScale": 4, "noiseType": 3]),
            ("Mandala", ["lineCount": 600, "steps": 120, "stage.symmetry": 5, "stage.segments": 8]),
            ("Curl Smoke", ["lineCount": 1600, "steps": 200, "curlFlow": 1, "noiseType": 1, "noiseWarp": 0.6]),
        ],
        .truchet: [
            ("Maze", ["columns": 18, "style": 1, "multiScale": 0]),
            ("Bubbles", ["columns": 9, "style": 0, "multiScale": 1, "subdivide": 0.6]),
        ],
        .waves: [
            ("Joy Division", ["lineCount": 80, "amplitude": 0.05, "noiseAmount": 0.9, "ampRamp": 0.6]),
            ("Moiré", ["lineCount": 200, "amplitude": 0.02, "frequency": 6, "phaseShift": 0.08]),
        ],
        .rings: [
            ("Tree Rings", ["ringCount": 60, "wobble": 0.35, "rhythm": 2]),
            ("Target", ["ringCount": 14, "wobble": 0, "rhythm": 0, "lineWidth": 0.018]),
            ("Dashed Orbit", ["ringCount": 30, "dashed": 1, "rhythm": 1]),
        ],
        .sampledGrid: [
            ("Halftone", ["columns": 90, "shape": 0, "sizeBy": 0, "colorSource": 3]),
            ("Mosaic", ["columns": 40, "shape": 1, "sizeBy": 2, "colorSource": 0, "dotScale": 1]),
        ],
        .circlePacking: [
            ("Froth", ["count": 2500, "minRadius": 0.003, "maxRadius": 0.05, "style": 0]),
            ("Rings", ["count": 500, "style": 2, "maxRadius": 0.12]),
            ("Hex Tiles", ["count": 1200, "shape": 2, "padding": 0.001]),
        ],
        .contours: [
            ("Topo Map", ["levels": 22, "noiseScale": 1.8, "emphasis": 0.7]),
            ("Fingerprint", ["levels": 40, "noiseScale": 5, "octaves": 1, "lineWidth": 0.0015]),
            ("Islands", ["levels": 8, "noiseType": 3, "lineWidth": 0.005]),
        ],
        .stipple: [
            ("Fine", ["dots": 12000, "maxDot": 0.003, "minDot": 0.0008]),
            ("Bold", ["dots": 2500, "maxDot": 0.009, "gamma": 2]),
        ],
        .subdivision: [
            ("Mondrian", ["depth": 5, "gap": 0.006, "fillChance": 0.45, "lineWidth": 0.006]),
            ("Circuit Board", ["depth": 9, "style": 3, "gap": 0.002]),
            ("Bubbles", ["depth": 8, "style": 2, "fillChance": 1, "lineWidth": 0]),
        ],
        .spaceFilling: [
            ("Hilbert", ["curve": 0, "order": 5, "rounded": 1]),
            ("Moore Loop", ["curve": 1, "order": 6, "lineWidth": 0.002]),
            ("Peano Weave", ["curve": 3, "order": 3, "rounded": 0, "lineWidth": 0.008]),
        ],
        .lSystem: [
            ("Fern", ["system": 0, "iterations": 6]),
            ("Dragon", ["system": 2, "iterations": 13, "lineWidth": 0.0015]),
            ("Snowflake", ["system": 3, "iterations": 4]),
        ],
        .growth: [
            ("Coral", ["steps": 700, "repulsion": 0.01, "attraction": 0.3]),
            ("Echo Rings", ["steps": 600, "echoes": 8]),
            ("Blob", ["steps": 300, "filled": 1, "repulsion": 0.02]),
        ],
        .waveTiles: [
            ("Pipes", ["tileSet": 0, "columns": 20]),
            ("Truchet Flow", ["tileSet": 1, "columns": 14, "nodes": 0, "density": 0.75]),
            ("Circuit", ["tileSet": 2, "columns": 24, "density": 0.45]),
        ],
        .stringArt: [
            ("Cardioid", ["mode": 0, "multiplier": 2]),
            ("Nephroid", ["mode": 0, "multiplier": 3]),
            ("Portrait", ["mode": 1, "lines": 2500, "threadOpacity": 0.25]),
        ],
        .noiseField: [
            ("Marble", ["kind": 0, "warp": 2.6, "scale": 2]),
            ("Cells", ["kind": 1, "scale": 6, "warp": 0.4]),
            ("Contour Bands", ["kind": 2, "bands": 8, "warp": 1]),
        ],
        .voronoi: [
            ("Stained Glass", ["style": 2, "edge": 0.08, "cells": 10]),
            ("Cracked", ["style": 1, "cells": 40, "edge": 0.03]),
        ],
        .plasma: [
            ("Lava", ["scale": 1.6, "waves": 6, "contrast": 1.8]),
            ("Posterized", ["bands": 6, "waves": 4]),
        ],
        .reactionDiffusion: [
            ("Coral", ["preset": 0]),
            ("Fingerprint", ["preset": 3, "iterations": 8000]),
            ("Cells", ["preset": 1]),
        ],
    ]
}

/// User-saved generator presets, persisted in UserDefaults like user palettes.
@Observable
final class UserPresetStore {
    static let shared = UserPresetStore()
    private static let defaultsKey = "userGeneratorPresets"
    private let defaults: UserDefaults

    private(set) var presets: [GeneratorPreset]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([GeneratorPreset].self, from: data) {
            presets = decoded
        } else {
            presets = []
        }
    }

    func presets(for type: GeneratorType) -> [GeneratorPreset] {
        presets.filter { $0.generator == type }
    }

    /// Saves under `name`, replacing a same-named preset for that generator.
    func save(_ preset: GeneratorPreset) {
        var saved = preset
        saved.name = preset.name.trimmingCharacters(in: .whitespaces)
        if saved.name.isEmpty { saved.name = "My Preset" }
        presets.removeAll { $0.generator == saved.generator && $0.name == saved.name }
        presets.append(saved)
        persist()
    }

    func remove(_ preset: GeneratorPreset) {
        presets.removeAll { $0.id == preset.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(presets) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
