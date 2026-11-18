import SwiftUI

/// A selection: a vector path in canvas coordinates (even-odd fill rule
/// throughout, so inverting and holes just work) plus a feather radius that
/// softens pixel operations. Marquee/lasso produce paths directly; the magic
/// wand traces its flood-fill region into one, so every selection gets
/// marching ants and crisp boolean ops.
///
/// Smart selections (Vision subject/people/object) also carry a soft `matte`.
/// When present, pixel operations use the matte and `path` is only its traced
/// 50% contour (marching ants, hit testing, bounds).
nonisolated struct CanvasSelection {
    var path: Path
    /// Soft edge in canvas pixels, applied when the selection rasterizes.
    var feather: Double
    var matte: SelectionMatte?

    init(path: Path, feather: Double = 0, matte: SelectionMatte? = nil) {
        self.path = path
        self.feather = feather
        self.matte = matte
    }

    /// A matte-backed selection; nil when the matte has no selected pixels.
    init?(matte: SelectionMatte, feather: Double = 0) {
        guard let path = matte.contourPath() else { return nil }
        self.init(path: path, feather: feather, matte: matte)
    }

    var bounds: CGRect { path.boundingRect }

    var isEmpty: Bool {
        let b = bounds
        return b.isNull || b.width < 0.5 || b.height < 0.5
    }

    func contains(_ point: CGPoint) -> Bool {
        path.contains(point, eoFill: true)
    }

    // MARK: - Booleans (even-odd rule everywhere)

    func union(_ other: Path) -> CanvasSelection {
        if matte != nil { return combinedSoft(with: CanvasSelection(path: other), .add) ?? self }
        return CanvasSelection(path: Path(path.cgPath.union(other.cgPath, using: .evenOdd)), feather: feather)
    }

    func subtracting(_ other: Path) -> CanvasSelection {
        if matte != nil { return combinedSoft(with: CanvasSelection(path: other), .subtract) ?? self }
        return CanvasSelection(path: Path(path.cgPath.subtracting(other.cgPath, using: .evenOdd)), feather: feather)
    }

    func intersecting(_ other: Path) -> CanvasSelection {
        if matte != nil { return combinedSoft(with: CanvasSelection(path: other), .intersect) ?? self }
        return CanvasSelection(path: Path(path.cgPath.intersection(other.cgPath, using: .evenOdd)), feather: feather)
    }

    /// Selection ⊕ selection. Path-only on both sides stays vector; if either
    /// side is soft, both rasterize onto a shared grid.
    func combined(with other: CanvasSelection, _ op: SelectionMatte.Op) -> CanvasSelection? {
        if matte == nil, other.matte == nil {
            switch op {
            case .add: return union(other.path)
            case .subtract: return subtracting(other.path)
            case .intersect: return intersecting(other.path)
            }
        }
        return combinedSoft(with: other, op)
    }

    private func combinedSoft(with other: CanvasSelection, _ op: SelectionMatte.Op) -> CanvasSelection? {
        let canvasSize = matte?.canvasSize ?? other.matte?.canvasSize ?? .zero
        guard let a = softMatte(canvasSize: canvasSize, like: other.matte),
              let b = other.softMatte(canvasSize: canvasSize, like: matte),
              let result = a.combined(with: b, op) else { return nil }
        guard let selection = CanvasSelection(matte: result, feather: feather) else {
            // Empty result: keep an empty path so callers' isEmpty checks work.
            return CanvasSelection(path: Path(), feather: feather)
        }
        return selection
    }

    /// The matte, or the path rasterized onto `like`'s grid (or the canvas grid).
    func softMatte(canvasSize: CGSize, like reference: SelectionMatte? = nil) -> SelectionMatte? {
        if let matte { return matte }
        let (w, h) = reference.map { ($0.width, $0.height) } ?? SelectionMatte.gridSize(for: canvasSize)
        return SelectionMatte.rasterize(path, canvasSize: canvasSize, width: w, height: h)
    }

    /// Even-odd inversion: appending the canvas rect flips inside/outside.
    func inverted(canvasSize: CGSize) -> CanvasSelection {
        if let matte, let flipped = matte.inverted() {
            return CanvasSelection(matte: flipped, feather: feather)
                ?? CanvasSelection(path: Path(), feather: feather)
        }
        var flipped = path
        flipped.addRect(CGRect(origin: .zero, size: canvasSize))
        return CanvasSelection(path: flipped, feather: feather)
    }

    static func all(canvasSize: CGSize) -> CanvasSelection {
        CanvasSelection(path: Path(CGRect(origin: .zero, size: canvasSize)))
    }

    /// How a freshly drawn region combines with the existing selection,
    /// decided by the modifier keys held when the gesture ends.
    static func combine(existing: CanvasSelection?, new: Path,
                        modifiers: NSEvent.ModifierFlags,
                        feather: Double) -> CanvasSelection? {
        let result: CanvasSelection
        if modifiers.contains(.shift), modifiers.contains(.option), let existing {
            result = existing.intersecting(new)
        } else if modifiers.contains(.shift), let existing {
            result = existing.union(new)
        } else if modifiers.contains(.option), let existing {
            result = existing.subtracting(new)
        } else {
            result = CanvasSelection(path: new, feather: feather)
        }
        return result.isEmpty ? nil : result
    }

    /// Combines a whole selection (possibly soft) with the existing one.
    static func combine(existing: CanvasSelection?, new: CanvasSelection,
                        mode: SelectionCombineMode) -> CanvasSelection? {
        let result: CanvasSelection?
        switch (mode, existing) {
        case (.replace, _), (_, nil): result = new
        case (.add, let existing?): result = existing.combined(with: new, .add)
        case (.subtract, let existing?): result = existing.combined(with: new, .subtract)
        case (.intersect, let existing?): result = existing.combined(with: new, .intersect)
        }
        guard let result, !result.isEmpty else { return nil }
        return result
    }
}
