import CoreGraphics
import Foundation

/// The serialized document state: everything needed to regenerate the artwork.
nonisolated struct ProjectModel: Codable, Hashable, Sendable {
    var canvasSize: CGSize
    var background: RGBAColor
    /// Bottom-to-top: index 0 draws first.
    var layers: [Layer]
    var palette: Palette

    init(canvasSize: CGSize = CGSize(width: 3000, height: 3000),
         background: RGBAColor = RGBAColor(hex: "#211E1B"),
         layers: [Layer] = [],
         palette: Palette = BuiltInPalettes.default) {
        self.canvasSize = canvasSize
        self.background = background
        self.layers = layers
        self.palette = palette
    }

    var canvasCenter: CGPoint { CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2) }

    func layer(id: UUID?) -> Layer? {
        guard let id else { return nil }
        return layers.first { $0.id == id }
    }

    func layerIndex(id: UUID) -> Int? {
        layers.firstIndex { $0.id == id }
    }

    mutating func modifyLayer(id: UUID, _ change: (inout Layer) -> Void) {
        guard let i = layerIndex(id: id) else { return }
        change(&layers[i])
    }

    /// A starter document: one flow-field pattern layer so a new window isn't blank.
    static func starter() -> ProjectModel {
        var model = ProjectModel()
        let config = PatternConfig(generator: .flowField)
        let layer = Layer(name: "Flow Field",
                          transform: LayerTransform(position: model.canvasCenter),
                          kind: .pattern(config))
        model.layers = [layer]
        return model
    }
}
