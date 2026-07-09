import AppKit

/// Cursor instances for the viewport. Everything is cached so pointer
/// identity is stable — the viewport only calls `set()` when the cursor
/// actually changes.
@MainActor
enum Cursors {
    // MARK: - Brush: a circle matching the on-screen brush diameter

    private static var brushCache: [Int: NSCursor] = [:]

    static func brush(diameter: Double) -> NSCursor {
        let clamped = min(max(diameter, 8), 300)
        // Bucket to 2px steps so zoom/size tweaks reuse cached cursors.
        let key = Int((clamped / 2).rounded()) * 2
        if let cached = brushCache[key] { return cached }

        let size = CGFloat(key) + 4
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            // Black-on-white double ring stays visible on any artwork.
            let outer = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            outer.lineWidth = 1.5
            NSColor.white.withAlphaComponent(0.9).setStroke()
            outer.stroke()
            let inner = NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5))
            inner.lineWidth = 1
            NSColor.black.withAlphaComponent(0.85).setStroke()
            inner.stroke()
            // Center dot for aim.
            let dot = NSBezierPath(ovalIn: NSRect(x: rect.midX - 1, y: rect.midY - 1, width: 2, height: 2))
            NSColor.black.withAlphaComponent(0.8).setFill()
            dot.fill()
            return true
        }
        let cursor = NSCursor(image: image, hotSpot: NSPoint(x: size / 2, y: size / 2))
        brushCache[key] = cursor
        return cursor
    }

    // MARK: - Symbol-based cursors

    static let rotate: NSCursor = symbolCursor("arrow.trianglehead.2.clockwise.rotate.90", pointSize: 14)

    /// Hotspot at the dropper's tip (bottom-left of the glyph).
    static let eyedropper: NSCursor = {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: "eyedropper", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return .crosshair }
        let size = symbol.size
        return NSCursor(image: symbol, hotSpot: NSPoint(x: 2, y: size.height - 2))
    }()

    private static func symbolCursor(_ name: String, pointSize: CGFloat) -> NSCursor {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return .crosshair }
        return NSCursor(image: symbol,
                        hotSpot: NSPoint(x: symbol.size.width / 2, y: symbol.size.height / 2))
    }

    // MARK: - Resize cursors

    /// Diagonal resize for a selection corner (0 = top-left, clockwise).
    static func resizeCorner(_ index: Int) -> NSCursor {
        switch index {
        case 0: .frameResize(position: .topLeft, directions: .all)
        case 1: .frameResize(position: .topRight, directions: .all)
        case 2: .frameResize(position: .bottomRight, directions: .all)
        default: .frameResize(position: .bottomLeft, directions: .all)
        }
    }

    /// Resize cursor for a crop handle described by its unit position on the
    /// rect (corners and edge midpoints).
    static func resizeForCropHandle(unit: CGPoint) -> NSCursor {
        switch (unit.x, unit.y) {
        case (0, 0): .frameResize(position: .topLeft, directions: .all)
        case (1, 0): .frameResize(position: .topRight, directions: .all)
        case (1, 1): .frameResize(position: .bottomRight, directions: .all)
        case (0, 1): .frameResize(position: .bottomLeft, directions: .all)
        case (_, 0): .frameResize(position: .top, directions: .all)
        case (_, 1): .frameResize(position: .bottom, directions: .all)
        case (0, _): .frameResize(position: .left, directions: .all)
        default: .frameResize(position: .right, directions: .all)
        }
    }
}
