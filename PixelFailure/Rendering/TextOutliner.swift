import AppKit
import CoreText
import SwiftUI

/// Converts a TextConfig into vector outlines. Text becomes paths, so the
/// viewport, PNG export, and SVG export are pixel-identical and the SVG needs
/// no fonts installed.
enum TextOutliner {
    private static let coreTextColorKey = NSAttributedString.Key(
        rawValue: kCTForegroundColorAttributeName as String)

    struct Result {
        var primitives: [VectorPrimitive]
        var size: CGSize
    }

    static func render(_ config: TextConfig, path textPath: Path? = nil) -> Result {
        let font = resolveFont(config)
        let attributed = attributedString(config, baseFont: font)
        if let textPath { return renderOnPath(attributed, config: config, path: textPath) }
        if let box = config.boxSize { return renderInBox(attributed, config: config, box: box) }
        let lines = config.displayText.components(separatedBy: "\n")
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let lineHeight = config.size * config.lineHeight

        struct LaidOutLine {
            var ctLine: CTLine
            var width: Double
        }

        var laidOut: [LaidOutLine] = []
        var stringLocation = 0
        for line in lines {
            let utf16Length = (line as NSString).length
            let lineAttributed: NSAttributedString
            if line.isEmpty {
                lineAttributed = NSAttributedString(string: " ", attributes: [
                    .font: font, .kern: config.tracking, coreTextColorKey: config.color.cgColor,
                ])
            } else {
                lineAttributed = attributed.attributedSubstring(
                    from: NSRange(location: min(stringLocation, attributed.length),
                                  length: min(utf16Length, max(attributed.length - stringLocation, 0))))
            }
            let ctLine = CTLineCreateWithAttributedString(lineAttributed)
            // Trailing kern inflates the width by one tracking unit; trim it.
            let rawWidth = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            let width = max(0, rawWidth - (line.isEmpty ? 0 : config.tracking))
            laidOut.append(LaidOutLine(ctLine: ctLine, width: width))
            stringLocation += utf16Length + 1
        }

        let totalWidth = laidOut.map(\.width).max() ?? 1
        let totalHeight = Double(ascent + descent) + lineHeight * Double(max(0, lines.count - 1))

        var primitives: [VectorPrimitive] = []
        for (index, line) in laidOut.enumerated() {
            let xOffset: Double
            switch config.alignment {
            case .left: xOffset = 0
            case .center: xOffset = (totalWidth - line.width) / 2
            case .right: xOffset = totalWidth - line.width
            }
            let baselineY = Double(ascent) + lineHeight * Double(index)
            primitives += glyphPrimitives(of: line.ctLine,
                                          offset: CGPoint(x: xOffset, y: baselineY),
                                          fallbackColor: config.color)
        }

        let size = CGSize(width: max(totalWidth, 1), height: max(totalHeight, 1))
        return Result(primitives: primitives, size: size)
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

    private static func attributedString(_ config: TextConfig, baseFont: CTFont) -> NSAttributedString {
        let text = config.displayText
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: baseFont, .kern: config.tracking,
            .ligature: (config.ligatures ?? true) ? 1 : 0,
            coreTextColorKey: config.color.cgColor,
        ])
        var featureSettings: [[CFString: Int]] = []
        if config.smallCaps == true {
            featureSettings.append([
                kCTFontFeatureTypeIdentifierKey: kLowerCaseType,
                kCTFontFeatureSelectorIdentifierKey: kLowerCaseSmallCapsSelector,
            ])
        }
        if let alternate = config.stylisticAlternates, alternate > 0 {
            featureSettings.append([
                kCTFontFeatureTypeIdentifierKey: kStylisticAlternativesType,
                kCTFontFeatureSelectorIdentifierKey: alternate,
            ])
        }
        if !featureSettings.isEmpty {
            result.addAttribute(NSAttributedString.Key(rawValue: kCTFontFeatureSettingsAttribute as String),
                                value: featureSettings,
                                range: NSRange(location: 0, length: result.length))
        }
        for run in config.styleRuns ?? [] {
            let location = min(max(run.location, 0), result.length)
            let length = min(max(run.length, 0), result.length - location)
            guard length > 0 else { continue }
            let range = NSRange(location: location, length: length)
            if let color = run.color {
                result.addAttribute(coreTextColorKey, value: color.cgColor, range: range)
            }
            if run.fontFamily != nil || run.weight != nil || run.size != nil {
                var adjusted = config
                adjusted.fontFamily = run.fontFamily ?? config.fontFamily
                adjusted.weight = run.weight ?? config.weight
                adjusted.size = run.size ?? config.size
                result.addAttribute(.font, value: resolveFont(adjusted), range: range)
            }
        }
        return result
    }

    private static func renderInBox(_ attributed: NSAttributedString, config: TextConfig,
                                    box: CGSize) -> Result {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let framePath = CGPath(rect: CGRect(origin: .zero, size: box), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length),
                                             framePath, nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var primitives: [VectorPrimitive] = []
        let usedHeight = min(box.height, CGFloat(max(lines.count, 1)) * config.size * config.lineHeight)
        let spare = max(0, box.height - usedHeight)
        let verticalOffset: CGFloat = switch config.verticalAlignment ?? .top {
        case .top: 0
        case .center: spare / 2
        case .bottom: spare
        }
        for index in lines.indices {
            let origin = origins[index]
            primitives += glyphPrimitives(of: lines[index],
                                          offset: CGPoint(x: origin.x, y: box.height - origin.y + verticalOffset),
                                          fallbackColor: config.color)
        }
        return Result(primitives: primitives,
                      size: CGSize(width: max(box.width, 1), height: max(box.height, 1)))
    }

    private static func renderOnPath(_ attributed: NSAttributedString, config: TextConfig,
                                     path: Path) -> Result {
        let points = flattenedEndpoints(path.cgPath)
        guard points.count >= 2 else { return render(config) }
        let line = CTLineCreateWithAttributedString(attributed)
        var primitives: [VectorPrimitive] = []
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attributes = CTRunGetAttributes(run) as! [CFString: Any]
            let runFont = attributes[kCTFontAttributeName] as! CTFont
            let color = color(from: attributes[kCTForegroundColorAttributeName]) ?? config.color
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            var combined = Path()
            for index in 0..<count {
                guard let glyph = CTFontCreatePathForGlyph(runFont, glyphs[index], nil),
                      let placement = pointAlong(points, distance: positions[index].x) else { continue }
                var transform = CGAffineTransform(translationX: placement.point.x,
                                                  y: placement.point.y)
                    .rotated(by: placement.angle)
                    .scaledBy(x: 1, y: -1)
                if let transformed = glyph.copy(using: &transform) {
                    combined.addPath(Path(transformed))
                }
            }
            primitives.append(VectorPrimitive(path: combined, fill: color))
        }
        return Result(primitives: primitives, size: path.boundingRect.size)
    }

    /// Each CoreText run becomes its own primitive so per-range colors remain
    /// vector attributes through SVG export.
    private static func glyphPrimitives(of line: CTLine, offset: CGPoint,
                                        fallbackColor: RGBAColor) -> [VectorPrimitive] {
        var primitives: [VectorPrimitive] = []
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

            var path = Path()
            for i in 0..<count {
                guard let glyphPath = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
                var transform = CGAffineTransform(translationX: offset.x + positions[i].x,
                                                  y: offset.y + positions[i].y)
                    .scaledBy(x: 1, y: -1)
                if let transformed = glyphPath.copy(using: &transform) {
                    path.addPath(Path(transformed))
                }
            }
            let color = color(from: attributes[kCTForegroundColorAttributeName]) ?? fallbackColor
            primitives.append(VectorPrimitive(path: path, fill: color))
        }
        return primitives
    }

    private static func color(from value: Any?) -> RGBAColor? {
        guard let value else { return nil }
        let color: CGColor
        if let nsColor = value as? NSColor { color = nsColor.cgColor }
        else { color = value as! CGColor }
        guard let converted = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3 else { return nil }
        return RGBAColor(r: components[0], g: components[1], b: components[2],
                         a: components.count > 3 ? components[3] : 1)
    }

    private static func flattenedEndpoints(_ path: CGPath) -> [CGPoint] {
        var points: [CGPoint] = []
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint, .addLineToPoint: points.append(element.points[0])
            case .addQuadCurveToPoint: points.append(element.points[1])
            case .addCurveToPoint: points.append(element.points[2])
            case .closeSubpath: if let first = points.first { points.append(first) }
            @unknown default: break
            }
        }
        return points
    }

    private static func pointAlong(_ points: [CGPoint], distance: CGFloat)
        -> (point: CGPoint, angle: CGFloat)? {
        var remaining = distance
        for index in 1..<points.count {
            let a = points[index - 1], b = points[index]
            let length = hypot(b.x - a.x, b.y - a.y)
            if remaining <= length {
                let t = length > 0 ? remaining / length : 0
                return (CGPoint(x: a.x + (b.x - a.x) * t,
                                y: a.y + (b.y - a.y) * t),
                        atan2(b.y - a.y, b.x - a.x))
            }
            remaining -= length
        }
        return nil
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
