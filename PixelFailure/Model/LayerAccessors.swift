import Foundation

/// Typed access to a layer's kind-specific config, used by inspectors and renderers.
extension Layer {
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
}
