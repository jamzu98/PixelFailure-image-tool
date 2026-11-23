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
    /// Variable-length values such as curve control points. Kept separate so
    /// manifests containing only the legacy scalar dictionary still decode.
    var arrayStorage: [String: [Double]]

    init() {
        storage = [:]
        arrayStorage = [:]
    }

    init(defaults specs: [ParamSpec]) {
        storage = Dictionary(uniqueKeysWithValues: specs.map { ($0.key, $0.defaultValue) })
        arrayStorage = [:]
    }

    private enum CodingKeys: String, CodingKey { case storage, arrayStorage }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        storage = try container.decodeIfPresent([String: Double].self, forKey: .storage) ?? [:]
        arrayStorage = try container.decodeIfPresent([String: [Double]].self, forKey: .arrayStorage) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(storage, forKey: .storage)
        if !arrayStorage.isEmpty { try container.encode(arrayStorage, forKey: .arrayStorage) }
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
    func array(_ key: String, _ fallback: [Double] = []) -> [Double] { arrayStorage[key] ?? fallback }

    mutating func set(_ key: String, _ value: Double) { storage[key] = value }
    mutating func setArray(_ key: String, _ value: [Double]) { arrayStorage[key] = value }

    /// Small, seeded nudges around `base`: sliders move by up to `strength`
    /// of their range, choices and toggles flip occasionally. Locked keys
    /// and keys outside `specs` stay put.
    static func mutated(specs: [ParamSpec], seed: UInt64, from base: ParamValues,
                        strength: Double, locked: Set<String> = []) -> ParamValues {
        var rng = SeededRNG(seed: seed)
        var out = base
        let s = min(max(strength, 0), 1)
        for spec in specs {
            // Always draw the same amount per spec so locks don't shift others.
            let a = rng.unit(), b = rng.unit()
            guard spec.randomizable, !locked.contains(spec.key) else { continue }
            let current = base.storage[spec.key] ?? spec.defaultValue
            switch spec.kind {
            case .slider(let min, let max):
                out.storage[spec.key] = Swift.min(Swift.max(current + (a * 2 - 1) * s * (max - min), min), max)
            case .intSlider(let min, let max):
                let moved = (current + (a * 2 - 1) * s * Double(max - min)).rounded()
                out.storage[spec.key] = Swift.min(Swift.max(moved, Double(min)), Double(max))
            case .choice(let options):
                if a < s * 0.3 { out.storage[spec.key] = Double(Int(b * Double(options.count)) % options.count) }
            case .toggle:
                if a < s * 0.2 { out.storage[spec.key] = current >= 0.5 ? 0 : 1 }
            }
        }
        return out
    }

    /// Fresh randomized values for the given specs (respecting `randomizable`
    /// and `locked`). Keys outside `specs`, such as the shared symmetry and
    /// region stages, carry over untouched.
    static func randomized(specs: [ParamSpec], seed: UInt64, keeping existing: ParamValues,
                           locked: Set<String> = []) -> ParamValues {
        var rng = SeededRNG(seed: seed)
        var out = existing
        for spec in specs {
            // Always draw, so a lock never shifts the other parameters' values.
            let drawn = spec.randomValue(using: &rng)
            out.storage[spec.key] = spec.randomizable && !locked.contains(spec.key)
                ? drawn
                : existing.storage[spec.key] ?? spec.defaultValue
        }
        return out
    }
}
