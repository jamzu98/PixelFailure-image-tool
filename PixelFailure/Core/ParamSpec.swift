import Foundation

/// Declarative parameter schema. Generators and effects declare their knobs as
/// specs; the inspector renders them generically, randomize samples them, and
/// values persist as a plain `[String: Double]` dictionary.
nonisolated struct ParamSpec: Identifiable, Sendable {
    enum Kind: Sendable {
        case slider(min: Double, max: Double)
        case intSlider(min: Int, max: Int)
        case toggle
        case choice([String])
    }

    let key: String
    let label: String
    let kind: Kind
    let defaultValue: Double
    /// Excluded from the dice/randomize action (e.g. counts that explode render cost).
    var randomizable: Bool = true

    var id: String { key }

    static func slider(_ key: String, _ label: String, min: Double, max: Double, initial: Double, randomizable: Bool = true) -> ParamSpec {
        ParamSpec(key: key, label: label, kind: .slider(min: min, max: max), defaultValue: initial, randomizable: randomizable)
    }

    static func intSlider(_ key: String, _ label: String, min: Int, max: Int, initial: Int, randomizable: Bool = true) -> ParamSpec {
        ParamSpec(key: key, label: label, kind: .intSlider(min: min, max: max), defaultValue: Double(initial), randomizable: randomizable)
    }

    static func toggle(_ key: String, _ label: String, initial: Bool, randomizable: Bool = true) -> ParamSpec {
        ParamSpec(key: key, label: label, kind: .toggle, defaultValue: initial ? 1 : 0, randomizable: randomizable)
    }

    static func choice(_ key: String, _ label: String, options: [String], initial: Int = 0, randomizable: Bool = true) -> ParamSpec {
        ParamSpec(key: key, label: label, kind: .choice(options), defaultValue: Double(initial), randomizable: randomizable)
    }

    func randomValue(using rng: inout SeededRNG) -> Double {
        switch kind {
        case .slider(let min, let max): return rng.range(min, max)
        case .intSlider(let min, let max): return Double(rng.int(min..<(max + 1)))
        case .toggle: return rng.chance(0.5) ? 1 : 0
        case .choice(let options): return Double(rng.int(0..<options.count))
        }
    }
}

/// Persisted parameter values keyed by spec key. Missing keys fall back to the
/// spec default, so adding new parameters never breaks old documents.
nonisolated struct ParamValues: Codable, Hashable, Sendable {
    var storage: [String: Double]

    init() { storage = [:] }

    init(defaults specs: [ParamSpec]) {
        storage = Dictionary(uniqueKeysWithValues: specs.map { ($0.key, $0.defaultValue) })
    }

    func value(_ key: String, _ specs: [ParamSpec]) -> Double {
        storage[key] ?? specs.first(where: { $0.key == key })?.defaultValue ?? 0
    }

    subscript(key: String, default defaultValue: Double) -> Double {
        get { storage[key] ?? defaultValue }
        set { storage[key] = newValue }
    }

    func double(_ key: String, _ fallback: Double = 0) -> Double { storage[key] ?? fallback }
    func int(_ key: String, _ fallback: Int = 0) -> Int { Int((storage[key] ?? Double(fallback)).rounded()) }
    func bool(_ key: String, _ fallback: Bool = false) -> Bool { (storage[key] ?? (fallback ? 1 : 0)) >= 0.5 }

    mutating func set(_ key: String, _ value: Double) { storage[key] = value }

    /// Fresh randomized values for the given specs (respecting `randomizable`).
    static func randomized(specs: [ParamSpec], seed: UInt64, keeping existing: ParamValues) -> ParamValues {
        var rng = SeededRNG(seed: seed)
        var out = ParamValues()
        for spec in specs {
            out.storage[spec.key] = spec.randomizable
                ? spec.randomValue(using: &rng)
                : existing.storage[spec.key] ?? spec.defaultValue
        }
        return out
    }
}
