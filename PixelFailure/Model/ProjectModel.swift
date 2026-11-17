import CoreGraphics
import Foundation

/// The serialized document state: everything needed to regenerate the artwork.
nonisolated struct ProjectModel: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 6

    /// Explicit manifest version. Documents written before versioning decode
    /// as v1; new migrations can branch on this without guessing from fields.
    var schemaVersion: Int
    var canvasSize: CGSize
    /// Working color space + raster bit depth (v5). Older documents decode
    /// as sRGB / 8-bit and render exactly as they always did.
    var colorSettings: ColorSettings
    var background: RGBAColor
    /// Bottom-to-top: index 0 draws first.
    var layers: [Layer]
    var palette: Palette
    /// Global adjustment stack applied to the whole composite (PNG/preview only).
    var canvasEffects: [Effect]
    var workspace: WorkspaceSettings
    var animation: AnimationSettings
    /// Physical output metadata; it never changes canvas pixels.
    var printSettings: PrintSettings
    var exportSlices: [ExportSlice]

    init(schemaVersion: Int = ProjectModel.currentSchemaVersion,
         canvasSize: CGSize = CGSize(width: 3000, height: 3000),
         colorSettings: ColorSettings = .default,
         background: RGBAColor = RGBAColor(hex: "#211E1B"),
         layers: [Layer] = [],
         palette: Palette = BuiltInPalettes.default,
         canvasEffects: [Effect] = [],
         workspace: WorkspaceSettings = WorkspaceSettings(),
         animation: AnimationSettings = AnimationSettings(),
         printSettings: PrintSettings = PrintSettings(),
         exportSlices: [ExportSlice] = []) {
        self.schemaVersion = schemaVersion
        self.canvasSize = canvasSize
        self.colorSettings = colorSettings
        self.background = background
        self.layers = layers
        self.palette = palette
        self.canvasEffects = canvasEffects
        self.workspace = workspace
        self.animation = animation
        self.printSettings = printSettings
        self.exportSlices = exportSlices
    }

    // Custom decoding so documents saved before canvasEffects existed still open.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, canvasSize, colorSettings, background, layers, palette, canvasEffects,
             workspace, animation, printSettings, exportSlices
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        canvasSize = try container.decode(CGSize.self, forKey: .canvasSize)
        colorSettings = try container.decodeIfPresent(ColorSettings.self, forKey: .colorSettings) ?? .default
        background = try container.decode(RGBAColor.self, forKey: .background)
        layers = try container.decode([Layer].self, forKey: .layers)
        palette = try container.decode(Palette.self, forKey: .palette)
        canvasEffects = try container.decodeIfPresent([Effect].self, forKey: .canvasEffects) ?? []
        workspace = try container.decodeIfPresent(WorkspaceSettings.self, forKey: .workspace) ?? WorkspaceSettings()
        animation = try container.decodeIfPresent(AnimationSettings.self, forKey: .animation) ?? AnimationSettings()
        printSettings = try container.decodeIfPresent(PrintSettings.self, forKey: .printSettings) ?? PrintSettings()
        exportSlices = try container.decodeIfPresent([ExportSlice].self, forKey: .exportSlices) ?? []
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

    /// Direct ancestors, nearest first.
    func ancestorGroupIDs(of id: UUID) -> [UUID] {
        Self.ancestorPath(to: id, in: layers) ?? []
    }

    private static func ancestorPath(to id: UUID, in layers: [Layer]) -> [UUID]? {
        for layer in layers {
            if layer.id == id { return [] }
            if case .group(let group) = layer.kind,
               let path = ancestorPath(to: id, in: group.children) {
                return [layer.id] + path
            }
        }
        return nil
    }

    /// A child of a locked group is effectively locked even when its own
    /// lock bit is clear.
    func isEffectivelyLocked(_ id: UUID) -> Bool {
        guard let layer = layer(id: id) else { return false }
        return layer.isLocked || ancestorGroupIDs(of: id).contains {
            self.layer(id: $0)?.isLocked == true
        }
    }

    /// Transform from the layer's immediate coordinate space to the canvas.
    func worldTransform(of id: UUID) -> LayerTransform? {
        guard var result = layer(id: id)?.transform else { return nil }
        for ancestorID in ancestorGroupIDs(of: id).reversed() {
            guard let parent = layer(id: ancestorID) else { continue }
            result = result.composed(withParent: parent.transform,
                                     parentNaturalSize: canvasSize)
        }
        return result
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

    /// Inserts into root or directly into a group. Index is bottom-to-top and
    /// clamps to the destination bounds.
    @discardableResult
    mutating func insertLayer(_ layer: Layer, into parentGroupID: UUID?, at index: Int) -> Bool {
        if let parentGroupID {
            var inserted = false
            modifyLayer(id: parentGroupID) { parent in
                guard case .group(var group) = parent.kind else { return }
                group.children.insert(layer, at: min(max(index, 0), group.children.count))
                parent.kind = .group(group)
                inserted = true
            }
            return inserted
        }
        layers.insert(layer, at: min(max(index, 0), layers.count))
        return true
    }

    func containerLayers(parentGroupID: UUID?) -> [Layer]? {
        guard let parentGroupID else { return layers }
        return layer(id: parentGroupID)?.groupConfig?.children
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

nonisolated struct PrintSettings: Codable, Hashable, Sendable {
    var dpi: Double
    init(dpi: Double = 72) { self.dpi = max(1, dpi) }

    func physicalSize(for pixels: CGSize) -> CGSize {
        CGSize(width: pixels.width / dpi, height: pixels.height / dpi)
    }
}

nonisolated struct ExportSlice: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var rect: CGRect
    var scales: [Int]

    init(id: UUID = UUID(), name: String = "Slice", rect: CGRect,
         scales: [Int] = [1, 2, 3]) {
        self.id = id; self.name = name; self.rect = rect
        self.scales = scales.filter { $0 > 0 }
    }
}

nonisolated struct AnimationKeyframe: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var time: Double
    var layerID: UUID
    var seed: UInt64
    var parameters: [String: Double]

    init(id: UUID = UUID(), time: Double, layerID: UUID, seed: UInt64,
         parameters: [String: Double]) {
        self.id = id
        self.time = time
        self.layerID = layerID
        self.seed = seed
        self.parameters = parameters
    }
}

nonisolated struct AnimationSettings: Codable, Hashable, Sendable {
    var duration: Double
    var framesPerSecond: Int
    var keyframes: [AnimationKeyframe]

    init(duration: Double = 4, framesPerSecond: Int = 24,
         keyframes: [AnimationKeyframe] = []) {
        self.duration = duration
        self.framesPerSecond = framesPerSecond
        self.keyframes = keyframes
    }

    var frameCount: Int { max(1, Int((duration * Double(framesPerSecond)).rounded())) }
}

extension ProjectModel {
    /// Resolves a deterministic frame. Scalars interpolate linearly; seeds
    /// step at the midpoint because generator randomness is intentionally discrete.
    func model(at animationTime: Double) -> ProjectModel {
        var result = self
        let time = min(max(animationTime, 0), animation.duration)
        let layerIDs = Set(animation.keyframes.map(\.layerID))
        for layerID in layerIDs {
            let frames = animation.keyframes.filter { $0.layerID == layerID }
                .sorted { $0.time < $1.time }
            guard let first = frames.first else { continue }
            let before = frames.last(where: { $0.time <= time }) ?? first
            let after = frames.first(where: { $0.time >= time }) ?? frames.last!
            let span = after.time - before.time
            let t = span > 0 ? (time - before.time) / span : 0
            result.modifyLayer(id: layerID) { layer in
                layer.modifyPattern { pattern in
                    pattern.seed = t < 0.5 ? before.seed : after.seed
                    let keys = Set(before.parameters.keys).union(after.parameters.keys)
                    for key in keys {
                        let a = before.parameters[key] ?? pattern.params.storage[key] ?? 0
                        let b = after.parameters[key] ?? a
                        pattern.params.storage[key] = a + (b - a) * t
                    }
                }
            }
        }
        return result
    }
}

nonisolated enum GuideOrientation: String, Codable, Hashable, Sendable {
    case horizontal, vertical
}

nonisolated struct CanvasGuide: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var orientation: GuideOrientation
    var position: Double

    init(id: UUID = UUID(), orientation: GuideOrientation, position: Double) {
        self.id = id
        self.orientation = orientation
        self.position = position
    }
}

nonisolated struct GridSettings: Codable, Hashable, Sendable {
    var isVisible: Bool
    var spacing: Double
    var subdivisions: Int
    var snapsToGrid: Bool

    init(isVisible: Bool = false, spacing: Double = 100,
         subdivisions: Int = 2, snapsToGrid: Bool = false) {
        self.isVisible = isVisible
        self.spacing = spacing
        self.subdivisions = subdivisions
        self.snapsToGrid = snapsToGrid
    }
}

nonisolated struct WorkspaceSettings: Codable, Hashable, Sendable {
    var guides: [CanvasGuide]
    var grid: GridSettings
    var showsRulers: Bool
    var smartGuidesEnabled: Bool
    var showsNavigator: Bool

    init(guides: [CanvasGuide] = [], grid: GridSettings = GridSettings(),
         showsRulers: Bool = true, smartGuidesEnabled: Bool = true,
         showsNavigator: Bool = false) {
        self.guides = guides
        self.grid = grid
        self.showsRulers = showsRulers
        self.smartGuidesEnabled = smartGuidesEnabled
        self.showsNavigator = showsNavigator
    }
}
