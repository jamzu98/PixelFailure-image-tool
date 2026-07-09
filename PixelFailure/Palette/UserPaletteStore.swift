import Foundation

/// App-level store for user-saved palettes, persisted in UserDefaults.
/// Built-in palettes never pass through here — they are immutable.
@Observable
final class UserPaletteStore {
    static let shared = UserPaletteStore()

    private static let defaultsKey = "userPalettes"

    private(set) var palettes: [Palette]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([Palette].self, from: data) {
            // Normalize palettes saved before the fixed swatch count existed.
            palettes = decoded.map(\.normalized)
        } else {
            palettes = []
        }
    }

    private let defaults: UserDefaults

    /// Saves under `name`, replacing an existing user palette of the same
    /// name. Names colliding with a built-in get a suffix so built-ins stay
    /// distinct and unmodifiable.
    func save(_ palette: Palette, named name: String) {
        var cleanName = name.trimmingCharacters(in: .whitespaces)
        if cleanName.isEmpty { cleanName = "My Palette" }
        if BuiltInPalettes.all.contains(where: { $0.name == cleanName }) {
            cleanName += " (Custom)"
        }
        var saved = palette.normalized
        saved.name = cleanName
        palettes.removeAll { $0.name == cleanName }
        palettes.append(saved)
        persist()
    }

    func remove(named name: String) {
        palettes.removeAll { $0.name == name }
        persist()
    }

    func contains(named name: String) -> Bool {
        palettes.contains { $0.name == name }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(palettes) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
