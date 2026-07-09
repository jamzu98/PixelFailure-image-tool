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

    // MARK: - Recursive traversal (groups nest layers)

    /// Finds a layer anywhere in the tree.
    func layer(id: UUID?) -> Layer? {
        guard let id else { return nil }
        return Self.find(id: id, in: layers)
    }

    private static func find(id: UUID, in layers: [Layer]) -> Layer? {
        for layer in layers {
            if layer.id == id { return layer }
            if case .group(let group) = layer.kind,
               let found = find(id: id, in: group.children) {
                return found
            }
        }
        return nil
    }

    /// Top-level index only (nil for nested layers).
    func layerIndex(id: UUID) -> Int? {
        layers.firstIndex { $0.id == id }
    }

    /// Mutates a layer anywhere in the tree.
    mutating func modifyLayer(id: UUID, _ change: (inout Layer) -> Void) {
        Self.modify(id: id, in: &layers, change)
    }

    @discardableResult
    private static func modify(id: UUID, in layers: inout [Layer], _ change: (inout Layer) -> Void) -> Bool {
        for i in layers.indices {
            if layers[i].id == id {
                change(&layers[i])
                return true
            }
            if case .group(var group) = layers[i].kind {
                if modify(id: id, in: &group.children, change) {
                    layers[i].kind = .group(group)
                    return true
                }
            }
        }
        return false
    }

    /// Every layer in the tree, depth-first, bottom-to-top within each level.
    var allLayers: [Layer] {
        Self.flatten(layers)
    }

    private static func flatten(_ layers: [Layer]) -> [Layer] {
        layers.flatMap { layer -> [Layer] in
            if case .group(let group) = layer.kind {
                return [layer] + flatten(group.children)
            }
            return [layer]
        }
    }

    /// The accumulated transform of a layer's ancestors: maps the layer's
    /// coordinate space into canvas space (identity for top-level layers).
    func parentAffine(of id: UUID) -> CGAffineTransform {
        Self.parentAffine(of: id, in: layers, canvasSize: canvasSize, accumulated: .identity) ?? .identity
    }

    private static func parentAffine(of id: UUID, in layers: [Layer],
                                     canvasSize: CGSize,
                                     accumulated: CGAffineTransform) -> CGAffineTransform? {
        for layer in layers {
            if layer.id == id { return accumulated }
            if case .group(let group) = layer.kind {
                // Children live in a nested canvas of the same size.
                let groupAffine = layer.transform.affine(naturalSize: canvasSize)
                    .concatenating(accumulated)
                if let found = parentAffine(of: id, in: group.children,
                                            canvasSize: canvasSize,
                                            accumulated: groupAffine) {
                    return found
                }
            }
        }
        return nil
    }

    /// The direct parent group's id (nil for top-level layers).
    func parentGroupID(of id: UUID) -> UUID? {
        Self.parentGroupID(of: id, in: layers)
    }

    private static func parentGroupID(of id: UUID, in layers: [Layer]) -> UUID? {
        for layer in layers {
            if case .group(let group) = layer.kind {
                if group.children.contains(where: { $0.id == id }) { return layer.id }
                if let found = parentGroupID(of: id, in: group.children) { return found }
            }
        }
        return nil
    }

    /// Mutates the array that directly contains a layer (the root list or a
    /// group's children). Returns false if the layer wasn't found.
    @discardableResult
    mutating func modifyContainer(of id: UUID, _ change: (inout [Layer]) -> Void) -> Bool {
        Self.modifyContainer(of: id, in: &layers, change)
    }

    private static func modifyContainer(of id: UUID, in layers: inout [Layer],
                                        _ change: (inout [Layer]) -> Void) -> Bool {
        if layers.contains(where: { $0.id == id }) {
            change(&layers)
            return true
        }
        for i in layers.indices {
            if case .group(var group) = layers[i].kind {
                if modifyContainer(of: id, in: &group.children, change) {
                    layers[i].kind = .group(group)
                    return true
                }
            }
        }
        return false
    }

    /// Removes the layers with these ids from anywhere in the tree and
    /// returns them in visual stacking order (bottom-to-top).
    mutating func removeLayers(ids: Set<UUID>) -> [Layer] {
        var removed: [Layer] = []
        Self.remove(ids: ids, from: &layers, removed: &removed)
        return removed
    }

    private static func remove(ids: Set<UUID>, from layers: inout [Layer], removed: inout [Layer]) {
        var kept: [Layer] = []
        for var layer in layers {
            if ids.contains(layer.id) {
                removed.append(layer)
                continue
            }
            if case .group(var group) = layer.kind {
                remove(ids: ids, from: &group.children, removed: &removed)
                layer.kind = .group(group)
            }
            kept.append(layer)
        }
        layers = kept
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
