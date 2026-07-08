import CoreGraphics
import Foundation

/// The serialized document state: everything needed to regenerate the artwork.
nonisolated struct ProjectModel: Codable, Hashable, Sendable {
    var canvasSize: CGSize
    var background: RGBAColor
    /// Bottom-to-top: index 0 draws first.
    var layers: [Layer]
    var palette: Palette
    /// Global adjustment stack applied to the whole composite (PNG/preview only).
    var canvasEffects: [Effect]

    init(canvasSize: CGSize = CGSize(width: 3000, height: 3000),
         background: RGBAColor = RGBAColor(hex: "#211E1B"),
         layers: [Layer] = [],
         palette: Palette = BuiltInPalettes.default,
         canvasEffects: [Effect] = []) {
        self.canvasSize = canvasSize
        self.background = background
        self.layers = layers
        self.palette = palette
        self.canvasEffects = canvasEffects
    }

    // Custom decoding so documents saved before canvasEffects existed still open.
    private enum CodingKeys: String, CodingKey {
        case canvasSize, background, layers, palette, canvasEffects
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        canvasSize = try container.decode(CGSize.self, forKey: .canvasSize)
        background = try container.decode(RGBAColor.self, forKey: .background)
        layers = try container.decode([Layer].self, forKey: .layers)
        palette = try container.decode(Palette.self, forKey: .palette)
        canvasEffects = try container.decodeIfPresent([Effect].self, forKey: .canvasEffects) ?? []
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
