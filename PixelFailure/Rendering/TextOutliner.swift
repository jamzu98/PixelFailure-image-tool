import AppKit
import CoreText
import SwiftUI

/// Converts a TextConfig into vector outlines. Text becomes paths, so the
/// viewport, PNG export, and SVG export are pixel-identical and the SVG needs
/// no fonts installed.
enum TextOutliner {
    struct Result {
        var primitives: [VectorPrimitive]
        var size: CGSize
    }

    static func render(_ config: TextConfig) -> Result {
        let font = resolveFont(config)
        let lines = config.displayText.components(separatedBy: "\n")
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let lineHeight = config.size * config.lineHeight

        struct LaidOutLine {
            var ctLine: CTLine
            var width: Double
        }

        var laidOut: [LaidOutLine] = []
        for line in lines {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .kern: config.tracking,
            ]
            let attributed = NSAttributedString(string: line.isEmpty ? " " : line, attributes: attributes)
            let ctLine = CTLineCreateWithAttributedString(attributed)
            // Trailing kern inflates the width by one tracking unit; trim it.
            let rawWidth = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            let width = max(0, rawWidth - (line.isEmpty ? 0 : config.tracking))
            laidOut.append(LaidOutLine(ctLine: ctLine, width: width))
        }

        let totalWidth = laidOut.map(\.width).max() ?? 1
        let totalHeight = Double(ascent + descent) + lineHeight * Double(max(0, lines.count - 1))

        var combined = Path()
        for (index, line) in laidOut.enumerated() {
            let xOffset: Double
            switch config.alignment {
            case .left: xOffset = 0
            case .center: xOffset = (totalWidth - line.width) / 2
            case .right: xOffset = totalWidth - line.width
            }
            let baselineY = Double(ascent) + lineHeight * Double(index)
            appendGlyphs(of: line.ctLine, to: &combined, offset: CGPoint(x: xOffset, y: baselineY))
        }

        let size = CGSize(width: max(totalWidth, 1), height: max(totalHeight, 1))
        let primitive = VectorPrimitive(path: combined, fill: config.color)
        return Result(primitives: [primitive], size: size)
    }

    static func naturalSize(_ config: TextConfig) -> CGSize {
        render(config).size
    }

    private static func resolveFont(_ config: TextConfig) -> CTFont {
        var traits: [NSFontDescriptor.TraitKey: Any] = [.weight: config.weight.nsWeight]
        if config.italic {
            traits[.symbolic] = NSFontDescriptor.SymbolicTraits.italic.rawValue
        }
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: config.fontFamily,
            .traits: traits,
        ])
        let font = NSFont(descriptor: descriptor, size: config.size)
            ?? NSFont.systemFont(ofSize: config.size, weight: config.weight.systemWeight)
        return font as CTFont
    }

    /// Appends each glyph's outline, flipped from CoreText's y-up space into
    /// our y-down canvas space, positioned along the baseline.
    private static func appendGlyphs(of line: CTLine, to path: inout Path, offset: CGPoint) {
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attributes = CTRunGetAttributes(run) as! [CFString: Any]
            let runFont = attributes[kCTFontAttributeName] as! CTFont

            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)

            for i in 0..<count {
                guard let glyphPath = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
                var transform = CGAffineTransform(translationX: offset.x + positions[i].x,
                                                  y: offset.y + positions[i].y)
                    .scaledBy(x: 1, y: -1)
                if let transformed = glyphPath.copy(using: &transform) {
                    path.addPath(Path(transformed))
                }
            }
        }
    }
}

extension FontWeightChoice {
    var nsWeight: CGFloat {
        // NSFontDescriptor trait weights run -1...1.
        switch self {
        case .ultraLight: -0.8
        case .thin: -0.6
        case .light: -0.4
        case .regular: 0
        case .medium: 0.23
        case .semibold: 0.3
        case .bold: 0.4
        case .heavy: 0.56
        case .black: 0.62
        }
    }

    var systemWeight: NSFont.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        }
    }
}
