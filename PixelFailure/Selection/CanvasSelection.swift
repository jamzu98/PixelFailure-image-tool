import SwiftUI

/// A selection: a vector path in canvas coordinates (even-odd fill rule
/// throughout, so inverting and holes just work) plus a feather radius that
/// softens pixel operations. Marquee/lasso produce paths directly; the magic
/// wand traces its flood-fill region into one, so every selection gets
/// marching ants and crisp boolean ops.
nonisolated struct CanvasSelection {
    var path: Path
    /// Soft edge in canvas pixels, applied when the selection rasterizes.
    var feather: Double

    init(path: Path, feather: Double = 0) {
        self.path = path
        self.feather = feather
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
        CanvasSelection(path: Path(path.cgPath.union(other.cgPath, using: .evenOdd)), feather: feather)
    }

    func subtracting(_ other: Path) -> CanvasSelection {
        CanvasSelection(path: Path(path.cgPath.subtracting(other.cgPath, using: .evenOdd)), feather: feather)
    }

    /// Even-odd inversion: appending the canvas rect flips inside/outside.
    func inverted(canvasSize: CGSize) -> CanvasSelection {
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
        if modifiers.contains(.shift), let existing {
            result = existing.union(new)
        } else if modifiers.contains(.option), let existing {
            result = existing.subtracting(new)
        } else {
            result = CanvasSelection(path: new, feather: feather)
        }
        return result.isEmpty ? nil : result
    }
}
