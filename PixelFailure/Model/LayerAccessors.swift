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
}
