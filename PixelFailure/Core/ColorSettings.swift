import CoreGraphics
import SwiftUI

/// The gamut every RGBAColor component value in the document is interpreted
/// against, and the space every raster context renders in. Imported images
/// keep their own embedded profiles; Core Graphics converts them into this
/// space when they draw.
nonisolated enum WorkingColorSpace: String, Codable, CaseIterable, Sendable {
    case sRGB
    case displayP3

    var displayName: String {
        switch self {
        case .sRGB: "sRGB"
        case .displayP3: "Display P3"
        }
    }

    var cgColorSpace: CGColorSpace {
        switch self {
        case .sRGB: CGColorSpace(name: CGColorSpace.sRGB)!
        case .displayP3: CGColorSpace(name: CGColorSpace.displayP3)!
        }
    }

    var swiftUISpace: Color.RGBColorSpace {
        switch self {
        case .sRGB: .sRGB
        case .displayP3: .displayP3
        }
    }
}

/// Bits per channel for rendered/painted rasters. 16-bit keeps smooth
/// gradients band-free through adjustment stacks; PNG and TIFF export
/// preserve it, lossy formats downconvert on encode.
nonisolated enum RasterBitDepth: Int, Codable, CaseIterable, Sendable {
    case eight = 8
    case sixteen = 16

    var displayName: String { "\(rawValue)-bit" }

    var bitsPerComponent: Int { rawValue }
}

/// Per-document color pipeline settings. Absent in documents saved before
/// schema v5, which decode as sRGB / 8-bit — exactly how they rendered before.
nonisolated struct ColorSettings: Codable, Hashable, Sendable {
    var workingSpace: WorkingColorSpace
    var bitDepth: RasterBitDepth

    init(workingSpace: WorkingColorSpace = .sRGB, bitDepth: RasterBitDepth = .eight) {
        self.workingSpace = workingSpace
        self.bitDepth = bitDepth
    }

    static let `default` = ColorSettings()

    /// Same gamut at 8-bit — for previews and thumbnails, where 16-bit
    /// buffers would only cost memory.
    var previewVariant: ColorSettings {
        ColorSettings(workingSpace: workingSpace, bitDepth: .eight)
    }

    /// An RGBA bitmap context in the working space at the configured depth.
    /// The single factory every renderer and paint buffer goes through.
    func makeRGBAContext(width: Int, height: Int) -> CGContext? {
        var bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        if bitDepth == .sixteen {
            bitmapInfo |= CGBitmapInfo.byteOrder16Little.rawValue
        }
        return CGContext(data: nil, width: max(1, width), height: max(1, height),
                         bitsPerComponent: bitDepth.bitsPerComponent, bytesPerRow: 0,
                         space: workingSpace.cgColorSpace, bitmapInfo: bitmapInfo)
    }
}
