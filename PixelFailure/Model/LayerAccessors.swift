import Foundation

/// Typed access to a layer's kind-specific config, used by inspectors and renderers.
nonisolated extension Layer {
    var patternConfig: PatternConfig? {
        if case .pattern(let config) = kind { config } else { nil }
    }

    var imageConfig: ImageConfig? {
        if case .image(let config) = kind { config } else { nil }
    }

    var textConfig: TextConfig? {
        if case .text(let config) = kind { config } else { nil }
    }

    mutating func modifyPattern(_ change: (inout PatternConfig) -> Void) {
        guard case .pattern(var config) = kind else { return }
        change(&config)
        kind = .pattern(config)
    }

    mutating func modifyImage(_ change: (inout ImageConfig) -> Void) {
        guard case .image(var config) = kind else { return }
        change(&config)
        kind = .image(config)
    }

    mutating func modifyText(_ change: (inout TextConfig) -> Void) {
        guard case .text(var config) = kind else { return }
        change(&config)
        kind = .text(config)
    }

    var fillConfig: FillConfig? {
        if case .fill(let config) = kind { config } else { nil }
    }

    var shapeConfig: ShapeConfig? {
        if case .shape(let config) = kind { config } else { nil }
    }

    mutating func modifyFill(_ change: (inout FillConfig) -> Void) {
        guard case .fill(var config) = kind else { return }
        change(&config)
        kind = .fill(config)
    }

    mutating func modifyShape(_ change: (inout ShapeConfig) -> Void) {
        guard case .shape(var config) = kind else { return }
        change(&config)
        kind = .shape(config)
    }

    var groupConfig: GroupConfig? {
        if case .group(let config) = kind { config } else { nil }
    }

    var adjustmentConfig: AdjustmentConfig? {
        if case .adjustment(let config) = kind { config } else { nil }
    }

    mutating func modifyAdjustment(_ change: (inout AdjustmentConfig) -> Void) {
        guard case .adjustment(var config) = kind else { return }
        change(&config)
        kind = .adjustment(config)
    }

    var pathConfig: PathConfig? {
        if case .path(let config) = kind { config } else { nil }
    }

    mutating func modifyPath(_ change: (inout PathConfig) -> Void) {
        guard case .path(var config) = kind else { return }
        change(&config)
        kind = .path(config)
    }

    mutating func modifyGroup(_ change: (inout GroupConfig) -> Void) {
        guard case .group(var config) = kind else { return }
        change(&config)
        kind = .group(config)
    }

    /// This layer with every id in its subtree regenerated — required when
    /// duplicating or pasting so ids stay unique.
    func withFreshIDs() -> Layer {
        var copy = self
        copy.id = UUID()
        copy.styles = copy.styles.map {
            var style = $0; style.id = UUID(); return style
        }
        if case .path(var path) = copy.kind {
            path.nodes = path.nodes.map { node in
                var fresh = node; fresh.id = UUID(); return fresh
            }
            copy.kind = .path(path)
        }
        if case .text(var text) = copy.kind, let runs = text.styleRuns {
            text.styleRuns = runs.map { run in
                var fresh = run; fresh.id = UUID(); return fresh
            }
            copy.kind = .text(text)
        }
        if case .group(var group) = copy.kind {
            group.children = group.children.map { $0.withFreshIDs() }
            copy.kind = .group(group)
        }
        return copy
    }

    /// All image-store keys referenced in this layer's subtree (content
    /// images and masks).
    var referencedImageKeys: [String] {
        var keys: [String] = []
        if let config = imageConfig { keys.append(config.imageKey) }
        if let mask, !mask.imageKey.isEmpty { keys.append(mask.imageKey) }
        if case .group(let group) = kind {
            keys += group.children.flatMap(\.referencedImageKeys)
        }
        return keys
    }

    /// Rewrites image-store keys throughout the subtree (used on paste).
    mutating func remapImageKeys(_ map: [String: String]) {
        if var config = imageConfig, let newKey = map[config.imageKey] {
            config.imageKey = newKey
            kind = .image(config)
        }
        if let mask, let newKey = map[mask.imageKey] {
            self.mask?.imageKey = newKey
        }
        if case .group(var group) = kind {
            for i in group.children.indices {
                group.children[i].remapImageKeys(map)
            }
            kind = .group(group)
        }
    }
}
